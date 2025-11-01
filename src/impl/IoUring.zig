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
    std.debug.assert(@typeInfo(@TypeOf(op)) == .pointer);

    if (self.tpool.batch.len + self.sqe_len + 1 == std.math.maxInt(u32)) {
        return io.QueueError.SubmissionQueueFull;
    }

    switch (op.header.code) {
        .getcwd => {
            _ = try self.tpool.queue(op);
        },
        .chdir => {
            _ = try self.tpool.queue(op);
        },
        else => {
            try self.queueOpHeader(&op.header);
            self.sqe_len += 1;
        },
    }

    return self.sqe_len + @as(u32, @intCast(self.tpool.batch.len));
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
                d.dir,
                d.path,
                os_flags,
                d.permissions,
            );
        },
        .close => {
            const close_op = Op(io.Close).fromHeaderUnsafe(op_h);
            sqe.prep_close(close_op.data.file);
        },
        .pread => {
            const pread_op = Op(io.PRead).fromHeaderUnsafe(op_h);
            const d = pread_op.data;
            sqe.prep_read(d.file, d.buffer[0..d.buffer_len], d.offset);
        },
        .pwrite => {
            const pwrite_op = Op(io.PWrite).fromHeaderUnsafe(op_h);
            const d = pwrite_op.data;
            sqe.prep_write(d.file, d.buffer[0..d.buffer_len], d.offset);
        },
        .fsync => {
            const fsync_op = Op(io.FSync).fromHeaderUnsafe(op_h);
            sqe.prep_fsync(fsync_op.data.file, 0);
        },
        .stat => {
            const stat_op = Op(io.Stat).fromHeaderUnsafe(op_h);
            sqe.prep_statx(
                stat_op.data.file,
                "",
                linux.AT.EMPTY_PATH,
                linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_ATIME |
                    linux.STATX_MTIME | linux.STATX_CTIME,
                &stat_op.private.uring_data,
            );
        },
        .getcwd, .chdir => unreachable,
        .unlinkat => {
            const unlinkat_op = Op(io.UnlinkAt).fromHeaderUnsafe(op_h);
            sqe.prep_unlinkat(
                unlinkat_op.data.dir,
                unlinkat_op.data.path,
                if (unlinkat_op.data.remove_dir) posix.AT.REMOVEDIR else 0,
            );
        },
        .socket => {
            const socket_op = Op(io.Socket).fromHeaderUnsafe(op_h);
            sqe.prep_socket(
                @intFromEnum(socket_op.data.domain),
                @intFromEnum(socket_op.data.protocol),
                @intFromEnum(socket_op.data.protocol),
                0,
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
        return submitted + try self.tpool.submit();
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

            switch (op_h.code) {
                .noop, .timeout => {},
                .openat => {
                    const op = Op(io.OpenAt).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
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
                        });
                    } else {
                        op.data.file = cqe.res;
                    }
                },
                .close => {},
                .pread => {
                    const op = Op(io.PRead).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
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
                        });
                    } else {
                        op.data.read = @intCast(cqe.res);
                    }
                },
                .pwrite => {
                    const op = Op(io.PWrite).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
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
                        });
                    } else {
                        op.data.write = @intCast(cqe.res);
                        op.data.err_code = 0;
                    }
                },
                .fsync => {
                    const op = Op(io.PWrite).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
                            .BADF, .INVAL, .ROFS => unreachable,
                            .IO => error.InputOutput,
                            .NOSPC => error.NoSpaceLeft,
                            .DQUOT => error.DiskQuota,
                            else => |err| posix.unexpectedErrno(err),
                        });
                    }
                },
                .stat => {
                    const op = Op(io.Stat).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
                            .ACCES => unreachable,
                            .BADF => unreachable,
                            .FAULT => unreachable,
                            .INVAL => unreachable,
                            .LOOP => unreachable,
                            .NAMETOOLONG => unreachable,
                            .NOENT => unreachable,
                            .NOMEM => error.SystemResources,
                            .NOTDIR => unreachable,
                            else => |err| posix.unexpectedErrno(err),
                        });
                    } else {
                        const std_stat = std.fs.File.Stat.fromLinux(
                            op.private.uring_data,
                        );
                        op.data.stat = .fromStdFsFileStat(std_stat);
                    }
                },
                .getcwd, .chdir => unreachable,
                .unlinkat => {
                    const op = Op(io.UnlinkAt).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
                            .ACCES => error.AccessDenied,
                            .PERM => error.PermissionDenied,
                            .BUSY => error.FileBusy,
                            .FAULT => unreachable,
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
                            // invalid flags, or pathname has '.' as last
                            // component
                            .INVAL => unreachable,
                            // always a race condition
                            .BADF => unreachable,
                            else => |err| posix.unexpectedErrno(err),
                        });
                    }
                },
                .socket => {
                    const op = Op(io.UnlinkAt).fromHeaderUnsafe(op_h);
                    if (cqe.res < 0) {
                        const rc = errno(cqe.res);
                        op.data.err_code = @intFromError(switch (rc) {
                            .ACCES => error.AccessDenied,
                            .AFNOSUPPORT => error.AddressFamilyNotSupported,
                            .INVAL => error.ProtocolFamilyNotAvailable,
                            .MFILE => error.ProcessFdQuotaExceeded,
                            .NFILE => error.SystemFdQuotaExceeded,
                            .NOBUFS => error.SystemResources,
                            .NOMEM => error.SystemResources,
                            .PROTONOSUPPORT => error.ProtocolNotSupported,
                            .PROTOTYPE => error.SocketTypeNotSupported,
                            else => |err| posix.unexpectedErrno(err),
                        });
                    }
                },
            }

            op_h.callback(op_h);
        }
        self.active -= done;

        return done + try self.tpool.poll(switch (mode) {
            .all => .all,
            .one => if (done == 0) .one else .nowait,
            .nowait => .nowait,
        });
    }
}

fn errno(err_code: i32) linux.E {
    return posix.errno(@as(isize, @intCast(err_code)));
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
    const UringData = if (T == io.TimeOut) T: {
        break :T linux.kernel_timespec;
    } else if (T == io.Stat) T: {
        break :T linux.Statx;
    } else if (T == io.GetCwd) {
        return ThreadPool.OpPrivateData(T);
    } else if (T == io.ChDir) {
        return ThreadPool.OpPrivateData(T);
    } else void;

    return extern struct {
        // Must be at end of struct so we can access field that doesn't depend
        // on T.
        uring_data: UringData = undefined,

        pub fn init(_: anytype) OpPrivateData(T) {
            return .{};
        }
    };
}

pub const noOp = io.noOp(Io);
pub const timeOut = io.timeOut(Io);
pub const openAt = io.openAt(Io);
pub const close = io.close(Io);
pub const pRead = io.pRead(Io);
pub const pWrite = io.pWrite(Io);
pub const fSync = io.fSync(Io);
pub const stat = io.stat(Io);
pub const getCwd = io.getCwd(Io);
pub const chDir = io.chDir(Io);
pub const unlinkAt = io.unlinkAt(Io);
