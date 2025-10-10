//! This file contains thread pool based backend.

const std = @import("std");

const ThreadPool = @import("../ThreadPool.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const operation = @import("../operation.zig");

const Self = @This();

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
    std.debug.assert(self.done.head == self.done.stub);
    self.done.init();
    self.tpool.deinit();
}

/// Submits an I/O operation on thread pool.
pub fn submit(self: *Self, op: *Operation) void {
    std.debug.assert(op.state == .dead);
    op.owner = self;
    op.state = .submitted;

    const batch = ThreadPool.Batch.from(&op.task);
    self.tpool.schedule(batch);
    self.pending += 1;
}

/// Polls until a scheduled I/O operation completes. If there is none, this
/// function returns without blocking.
pub fn poll(self: *Self) usize {
    var done: usize = 0;
    while (self.done.pop()) |op| {
        op.state = .dead;
        op.callback(@ptrCast(op));
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
const Operation = struct {
    owner: *Self = undefined,
    state: operation.State = .dead,
    task: ThreadPool.Task = .{
        .node = .{ .next = null },
        .callback = struct {
            fn callback(t: *ThreadPool.Task) void {
                const op: *Operation = @fieldParentPtr("task", t);
                op.block();
            }
        }.callback,
    },

    data: union(operation.Type) {
        sleep: struct { ns: u64 },
    },

    // Callback executed after completion.
    callback: operation.Callback,

    // Intrusive linked list next field.
    next: ?*Operation = null,

    /// Execute blocking I/O operation.
    fn block(self: *Operation) void {
        switch (self.data) {
            .sleep => |data| std.Thread.sleep(data.ns),
        }

        self.owner.done.push(self);
        std.Thread.Futex.wake(&self.owner.futex, 1);
    }
};

test "sleep" {
    const Static = struct {
        var called = false;

        fn callback(_: *anyopaque) void {
            called = true;
        }
    };

    var b: Self = undefined;
    b.init();

    var op: Operation = .{
        .data = .{ .sleep = .{ .ns = 5 * std.time.ns_per_ms } },
        .callback = &Static.callback,
    };

    b.submit(&op);

    var timer = try std.time.Timer.start();
    _ = b.poll();
    const ns = timer.read();

    try std.testing.expect(ns >= 5 * std.time.ns_per_ms);
    try std.testing.expect(Static.called);
}
