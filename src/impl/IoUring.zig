//! io_uring based implementation of Io.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const io = @import("../io.zig");

const Self = @This();

ring: linux.IoUring = undefined,

// Number of entry submitted to the kernel and not polled (yet).
active: u32 = 0,

pub fn init(self: *Self, opts: Options) !void {
    self.* = .{};

    if (opts.params) |p| self.ring = try linux.IoUring.init_params(
        opts.entries,
        p,
    ) else self.ring = try linux.IoUring.init(opts.entries, 0);
}

pub fn deinit(self: *Self) void {
    self.ring.deinit();
}

pub fn submit(self: *Self, iop: *Op) !void {
    try self.submitBatch(Batch.from(iop));
}

pub fn submitBatch(self: *Self, batch: Batch) !void {
    var b = batch;
    while (b.pop()) |iop| {
        self.enqueue(iop) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                try self.submitSQ();
                self.enqueue(iop) catch unreachable;
            },
        };
    }

    try self.submitSQ();
}

fn submitSQ(self: *Self) !void {
    while (true) {
        self.active += self.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        return;
    }
}

fn enqueue(self: *Self, iop: *Op) !void {
    const sqe = try self.ring.get_sqe();

    // Prepare entry.
    switch (iop.data) {
        .noop => sqe.prep_nop(),
        .timeout => sqe.prep_timeout(
            &iop.data.timeout,
            1,
            linux.IORING_TIMEOUT_ABS,
        ),
        .openat => |d| sqe.prep_openat(
            linux.AT.FDCWD,
            d.path,
            d.flags,
            d.mode,
        ),
        .close => |d| sqe.prep_close(d.file.handle),
        .pread => |d| sqe.prep_read(d.file.handle, d.buffer, d.offset),
        .pwrite => |d| sqe.prep_write(d.file.handle, d.buffer, d.offset),
    }
    sqe.user_data = @intFromPtr(iop);
}

pub fn poll(self: *Self, mode: io.PollMode) !u32 {
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
            const op: *Op = @ptrFromInt(cqe.user_data);
            switch (op.data) {
                .noop => {},
                .timeout => {},
                .openat => |*d| {
                    if (cqe.res < 0) {
                        const rc = @as(posix.E, @enumFromInt(-cqe.res));
                        d.file = switch (rc) {
                            .INTR => unreachable,
                            .FAULT => unreachable,
                            .INVAL => error.BadPathName,
                            .BADF => unreachable,
                            .ACCES => error.AccessDenied,
                            .FBIG => error.FileTooBig,
                            .OVERFLOW => error.FileTooBig,
                            .ISDIR => error.IsDir,
                            .LOOP => error.SymLinkLoop,
                            .MFILE => error.ProcessFdQuotaExceeded,
                            .NAMETOOLONG => error.NameTooLong,
                            .NFILE => error.SystemFdQuotaExceeded,
                            .NODEV => error.NoDevice,
                            .NOENT => error.FileNotFound,
                            .SRCH => error.ProcessNotFound,
                            .NOMEM => error.SystemResources,
                            .NOSPC => error.NoSpaceLeft,
                            .NOTDIR => error.NotDir,
                            .PERM => error.PermissionDenied,
                            .EXIST => error.PathAlreadyExists,
                            .BUSY => error.DeviceBusy,
                            .OPNOTSUPP => error.FileLocksNotSupported,
                            .AGAIN => error.WouldBlock,
                            .TXTBSY => error.FileBusy,
                            .NXIO => error.NoDevice,
                            .ILSEQ => |err| if (builtin.os.tag == .wasi)
                                error.InvalidUtf8
                            else
                                posix.unexpectedErrno(err),
                            else => |err| posix.unexpectedErrno(err),
                        };
                    } else d.file = .{ .handle = cqe.res };
                },
                .close => {},
                .pread => |*d| {
                    if (cqe.res < 0) {
                        const rc = @as(posix.E, @enumFromInt(-cqe.res));
                        d.read = switch (rc) {
                            .INTR => unreachable,
                            .INVAL => unreachable,
                            .FAULT => unreachable,
                            .SRCH => error.ProcessNotFound,
                            .AGAIN => error.WouldBlock,
                            .CANCELED => error.Canceled,
                            // Can be a race condition.
                            .BADF => error.NotOpenForReading,
                            .IO => error.InputOutput,
                            .ISDIR => error.IsDir,
                            .NOBUFS => error.SystemResources,
                            .NOMEM => error.SystemResources,
                            .NOTCONN => error.SocketNotConnected,
                            .CONNRESET => error.ConnectionResetByPeer,
                            .TIMEDOUT => error.ConnectionTimedOut,
                            else => |err| posix.unexpectedErrno(err),
                        };
                    } else {
                        d.read = @intCast(cqe.res);
                    }
                },
                .pwrite => |*d| {
                    if (cqe.res < 0) {
                        const rc = @as(posix.E, @enumFromInt(-cqe.res));
                        d.write = switch (rc) {
                            .INTR => unreachable,
                            .INVAL => error.InvalidArgument,
                            .FAULT => unreachable,
                            .SRCH => error.ProcessNotFound,
                            .AGAIN => error.WouldBlock,
                            // can be a race condition.
                            .BADF => error.NotOpenForWriting,
                            // `connect` was never called.
                            .DESTADDRREQ => unreachable,
                            .DQUOT => error.DiskQuota,
                            .FBIG => error.FileTooBig,
                            .IO => error.InputOutput,
                            .NOSPC => error.NoSpaceLeft,
                            .ACCES => error.AccessDenied,
                            .PERM => error.PermissionDenied,
                            .PIPE => error.BrokenPipe,
                            .CONNRESET => error.ConnectionResetByPeer,
                            .BUSY => error.DeviceBusy,
                            .NXIO => error.NoDevice,
                            .MSGSIZE => error.MessageTooBig,
                            else => |err| posix.unexpectedErrno(err),
                        };
                    } else {
                        d.write = @intCast(cqe.res);
                    }
                },
            }

            op.callback(op);
        }
        self.active -= done;

        return done;
    }
}

pub fn noop(
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .noop = undefined },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn timeout(
    ms: u64,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .timeout = msToTimespec(ms) },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn openat(
    dir: std.fs.Dir,
    path: [:0]const u8,
    opts: io.OpenOptions,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
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

    return .{
        .data = .{ .openat = .{
            .dirfd = dir.fd,
            .path = path,
            .flags = os_flags,
            .mode = opts.mode,
        } },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn close(
    file: std.fs.File,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .close = .{ .file = file } },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn pread(
    file: std.fs.File,
    buf: []u8,
    offset: u64,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .pread = .{
            .file = file,
            .buffer = buf,
            .offset = offset,
        } },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn pwrite(
    file: std.fs.File,
    buf: []const u8,
    offset: u64,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .pwrite = .{
            .file = file,
            .buffer = buf,
            .offset = offset,
        } },
        .user_data = user_data,
        .callback = callback,
    };
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

/// An entry in the submission queue.
pub const Op = struct {
    data: union(io.OpCode) {
        noop: void,
        timeout: linux.kernel_timespec,
        openat: struct {
            dirfd: linux.fd_t,
            path: [*:0]const u8,
            flags: linux.O,
            mode: linux.mode_t,

            file: std.fs.File.OpenError!std.fs.File = undefined,
        },
        close: struct { file: std.fs.File },
        pread: struct {
            file: std.fs.File,
            buffer: []u8,
            offset: u64,
            read: std.fs.File.ReadError!usize = undefined,
        },
        pwrite: struct {
            file: std.fs.File,
            buffer: []const u8,
            offset: u64,
            write: std.fs.File.PWriteError!usize = undefined,
        },
    },
    callback: *const fn (*Op) void,
    user_data: ?*anyopaque,

    // Intrusive queue next field.
    node: Batch.Node = .{},
};
pub const Options = struct {
    entries: u16 = 256,
    params: ?*linux.io_uring_params = null,
};
pub const Batch = io.Batch(Self);
