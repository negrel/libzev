const std = @import("std");

const ThreadPool = @import("../ThreadPool.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const queue = @import("../queue.zig");
const ring = @import("../ring.zig");
const op = @import("../op.zig");

/// ThreadPoolImpl defines a thread pool based implementation of Io.
pub fn ThreadPoolImpl(capacity: usize) type {
    return struct {
        const Self = @This();

        tpool: ThreadPool = .init(.{}),
        sq: ring.Buffer(Sqe, capacity),
        cq: ring.Buffer(Cqe, capacity),
        futex: *std.atomic.Value(u32) = .init(0),

        // Recent SQE.
        sqe: ?*Sqe,

        /// Returns submission queue entry if one is available.
        pub fn getSqe(self: *Self) ?*Sqe {
            const sqe = self.sq.push() orelse return null;
            sqe.* = .{};
            if (self.sqe) |e| sqe.task.node = e.task.node;
            self.sqe = sqe;
        }

        /// Submits all entries in submission queue.
        pub fn submit(self: *Self) void {
            if (self.sqe) |e| {
                self.tpool.schedule(ThreadPool.Batch.from(e.task));
                self.sqe = null;
            }
        }

        /// Waits for I/O submission to complete.
        pub fn wait(self: *Self, min_complete: u32) u32 {
            min_complete = @min(min_complete, self.active);
            if (min_complete == 0) return;

            self.futex.store(min_complete, .seq_cst);
            std.Thread.Futex.wait(&self.futex, 0);
        }

        /// Retrieves an I/O completion if any.
        pub fn getCqe(self: *Self) ?*Cqe {
            return self.cq.peek();
        }

        /// Submission queue entry.
        pub const Sqe = struct {
            // Public fields.
            data: op.Data,
            user_data: *anyopaque,

            // Private fields.
            task: ThreadPool.Task = .{},
        };

        /// Completion queue entry.
        pub const Cqe = struct {
            result: op.Completion,
            user_data: *anyopaque,
        };
    };
}

test "noop" {
    const Io = ThreadPoolImpl(1024);
    const io: Io = .{};

    const empty = struct {};

    for (0..1024) |_| {
        io.getSqe().?.* = .{
            .data = .{ .noop = undefined },
            .user_data = @ptrCast(&empty),
        };
    }

    const done = io.wait(1024);

    try std.testing.expect(done == 1024);
}
