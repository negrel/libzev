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
// Number of entry in the submission queue (but not submitted).
sqe_len: u32 = 0,
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

pub fn queue(self: *Io, op: anytype) io.QueueError!u32 {
    try self.queueOpHeader(&op.header);
    self.sqe_len += 1;
    return self.sqe_len;
}

fn queueOpHeader(self: *Io, op_h: *io.OpHeader) io.QueueError!void {
    const sqe = try self.ring.get_sqe();

    // Prepare entry.
    switch (op_h.code) {
        .noop => sqe.prep_nop(),
        .timeout => {
            const timeout_op = Op(io.TimeOut).fromHeaderUnsafe(op_h);
            timeout_op.private.uring_data = msToTimespec(timeout_op.data.ms);

            sqe.prep_timeout(
                &timeout_op.private.uring_data,
                1,
                linux.IORING_TIMEOUT_ABS,
            );
        },
        .openat => {
            const openat_op = Op(io.OpenAt).fromHeaderUnsafe(op_h);
            const d = openat_op.data;
            const opts = d.opts;
            var os_flags: posix.O = .{
                .CLOEXEC = true,
                .APPEND = opts.append,
                .TRUNC = opts.truncate,
                .CREAT = opts.create or opts.create_new,
                .EXCL = opts.create_new,
                .ACCMODE = .RDONLY,
            };
            if (opts.write) {
                if (opts.read) os_flags.ACCMODE = .RDWR else {
                    os_flags.ACCMODE = .WRONLY;
                }
            }
            sqe.prep_openat(
                linux.AT.FDCWD,
                d.path,
                os_flags,
                d.permissions,
            );
        },
    }
    sqe.user_data = @intFromPtr(op_h);
}

pub fn submit(self: *Io) io.SubmitError!u32 {
    var submitted: u32 = 0;
    while (true) {
        submitted += self.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            error.SystemResources => return error.SystemResources,
            error.CompletionQueueOvercommitted => {
                return error.CompletionQueueOvercommitted;
            },
            error.SubmissionQueueEntryInvalid => return error.InvalidOp,
            error.FileDescriptorInvalid,
            error.FileDescriptorInBadState,
            error.BufferInvalid,
            error.RingShuttingDown,
            error.OpcodeNotSupported,
            error.Unexpected,
            => {
                return io.SubmitError.Unexpected;
            },
        };

        self.sqe_len -= submitted;
        self.active += submitted;
        return submitted;
    }
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

            const op = Op(io.NoOp).fromHeaderUnsafe(op_h);
            op.private.callback(&op.header);
        }
        self.active -= done;

        return done + try self.tpool.poll(switch (mode) {
            .all => .all,
            .one => if (done == 0) .one else .nowait,
            .nowait => .nowait,
        });
    }
}

comptime {
    // Safety: ensure we can cast *io.OpHeader to *Op(NoOp) to retrieve
    // OpPrivateData when T is unknown.
    if (@offsetOf(Op(io.NoOp), "private") !=
        @offsetOf(Op(io.TimeOut), "private"))
    {
        @compileError("Op(Io).private offset depends on T");
    }

    // Safety: ensure we can safely access OpPrivateData.user_data when T is
    // unknown.
    if (@offsetOf(OpPrivateData(io.NoOp), "user_data") !=
        @offsetOf(OpPrivateData(io.TimeOut), "user_data"))
    {
        @compileError("OpPrivateData(T).user_data offset depends on T");
    }

    // Safety: ensure we can safely access OpPrivateData.callback when T is
    // unknown.
    if (@offsetOf(OpPrivateData(io.NoOp), "callback") !=
        @offsetOf(OpPrivateData(io.TimeOut), "callback"))
    {
        @compileError("OpPrivateData(T).callback offset depends on T");
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
        callback: *const fn (op_h: *io.OpHeader) callconv(.c) void,
        user_data: ?*anyopaque,

        // Must be at end of struct so we can access field that doesn't depend
        // on T.
        uring_data: UringData = undefined,

        pub fn init(opts: anytype) OpPrivateData(T) {
            return .{
                .callback = opts.callback,
                .user_data = opts.user_data,
            };
        }
    };
}

pub const noop = io.noOp(Io);
pub const timeout = io.timeOut(Io);
