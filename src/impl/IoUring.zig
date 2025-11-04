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
        std.debug.assert(@typeInfo(@TypeOf(op)) == .pointer);
        std.debug.assert(!@typeInfo(@TypeOf(op)).pointer.is_const);
    }

    if (self.tpool.batch.len + self.sqe_len + 1 == std.math.maxInt(u32)) {
        return io.QueueError.SubmissionQueueFull;
    }

    switch (op.header.code) {
        .getcwd, .chdir, .spawn => {
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
            const timeout_op = Op(io.TimeOut).fromHeader(op_h);
            timeout_op.private.uring_data = .{
                .sec = std.math.cast(isize, timeout_op.data.sec) orelse
                    std.math.maxInt(isize),
                .nsec = std.math.cast(isize, timeout_op.data.nsec) orelse
                    std.time.ns_per_s - 1,
            };

            sqe.prep_timeout(
                &timeout_op.private.uring_data,
                1,
                linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_ETIME_SUCCESS,
            );
        },
        .openat => {
            const openat_op = Op(io.OpenAt).fromHeader(op_h);
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
            const close_op = Op(io.Close).fromHeader(op_h);
            sqe.prep_close(close_op.data.file);
        },
        .pread => {
            const pread_op = Op(io.PRead).fromHeader(op_h);
            const d = pread_op.data;
            sqe.prep_read(d.file, d.buffer[0..d.buffer_len], d.offset);
        },
        .pwrite => {
            const pwrite_op = Op(io.PWrite).fromHeader(op_h);
            const d = pwrite_op.data;
            sqe.prep_write(d.file, d.buffer[0..d.buffer_len], d.offset);
        },
        .fsync => {
            const fsync_op = Op(io.FSync).fromHeader(op_h);
            sqe.prep_fsync(fsync_op.data.file, 0);
        },
        .stat => {
            const stat_op = Op(io.Stat).fromHeader(op_h);
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
            const unlinkat_op = Op(io.UnlinkAt).fromHeader(op_h);
            sqe.prep_unlinkat(
                unlinkat_op.data.dir,
                unlinkat_op.data.path,
                if (unlinkat_op.data.remove_dir) posix.AT.REMOVEDIR else 0,
            );
        },
        .socket => {
            const socket_op = Op(io.Socket).fromHeader(op_h);
            sqe.prep_socket(
                @intFromEnum(socket_op.data.domain),
                @intFromEnum(socket_op.data.socket_type),
                @intFromEnum(socket_op.data.protocol),
                0,
            );
        },
        .bind => {
            const bind_op = Op(io.Bind).fromHeader(op_h);
            sqe.prep_bind(
                bind_op.data.socket,
                bind_op.data.address,
                bind_op.data.address_len,
                0,
            );
        },
        .listen => {
            const listen_op = Op(io.Listen).fromHeader(op_h);
            sqe.prep_listen(
                listen_op.data.socket,
                listen_op.data.backlog,
                0,
            );
        },
        .accept => {
            const accept_op = Op(io.Accept).fromHeader(op_h);
            sqe.prep_accept(
                accept_op.data.socket,
                accept_op.data.address,
                accept_op.data.address_len,
                0,
            );
        },
        .connect => {
            const connect_op = Op(io.Connect).fromHeader(op_h);
            sqe.prep_connect(
                connect_op.data.socket,
                connect_op.data.address,
                connect_op.data.address_len,
            );
        },
        .shutdown => {
            const shutdown_op = Op(io.Shutdown).fromHeader(op_h);
            sqe.prep_shutdown(
                shutdown_op.data.socket,
                @intFromEnum(shutdown_op.data.how),
            );
        },
        .closesocket => {
            const closesocket_op = Op(io.CloseSocket).fromHeader(op_h);
            sqe.prep_close(closesocket_op.data.socket);
        },
        .recv => {
            const recv_op = Op(io.Recv).fromHeader(op_h);
            sqe.prep_recv(
                recv_op.data.socket,
                recv_op.data.buffer[0..recv_op.data.buffer_len],
                recv_op.data.flags,
            );
        },
        .send => {
            const send_op = Op(io.Send).fromHeader(op_h);
            sqe.prep_send(
                send_op.data.socket,
                send_op.data.buffer[0..send_op.data.buffer_len],
                send_op.data.flags,
            );
        },
        .spawn => unreachable,
        .waitpid => {
            const waitpid_op = Op(io.WaitPid).fromHeader(op_h);
            sqe.prep_waitid(
                linux.P.PID,
                waitpid_op.data.pid,
                &waitpid_op.private.uring_data,
                linux.W.EXITED,
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
                if (rc != .TIME)
                    op.data.err_code = @intFromError(switch (rc) {
                        .FAULT => posix.NanoSleepError.BadAddress,
                        .INVAL => posix.NanoSleepError.InvalidSyscallParameters,
                        .INTR => posix.NanoSleepError.SignalInterrupt,
                        else => |err| posix.unexpectedErrno(err),
                    });
            }
        },
        .openat => {
            const op = Op(io.OpenAt).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .INVAL => error.BadPathName,
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
            const op = Op(io.PRead).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
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
            const op = Op(io.PWrite).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .INVAL => error.InvalidArgument,
                    .SRCH => error.ProcessNotFound,
                    .AGAIN => error.WouldBlock,
                    // can be a race condition.
                    .BADF => error.NotOpenForWriting,
                    // `connect` was never called.
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
            const op = Op(io.FSync).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .IO => error.InputOutput,
                    .NOSPC => error.NoSpaceLeft,
                    .DQUOT => error.DiskQuota,
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
        .stat => {
            const op = Op(io.Stat).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .NOMEM => error.SystemResources,
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
        .socket => {
            const op = Op(io.Socket).fromHeader(op_h);
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
            } else {
                op.data.socket = cqe.res;
            }
        },
        .bind => {
            const op = Op(io.Bind).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .ACCES, .PERM => error.AccessDenied,
                    .ADDRINUSE => error.AddressInUse,
                    .AFNOSUPPORT => error.AddressFamilyNotSupported,
                    .ADDRNOTAVAIL => error.AddressNotAvailable,
                    .LOOP => error.SymLinkLoop,
                    .NAMETOOLONG => error.NameTooLong,
                    .NOENT => error.FileNotFound,
                    .NOMEM => error.SystemResources,
                    .NOTDIR => error.NotDir,
                    .ROFS => error.ReadOnlyFileSystem,
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
        .listen => {
            const op = Op(io.Listen).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .ADDRINUSE => error.AddressInUse,
                    .NOTSOCK => error.FileDescriptorNotASocket,
                    .OPNOTSUPP => error.OperationNotSupported,
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
        .accept => {
            const op = Op(io.Accept).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .AGAIN => error.WouldBlock,
                    .CONNABORTED => error.ConnectionAborted,
                    .INVAL => error.SocketNotListening,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    .NOBUFS => error.SystemResources,
                    .NOMEM => error.SystemResources,
                    .PROTO => error.ProtocolFailure,
                    .PERM => error.BlockedByFirewall,
                    else => |err| posix.unexpectedErrno(err),
                });
            } else {
                op.data.accepted_socket = @intCast(cqe.res);
            }
        },
        .connect => {
            const op = Op(io.Connect).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .ACCES => error.AccessDenied,
                    .PERM => error.PermissionDenied,
                    .ADDRINUSE => error.AddressInUse,
                    .ADDRNOTAVAIL => error.AddressNotAvailable,
                    .AFNOSUPPORT => error.AddressFamilyNotSupported,
                    .AGAIN, .INPROGRESS => error.WouldBlock,
                    .ALREADY => error.ConnectionPending,
                    .CONNREFUSED => error.ConnectionRefused,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .HOSTUNREACH => error.NetworkUnreachable,
                    .NETUNREACH => error.NetworkUnreachable,
                    .TIMEDOUT => error.ConnectionTimedOut,
                    // Returned when socket is AF.UNIX and the given
                    // path does not exist.
                    .NOENT => error.FileNotFound,
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
        .shutdown => {
            const op = Op(io.Shutdown).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .NOTCONN => error.SocketNotConnected,
                    .NOBUFS => error.SystemResources,
                    else => |err| posix.unexpectedErrno(err),
                });
            }
        },
        .closesocket => {},
        .recv => {
            const op = Op(io.Recv).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .NOTCONN => error.SocketNotConnected,
                    .AGAIN => error.WouldBlock,
                    .NOMEM => error.SystemResources,
                    .CONNREFUSED => error.ConnectionRefused,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .TIMEDOUT => error.ConnectionTimedOut,
                    else => |err| posix.unexpectedErrno(err),
                });
            } else op.data.recv = @intCast(cqe.res);
        },
        .send => {
            const op = Op(io.Send).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.err_code = @intFromError(switch (rc) {
                    .ACCES => error.AccessDenied,
                    .AGAIN => error.WouldBlock,
                    .ALREADY => error.FastOpenAlreadyInProgress,
                    .CONNREFUSED => error.ConnectionRefused,
                    .CONNRESET => error.ConnectionResetByPeer,
                    // connection-mode socket was connected already but
                    // a recipient was specified
                    .MSGSIZE => error.MessageTooBig,
                    .NOBUFS => error.SystemResources,
                    .NOMEM => error.SystemResources,
                    // Some bit in the flags argument is inappropriate
                    // for the socket type.
                    .PIPE => error.BrokenPipe,
                    .LOOP => error.SymLinkLoop,
                    .NOENT => error.FileNotFound,
                    .NOTDIR => error.NotDir,
                    .NOTCONN => error.SocketNotConnected,
                    .NETDOWN => error.NetworkSubsystemFailed,
                    else => |err| posix.unexpectedErrno(err),
                });
            } else op.data.send = @intCast(cqe.res);
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

    op_h.callback(self, op_h);
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
    } else if (T == io.Stat) T: {
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

    return extern struct {
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
pub const stat = io.opInitOf(Io, io.Stat);
pub const getCwd = io.opInitOf(Io, io.GetCwd);
pub const chDir = io.opInitOf(Io, io.ChDir);
pub const unlinkAt = io.opInitOf(Io, io.UnlinkAt);
pub const socket = io.opInitOf(Io, io.Socket);
pub const bind = io.opInitOf(Io, io.Bind);
pub const listen = io.opInitOf(Io, io.Listen);
pub const accept = io.opInitOf(Io, io.Accept);
pub const connect = io.opInitOf(Io, io.Connect);
pub const shutdown = io.opInitOf(Io, io.Shutdown);
pub const closeSocket = io.opInitOf(Io, io.CloseSocket);
pub const recv = io.opInitOf(Io, io.Recv);
pub const send = io.opInitOf(Io, io.Send);
pub const spawn = io.opInitOf(Io, io.Spawn);
pub const waitPid = io.opInitOf(Io, io.WaitPid);
