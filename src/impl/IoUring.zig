//! io_uring based implementation of Io.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const io = @import("../io.zig");
const ThreadPool = @import("./ThreadPool.zig");

const Io = @This();

ring: linux.IoUring = undefined,

// Number of entry submitted to the kernel and not polled (yet).
active: u32 = 0,

// Blocking task not supported by io_uring run on the thread pool.
tpool: ThreadPool = undefined,

pub fn init(self: *Io, opts: Options) !void {
    self.* = .{};

    if (opts.params) |p| self.ring = try linux.IoUring.init_params(
        opts.entries,
        p,
    ) else self.ring = try linux.IoUring.init(opts.entries, 0);

    try self.tpool.init(opts.thread_pool);
}

pub fn deinit(self: *Io) void {
    self.ring.deinit();
}

pub fn submit(self: *Io, iop: anytype) !void {
    try self.submitBatch(io.Batch.from(iop));
}

pub fn submitBatch(self: *Io, batch: io.Batch) !void {
    var b = batch;
    while (b.pop()) |op_h| {
        self.enqueue(op_h) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                try self.submitSQ();
                self.enqueue(op_h) catch unreachable;
            },
        };
    }

    try self.submitSQ();
}

fn submitSQ(self: *Io) !void {
    while (true) {
        self.active += self.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        return;
    }
}

fn enqueue(self: *Io, iop: *io.OpHeader) !void {
    const sqe = try self.ring.get_sqe();

    // Prepare entry.
    switch (iop.code) {
        .noop => sqe.prep_nop(),
        .timeout => {
            const timeout_op = Op(io.TimeOut).fromHeaderUnsafe(iop);
            timeout_op.private.uring_data = msToTimespec(timeout_op.data.ms);

            sqe.prep_timeout(
                &timeout_op.private.uring_data,
                1,
                linux.IORING_TIMEOUT_ABS,
            );
        },
    }
    sqe.user_data = @intFromPtr(iop);
}

pub fn poll(self: *Io, mode: io.PollMode) !u32 {
    var cqes: [256]linux.io_uring_cqe = undefined;
    while (true) {
        const done = self.ring.copy_cqes(
            cqes[0..cqes.len],
            switch (mode) {
                .all => @min(self.active, cqes.len),
                .one => @min(self.active, 1),
                .nowait => 0,
            },
        ) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        for (0..done) |i| {
            const cqe = cqes[i];
            const op_h: *io.OpHeader = @ptrFromInt(cqe.user_data);
            switch (op_h.code) {
                .noop => {
                    const op = Op(io.NoOp).fromHeaderUnsafe(op_h);
                    op.private.callback(op.data);
                },
                .timeout => {
                    const op = Op(io.TimeOut).fromHeaderUnsafe(op_h);
                    op.private.callback(op.data);
                },
            }
        }
        self.active -= done;

        return done + try self.tpool.poll(switch (mode) {
            .all => .all,
            .one => if (done == 0) .one else .nowait,
            .nowait => .nowait,
        });
    }
}

fn msToTimespec(ms: u64) linux.kernel_timespec {
    const max: linux.kernel_timespec = .{
        .sec = std.math.maxInt(isize),
        .nsec = std.math.maxInt(isize),
    };
    const next_s = std.math.cast(isize, ms / std.time.ms_per_s) orelse
        return max;
    const next_ns = std.math.cast(
        isize,
        (ms % std.time.ms_per_s) * std.time.ns_per_ms,
    ) orelse return max;

    const now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch unreachable;

    return .{
        .sec = std.math.add(isize, now.sec, next_s) catch return max,
        .nsec = std.math.add(isize, now.nsec, next_ns) catch return max,
    };
}

pub const Options = struct {
    entries: u16 = 256,
    params: ?*linux.io_uring_params = null,
    thread_pool: ThreadPool.Options = .{},
};

pub fn Op(T: type) type {
    return io.Op(Io, T);
}

/// I/O operation data specific to this ThreadPool.
pub fn OpPrivateData(T: type) type {
    const UringData = if (T.op_code == io.OpCode.timeout) T: {
        break :T linux.kernel_timespec;
    } else void;

    return extern struct {
        callback: *const fn (T) callconv(.c) void,
        user_data: ?*anyopaque,

        uring_data: UringData = undefined,

        pub fn init(opts: anytype) OpPrivateData(T) {
            return .{
                .callback = opts.callback,
                .user_data = opts.user_data,
            };
        }
    };
}

pub const noop = io.noop(Io);
pub const timeout = io.timeout(Io);
