//! This file contains thread pool / POSIX poll based backend. I/O operations
//! are scheduled on a separate thread and POSIX poll is used for cancellations.
//! For blocking operations that can't be cancelled (e.g. open / stat syscalls),
//! cancellations is emulated by discarding the result or closing the file.

const std = @import("std");
const builtin = @import("builtin");

const ThreadPool = @import("../ThreadPool.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const operation = @import("../operation.zig");

const Self = @This();
pub const Loop = Self;

// Number of pending operations.
pending: usize,

// Thread pool and done queue.
tpool: ThreadPool,
done: queue_mpsc.Intrusive(Operation),

// Futex to wake up blocking poll.
futex: std.atomic.Value(u32),

pub fn init(self: *Self) void {
    self.pending = 0;
    self.tpool = .init(.{});
    self.done = undefined;
    self.futex = .init(0);
    self.done.init();
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.pending == 0);
    std.debug.assert(self.done.head == &self.done.stub);
    self.done.init();
    self.tpool.shutdown();
    self.tpool.deinit();
}

/// Submits an I/O operation on thread pool.
pub fn submit(self: *Self, op: *Operation) void {
    op.submitted(self);

    const batch = ThreadPool.Batch.from(&op.task);
    self.tpool.schedule(batch);
    self.pending += 1;
}

/// Polls until a scheduled I/O operation completes. If there is none, this
/// function returns without blocking.
pub fn poll(self: *Self) usize {
    var done: usize = 0;
    while (self.done.pop()) |op| {
        op.callback();
        op.* = Operation.init(undefined);
        done += 1;
    }

    if (done == 0) {
        if (self.pending == 0) return 0;

        self.futex.store(0, .unordered);
        std.Thread.Futex.wait(&self.futex, 0);
        return self.poll();
    }

    self.pending -= done;
    return done;
}

/// Operation defines an asynchronous I/O operation executed on a thread pool.
pub const Operation = struct {
    // Input / output.
    data: operation.Data,

    // Metadata:

    owner: *Loop,
    state: OpStateMachine,
    task: ThreadPool.Task,

    // Intrusive linked list next field.
    next: ?*Operation = null,

    fn init(data: operation.Data) Operation {
        return .{
            .data = data,
            .owner = undefined,
            .state = .{},
            .task = .{
                .node = .{ .next = null },
                .callback = struct {
                    fn callback(t: *ThreadPool.Task) void {
                        const op: *Operation = @fieldParentPtr(
                            "task",
                            t,
                        );
                        op.block();
                    }
                }.callback,
            },
            .next = null,
        };
    }

    fn submitted(self: *Operation, loop: *Loop) void {
        self.owner = loop;
    }

    /// Execute blocking I/O operation.
    fn block(self: *Operation) void {
        var state: ThreadStateMachine = .{};
        if (!self.state.try_sync(&state)) { // Early cancel.
            return;
        }

        switch (self.data) {
            .sleep => |data| {
                std.Thread.sleep(std.math.mul(
                    usize,
                    data.ms,
                    std.time.ns_per_ms,
                ) catch std.math.maxInt(usize));
                if (!state.try_terminate()) { // cancelled.
                    return;
                }
            },
            .cancel => |data| {
                const op: *Operation = @ptrCast(@alignCast(data.op));
                switch (op.data) {
                    .cancel => @panic(
                        "cancelling cancel operation is not possible",
                    ),
                    else => if (op.try_cancel()) {
                        // Schedule cancelled operation callback.
                        self.owner.done.push(op);
                    } else {
                        self.data.cancel.result = error.OperationDone;
                    },
                }
            },
        }

        self.owner.done.push(self);
        std.Thread.Futex.wake(&self.owner.futex, 1);
    }

    // Tries to cancel operation and returns true if succeeed.
    fn try_cancel(self: *Operation) bool {
        if (!self.state.try_cancel()) return false;

        inline for (@typeInfo(operation.Type).@"enum".fields) |variant| {
            const opType = @field(operation.Type, variant.name);
            if (@as(operation.Type, self.data) == opType) {
                if (opType == @field(operation.Type, "cancel")) {
                    unreachable;
                } else {
                    @field(self.data, variant.name).result = error.CancelError;
                    return true;
                }
            }
        }

        unreachable;
    }

    // Executes callback.
    fn callback(self: *Operation) void {
        inline for (@typeInfo(operation.Type).@"enum".fields) |variant| {
            if (@as(operation.Type, self.data) ==
                @field(operation.Type, variant.name))
            {
                const data = @field(self.data, variant.name);
                const cb = @field(data, "callback");
                @call(.auto, cb, .{ self, data });
                return;
            }
        }
        unreachable;
    }
};

// OpStateMachine defines state machine of an operation submitted to a worker
// thread.
const OpStateMachine = struct {
    thread_state: std.atomic.Value(?*ThreadStateMachine) = .init(null),

    var early_cancel: ThreadStateMachine = .{ .state = .init(.cancelled) };

    /// Tries to synchronizes state with thread. This fails if task is already
    /// cancelled.
    fn try_sync(
        self: *OpStateMachine,
        thread_state: *ThreadStateMachine,
    ) bool {
        return self.thread_state.cmpxchgStrong(
            null,
            thread_state,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    // Tries to transition from submitted to cancelled state and returns true if
    // succeeed. This function should never be called from a worker thread.
    fn try_cancel(self: *OpStateMachine) bool {
        if (self.thread_state.swap(&early_cancel, .seq_cst)) |s| {
            if (s == &early_cancel) return false; // already cancelled.

            const state = s.state.cmpxchgStrong(
                .submitted,
                .cancelled,
                .seq_cst,
                .seq_cst,
            );
            return state == null;
        }

        return true;
    }
};

/// ThreadStateMachine defines state machine of an Operation executed on a
/// worker thread.
const ThreadStateMachine = struct {
    state: std.atomic.Value(operation.State) = .init(.submitted),

    // Tries to transition from submitted to cancelled state and returns true if
    // succeeed.
    fn try_terminate(self: *ThreadStateMachine) bool {
        return self.state.cmpxchgStrong(
            .submitted,
            .dead,
            .seq_cst,
            .seq_cst,
        ) == null;
    }
};

test "sleep" {
    const Static = struct {
        var called = false;

        fn callback(_: *anyopaque, data: operation.Data.of(.sleep)) void {
            called = true;
            data.result catch unreachable;
        }
    };

    var b: Self = undefined;
    b.init();
    defer b.deinit();

    var sleep1 = Operation.init(.{ .sleep = .{
        .ms = 5,
        .callback = &Static.callback,
    } });
    var sleep2 = Operation.init(.{ .sleep = .{
        .ms = 15,
        .callback = &Static.callback,
    } });

    b.submit(&sleep1);
    b.submit(&sleep2);

    // Poll.
    var timer = try std.time.Timer.start();
    const done = b.poll();
    const ns = timer.read();

    try std.testing.expect(done == 1);
    try std.testing.expect(ns >= 5 * std.time.ns_per_ms);
    try std.testing.expect(Static.called);

    _ = b.poll();
}

test "cancel sleep" {
    var n: usize = 0;

    for (0..100) |_| {
        const S = struct {
            var called: usize = 0;
            var sleepCallbackData: ?operation.Data.of(.sleep) = null;
            var cancelCallbackData: ?operation.Data.of(.cancel) = null;

            fn sleepCallback(_: *anyopaque, data: operation.Data.of(.sleep)) void {
                sleepCallbackData = data;
                defer called += 1;

                data.result catch |err| {
                    if (err != error.CancelError) unreachable;
                    if (called != 0) unreachable;
                    return;
                };
                if (called != 1) unreachable;
            }

            fn cancelCallback(_: *anyopaque, data: operation.Data.of(.cancel)) void {
                cancelCallbackData = data;
                defer called += 1;

                data.result catch |err| {
                    if (err != error.OperationDone) unreachable;
                    if (called != 0) unreachable;
                    return;
                };
                if (called != 1) unreachable;
            }
        };
        S.called = 0;
        S.sleepCallbackData = null;
        S.cancelCallbackData = null;

        var b: Self = undefined;
        b.init();

        var sleep = Operation.init(.{ .sleep = .{
            .ms = 5,
            .callback = &S.sleepCallback,
        } });
        var cancel = Operation.init(.{ .cancel = .{
            .op = &sleep,
            .callback = S.cancelCallback,
        } });

        b.submit(&sleep);
        b.submit(&cancel);

        var timer = try std.time.Timer.start();
        const done = b.poll();
        const ns = timer.read();

        try std.testing.expect(done == 2);
        try std.testing.expect(S.called == 2);
        S.sleepCallbackData.?.result catch { // cancelled
            n |= 1;
            try std.testing.expect(ns <= 5 * std.time.ns_per_ms);
            return;
        };
        n |= 2;
        try std.testing.expect(ns >= 5 * std.time.ns_per_ms);
    }

    try std.testing.expect(n == 3);
}
