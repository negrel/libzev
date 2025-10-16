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
    // Prepare to wait.
    self.futex.store(0, .seq_cst);

    // Pop all completed operation.
    var done: usize = 0;
    while (self.done.pop()) |op| {
        op.callback();
        done += 1;
    }

    // Zero operation complete.
    if (done == 0) {
        if (self.pending == 0) return 0;

        // Wait until a thread operation completes.
        std.Thread.Futex.wait(&self.futex, 0);

        // Retry to poll.
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
        self.* = .init(self.data);
        self.owner = loop;
    }

    /// Freezes thread state machine to final state by replacing the local one
    /// with static equivalent.
    fn freezeThreadState(
        self: *Operation,
        thread_state: *ThreadStateMachine,
    ) void {
        if (self.state.thread_state.load(.seq_cst) == thread_state) {
            switch (thread_state.state.load(.seq_cst)) {
                .dead => self.state.thread_state.store(
                    &OpStateMachine.dead,
                    .seq_cst,
                ),
                .cancelled => self.state.thread_state.store(
                    &OpStateMachine.cancelled,
                    .seq_cst,
                ),
                .submitted => unreachable,
            }
        }
    }

    /// Execute blocking I/O operation.
    fn block(self: *Operation) void {
        // Store operation thread on the stack so it can outlive the operation
        // if cancelled.
        var state: ThreadStateMachine = .{};
        if (!state.try_sync(&self.state)) return; // Early cancel.

        // Freeze thread state before returning / pushing it to the done queue
        // as &state is a pointer to local variable and will be invalid once we
        // return.
        {
            defer self.freezeThreadState(&state);

            switch (self.data) {
                .sleep => |data| {
                    std.Thread.sleep(std.math.mul(
                        usize,
                        data.ms,
                        std.time.ns_per_ms,
                    ) catch std.math.maxInt(usize));
                    if (!state.try_terminate()) return; // cancelled.
                },
                .cancel => |data| {
                    const op: *Operation = @ptrCast(@alignCast(data.op));
                    if (op.try_cancel()) {
                        switch (op.data) {
                            .cancel => @panic(
                                "cancelling cancel operation is not possible",
                            ),
                            else => {},
                        }

                        // Schedule cancelled operation callback.
                        if (!state.try_terminate()) unreachable;
                        self.owner.done.push(op);
                    } else {
                        if (!state.try_terminate()) unreachable;
                        self.data.cancel.result = error.OperationDone;
                    }
                },
                .open_file => |data| {
                    const result = data.dir.openFile(
                        data.sub_path,
                        data.flags,
                    );
                    if (state.try_terminate()) {
                        self.data.open_file = .{
                            .dir = data.dir,
                            .sub_path = data.sub_path,
                            .flags = data.flags,
                            .result = result,
                            .callback = data.callback,
                        };
                    } else { // cancelled.
                        cleanup: {
                            const f = result catch break :cleanup;
                            f.close();
                        }
                        return;
                    }
                },
                .pread => |data| {
                    const result = data.f.pread(data.buf, data.offset);
                    if (state.try_terminate()) {
                        self.data.pread = .{
                            .f = data.f,
                            .buf = data.buf,
                            .offset = data.offset,
                            .result = result,
                            .callback = data.callback,
                        };
                    } else return;
                },
            }
        }

        // Schedule callback.
        self.owner.done.push(self);

        // Wake up blocking poll if any.
        self.owner.futex.store(1, .seq_cst);
        std.Thread.Futex.wake(&self.owner.futex, 1);
    }

    // Tries to cancel operation and returns true if succeeed.
    fn try_cancel(self: *Operation) bool {
        const cancelled = self.state.try_cancel();
        if (!cancelled) return false;

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
    thread_state: std.atomic.Value(*ThreadStateMachine) = .init(&submitted),

    // Immutable static ThreadStateMachine. These are used to before an
    // operation starts and after it complete.
    pub var submitted: ThreadStateMachine = .{ .state = .init(.submitted) };
    pub var dead: ThreadStateMachine = .{ .state = .init(.dead) };
    pub var cancelled: ThreadStateMachine = .{ .state = .init(.cancelled) };

    // Tries to transition from submitted to cancelled state and returns true if
    // succeed. This function should never be called from a worker thread.
    fn try_cancel(self: *OpStateMachine) bool {
        const swapped = self.thread_state.swap(&cancelled, .seq_cst);
        if (swapped == &cancelled) return false; // already cancelled.
        if (swapped == &dead) return false; // already completed.
        if (swapped == &submitted) return true; // early cancel.

        // transition local thread state from submitted to cancelled.
        return swapped.state.cmpxchgStrong(
            .submitted,
            .cancelled,
            .seq_cst,
            .seq_cst,
        ) == null;
    }
};

/// ThreadStateMachine defines state machine of an Operation executed on a
/// worker thread.
const ThreadStateMachine = struct {
    state: std.atomic.Value(operation.State) = .init(.submitted),

    /// Tries to synchronizes state with one stored on thread stack. This fails
    /// if task is already cancelled.
    fn try_sync(
        self: *ThreadStateMachine,
        op_state: *OpStateMachine,
    ) bool {
        return op_state.thread_state.cmpxchgStrong(
            &OpStateMachine.submitted, // static
            self, // non static
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    // Tries to transition from submitted to cancelled state and returns true if
    // succeed.
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

    for (0..100) |_| {
        S.called = 0;
        S.sleepCallbackData = null;
        S.cancelCallbackData = null;

        var b: Self = undefined;
        b.init();
        defer b.deinit();

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

        try std.Thread.yield();
        var timer = try std.time.Timer.start();
        var done: usize = 0;
        var iter: usize = 0;
        while (@max(done, iter) != 2) {
            done += b.poll();
            iter += 1;
        }
        const ns = timer.read();

        try std.testing.expect(done == 2);
        try std.testing.expect(S.called == 2);
        S.sleepCallbackData.?.result catch { // cancelled
            n |= 1;
            return;
        };
        n |= 2;
        try std.testing.expect(ns >= 5 * std.time.ns_per_ms);
    }

    try std.testing.expect(n == 3);
}

test "open file" {
    const S = struct {
        var f: ?std.fs.File = null;

        fn callback(_: *anyopaque, data: operation.Data.of(.open_file)) void {
            f = data.result catch unreachable;
        }
    };

    for (0..100) |_| {
        S.f = null;

        var b: Self = undefined;
        b.init();
        defer b.deinit();

        var fopen = Operation.init(.{ .open_file = .{
            .dir = std.fs.cwd(),
            .sub_path = "./src/testdata/file.txt",
            .flags = .{ .mode = .read_only },
            .callback = &S.callback,
        } });

        b.submit(&fopen);

        const done = b.poll();

        try std.testing.expect(done == 1);

        var buf: [1028]u8 = undefined;
        var reader = S.f.?.reader(buf[0..buf.len]);
        const r = try reader.read(buf[0..buf.len]);
        try std.testing.expectEqualStrings("Hello from text file!\n", buf[0..r]);
    }
}

test "cancel open file" {
    const S = struct {
        fn openFileCallback(
            _: *anyopaque,
            data: operation.Data.of(.open_file),
        ) void {
            _ = data.result catch |err| {
                std.debug.assert(err == error.CancelError);
                return;
            };
            // unreachable;
        }

        fn cancelCallback(
            _: *anyopaque,
            _: operation.Data.of(.cancel),
        ) void {}
    };

    for (0..100) |_| {
        var b: Self = undefined;
        b.init();
        defer b.deinit();

        var fopen = Operation.init(.{ .open_file = .{
            .dir = std.fs.cwd(),
            .sub_path = "./src/testdata/file.txt",
            .flags = .{ .mode = .read_only },
            .callback = &S.openFileCallback,
        } });
        var cancel = Operation.init(.{ .cancel = .{
            .op = &fopen,
            .callback = &S.cancelCallback,
        } });

        b.submit(&fopen);
        try std.Thread.yield();
        b.submit(&cancel);

        var done: usize = 0;
        var iter: usize = 0;
        while (@max(done, iter) != 2) {
            done += b.poll();
            iter += 1;
        }

        try std.testing.expect(done == 2);
    }
}

test "schedule cancelled open file" {
    const S = struct {
        fn openFileCallback(
            ptr: *anyopaque,
            data: operation.Data.of(.open_file),
        ) void {
            const op: *Operation = @ptrCast(@alignCast(ptr));
            _ = data.result catch |err| {
                std.debug.assert(err == error.CancelError);
                op.owner.submit(op);
                return;
            };
            // unreachable;
        }

        fn cancelCallback(
            _: *anyopaque,
            _: operation.Data.of(.cancel),
        ) void {}
    };

    for (0..100) |_| {
        var b: Self = undefined;
        b.init();
        defer b.deinit();

        var fopen = Operation.init(.{ .open_file = .{
            .dir = std.fs.cwd(),
            .sub_path = "./src/testdata/file.txt",
            .flags = .{ .mode = .read_only },
            .callback = &S.openFileCallback,
        } });
        var cancel = Operation.init(.{ .cancel = .{
            .op = &fopen,
            .callback = &S.cancelCallback,
        } });

        b.submit(&fopen);
        try std.Thread.yield();
        b.submit(&cancel);

        var done: usize = 0;
        var iter: usize = 0;
        while (@max(done, iter) != 5) {
            done += b.poll();
            iter += 1;
        }

        try std.testing.expect(done >= 2);
    }
}

test "open then read file" {
    const S = struct {
        var b: Self = undefined;
        var pread: Operation = undefined;
        var buf: [1028]u8 = undefined;
        var read: usize = 0;

        fn openFileCallback(
            _: *anyopaque,
            data: operation.Data.of(.open_file),
        ) void {
            const f = data.result catch unreachable;
            pread = .init(.{ .pread = .{
                .f = f,
                .buf = buf[0..buf.len],
                .offset = 0,
                .callback = preadFileCallback,
            } });
            b.submit(&pread);
        }
        fn preadFileCallback(
            _: *anyopaque,
            data: operation.Data.of(.pread),
        ) void {
            read = data.result catch unreachable;
        }
    };

    S.b.init();
    defer S.b.deinit();

    var fopen = Operation.init(.{ .open_file = .{
        .dir = std.fs.cwd(),
        .sub_path = "./src/testdata/file.txt",
        .flags = .{ .mode = .read_only },
        .callback = &S.openFileCallback,
    } });

    S.b.submit(&fopen);

    var done: usize = 0;
    var iter: usize = 0;
    while (@max(done, iter) != 2) {
        done += S.b.poll();
        iter += 1;
    }

    try std.testing.expect(done == 2);
    try std.testing.expectEqualStrings("Hello from text file!\n", S.buf[0..S.read]);
}
