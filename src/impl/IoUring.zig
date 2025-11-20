//! io_uring based implementation of Io.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const posix = @import("../posix.zig");
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
    comptime {
        std.debug.assert(
            std.mem.startsWith(u8, @typeName(@TypeOf(op)), "*io.Op("),
        );
    }

    if (self.tpool.batch.len + self.sqe_len + 1 == std.math.maxInt(u32)) {
        return io.QueueError.SubmissionQueueFull;
    }

    switch (@TypeOf(op)) {
        *Op(io.GetCwd), *Op(io.ChDir), *Op(io.Spawn) => {
            _ = try self.tpool.queue(op);
        },
        else => {
            try self.queueOpHeader(op);
            self.sqe_len += 1;
        },
    }

    return self.sqe_len + @as(u32, @intCast(self.tpool.batch.len));
}

fn queueOpHeader(self: *Io, op: anytype) io.QueueError!void {
    const sqe = try self.ring.get_sqe();

    // Prepare entry.
    switch (@TypeOf(op)) {
        *Op(io.NoOp) => sqe.prep_nop(),
        *Op(io.TimeOut) => {
            op.private.uring_data = msToTimespec(op.data.msec);

            sqe.prep_timeout(
                &op.private.uring_data,
                1,
                linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_ETIME_SUCCESS,
            );
        },
        *Op(io.OpenAt) => {
            const d = op.data;
            op.private.uring_data = std.posix.toPosixPath(d.path) catch
                [1:0]u8{0} ** (std.posix.PATH_MAX - 1);

            const flags: linux.O = .{
                .ACCMODE = switch (d.options.read) {
                    false => switch (d.options.write) {
                        false => .RDONLY,
                        true => .WRONLY,
                    },
                    true => switch (d.options.write) {
                        false => .RDONLY,
                        true => .RDWR,
                    },
                },
                .TRUNC = d.options.truncate,
                .CREAT = d.options.create or d.options.create_new,
                .EXCL = d.options.create_new,
                .APPEND = d.options.append,
                .CLOEXEC = true,
            };

            sqe.prep_openat(
                d.dir.fd,
                op.private.uring_data[0..],
                flags,
                d.mode,
            );
        },
        *Op(io.Close) => sqe.prep_close(op.data.file.handle),
        *Op(io.PRead) => sqe.prep_read(
            op.data.file.handle,
            op.data.buffer,
            @bitCast(op.data.offset),
        ),
        *Op(io.PWrite) => sqe.prep_write(
            op.data.file.handle,
            op.data.buffer,
            @bitCast(op.data.offset),
        ),
        *Op(io.FSync) => sqe.prep_fsync(op.data.file.handle, 0),
        *Op(io.FStat) => {
            sqe.prep_statx(
                op.data.file.handle,
                "",
                linux.AT.EMPTY_PATH,
                linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_ATIME |
                    linux.STATX_MTIME | linux.STATX_CTIME,
                &op.private.uring_data,
            );
        },
        *Op(io.GetCwd), *Op(io.ChDir) => unreachable,
        *Op(io.UnlinkAt) => {
            sqe.prep_unlinkat(
                op.data.dir,
                op.data.path,
                if (op.data.remove_dir) posix.AT.REMOVEDIR else 0,
            );
        },
        *Op(io.Spawn) => unreachable,
        *Op(io.WaitPid) => {
            sqe.prep_waitid(
                linux.P.PID,
                op.data.pid,
                &op.private.uring_data,
                linux.W.EXITED,
                0,
            );
        },
        else => unreachable,
    }
    sqe.user_data = @intFromPtr(&op.header);
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
        return submitted + try self.tpool.submit();
    }
}

pub fn poll(self: *Io, mode: io.PollMode) !u32 {
    var cqes: [256]linux.io_uring_cqe = undefined;
    var done: u32 = 0;
    while (true) {
        const copied = self.ring.copy_cqes(
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
        done += copied;

        for (cqes[0..copied]) |*cqe| {
            self.processCompletion(cqe);
        }

        if (copied < cqes.len) break;
    }

    self.active -= done;

    return done + try self.tpool.poll(switch (mode) {
        .all => .all,
        .one => if (done == 0) .one else .nowait,
        .nowait => .nowait,
    });
}

fn processCompletion(self: *Io, cqe: *linux.io_uring_cqe) void {
    const op_h: *io.OpHeader = @ptrFromInt(cqe.user_data);
    switch (op_h.code) {
        .noop => {},
        .timeout => {
            const op = Op(io.TimeOut).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.result = switch (rc) {
                    .SUCCESS, .TIME => undefined, // OK.
                    .CANCELED => error.Canceled,
                    .FAULT => error.BadAddress,
                    .INVAL => error.InvalidSyscallParameters,
                    .INTR => error.SignalInterrupt,
                    else => |err| posix.unexpectedErrno(err),
                };
            }
        },
        .openat => {
            const op = Op(io.OpenAt).fromHeader(op_h);
            op.data.result = ThreadPool.openAtErrorFromPosixErrno(
                @as(isize, @intCast(cqe.res)),
            );
        },
        .close => {
            const op = Op(io.Close).fromHeader(op_h);
            op.data.result = ThreadPool.closeErrorFromPosixErrno(
                @as(isize, @intCast(cqe.res)),
            );
        },
        .pread => {
            const op = Op(io.PRead).fromHeader(op_h);
            op.data.result = ThreadPool.preadErrorFromPosixErrno(
                @as(isize, @intCast(cqe.res)),
            );
        },
        .pwrite => {
            const op = Op(io.PWrite).fromHeader(op_h);
            op.data.result = ThreadPool.pwriteErrorFromPosixErrno(
                @as(isize, @intCast(cqe.res)),
            );
        },
        .fsync => {
            const op = Op(io.FSync).fromHeader(op_h);
            op.data.result = ThreadPool.fsyncErrorFromPosixErrno(
                @as(isize, @intCast(cqe.res)),
            );
        },
        .fstat => {
            const op = Op(io.FStat).fromHeader(op_h);
            ThreadPool.fstatErrorFromPosixErrno(
                @as(isize, @intCast(cqe.res)),
            ) catch |err| {
                op.data.result = err;
                return;
            };

            op.data.result = std.fs.File.Stat.fromLinux(op.private.uring_data);
        },
        .getcwd, .chdir => unreachable,
        .unlinkat => {
            const op = Op(io.UnlinkAt).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .ACCES => error.AccessDenied,
                    .PERM => error.PermissionDenied,
                    .BUSY => error.FileBusy,
                    .IO => error.FileSystem,
                    .ISDIR => error.IsDir,
                    .LOOP => error.SymLinkLoop,
                    .NAMETOOLONG => error.NameTooLong,
                    .NOENT => error.FileNotFound,
                    .NOTDIR => error.NotDir,
                    .NOMEM => error.SystemResources,
                    .ROFS => error.ReadOnlyFileSystem,
                    .EXIST => if (op.data.remove_dir)
                        error.DirNotEmpty
                    else
                        unreachable,
                    .NOTEMPTY => error.DirNotEmpty,
                    .ILSEQ => |err| if (builtin.os.tag == .wasi)
                        error.InvalidUtf8
                    else
                        posix.unexpectedErrno(err),
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
        .spawn => unreachable,
        .waitpid => {
            const op = Op(io.WaitPid).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .CHILD => error.NoChild,
                    .INTR => error.SignalInterrupt,
                    .INVAL => error.InvalidSyscallParameters,
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
    }

    op_h.callback(@ptrCast(self), @ptrCast(op_h));
}

fn errno(err_code: i32) linux.E {
    return posix.errno(@as(isize, @intCast(err_code)));
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
    const UringData = if (T == io.TimeOut) T: {
        break :T linux.kernel_timespec;
    } else if (T == io.OpenAt) T: {
        break :T [std.posix.PATH_MAX - 1:0]u8;
    } else if (T == io.FStat) T: {
        break :T linux.Statx;
    } else if (T == io.GetCwd) {
        return ThreadPool.OpPrivateData(T);
    } else if (T == io.ChDir) {
        return ThreadPool.OpPrivateData(T);
    } else if (T == io.Spawn) {
        return ThreadPool.OpPrivateData(T);
    } else if (T == io.WaitPid) T: {
        break :T linux.siginfo_t;
    } else void;

    return struct {
        // Must be at end of struct so we can access field that doesn't depend
        // on T.
        uring_data: UringData = undefined,

        pub fn init(_: anytype) OpPrivateData(T) {
            return .{};
        }
    };
}

pub const noOp = io.opInitOf(Io, io.NoOp);
pub const timeOut = io.opInitOf(Io, io.TimeOut);
pub const openAt = io.opInitOf(Io, io.OpenAt);
pub const close = io.opInitOf(Io, io.Close);
pub const pRead = io.opInitOf(Io, io.PRead);
pub const pWrite = io.opInitOf(Io, io.PWrite);
pub const fSync = io.opInitOf(Io, io.FSync);
pub const fStat = io.opInitOf(Io, io.FStat);
pub const getCwd = io.opInitOf(Io, io.GetCwd);
pub const chDir = io.opInitOf(Io, io.ChDir);
pub const unlinkAt = io.opInitOf(Io, io.UnlinkAt);
pub const spawn = io.opInitOf(Io, io.Spawn);
pub const waitPid = io.opInitOf(Io, io.WaitPid);

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
