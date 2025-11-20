//! io_uring based implementation of Io.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const posix = @import("../posix.zig");
const io = @import("../io.zig");
const ThreadPool = @import("./ThreadPool.zig");

const Io = @This();

ring: linux.IoUring = undefined,
// Blocking task not supported by io_uring run on the thread pool.
tpool: ThreadPool = undefined,

pub fn init(self: *Io, opts: Options) !void {
    self.* = .{};

    if (opts.params) |p| self.ring = try linux.IoUring.init_params(
        opts.entries,
        p,
    ) else {
        self.ring = try linux.IoUring.init(
            opts.entries,
            linux.IORING_SETUP_SUBMIT_ALL,
        );
    }

    try self.tpool.init(opts.thread_pool);
}

pub fn deinit(self: *Io) void {
    self.ring.deinit();
}

pub fn submit(self: *Io, op: anytype) !void {
    comptime {
        std.debug.assert(
            std.mem.startsWith(u8, @typeName(@TypeOf(op)), "*io.Op("),
        );
    }

    switch (@TypeOf(op)) {
        *Op(io.GetCwd), *Op(io.ChDir), *Op(io.Spawn) => {
            _ = try self.tpool.submit(op);
        },
        else => try self.submitOpHeader(op),
    }
}

fn submitOpHeader(self: *Io, op: anytype) !void {
    const sqe = try self.ring.get_sqe();

    // Prepare entry.
    switch (@TypeOf(op)) {
        *Op(io.NoOp) => sqe.prep_nop(),
        *Op(io.Sleep) => {
            op.private.uring_data = .{
                .sec = @intCast(op.data.msec / std.time.ms_per_s),
                .nsec = @intCast(
                    (op.data.msec % std.time.ms_per_s) * std.time.ns_per_ms,
                ),
            };

            sqe.prep_timeout(
                &op.private.uring_data,
                1,
                linux.IORING_TIMEOUT_ETIME_SUCCESS,
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

pub fn poll(self: *Io, mode: io.PollMode) !u32 {
    var cqes: [256]linux.io_uring_cqe = undefined;
    var done: u32 = 0;
    while (true) {
        // Flush SQ.
        const submitted = self.ring.flush_sq();

        var ready = self.ring.cq_ready();
        if (ready == 0) ready = submitted;

        _ = self.ring.enter(
            submitted,
            switch (mode) {
                .all => @min(ready, cqes.len),
                .one => @min(ready, 1),
                .nowait => 0,
            },
            if (ready > 0 and mode != .nowait) linux.IORING_ENTER_GETEVENTS else 0,
        ) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        const copied = try self.ring.copy_cqes(
            cqes[0..cqes.len],
            0, // No wait, don't enter kernel again.
        );
        done += copied;

        for (cqes[0..copied]) |*cqe| {
            self.processCompletion(cqe);
        }

        // We processed all ready.
        if (copied >= ready) break;
    }

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
        .sleep => {
            const op = Op(io.Sleep).fromHeader(op_h);
            if (cqe.res < 0) {
                const rc = errno(cqe.res);
                op.data.result = switch (rc) {
                    .SUCCESS, .TIME => undefined, // OK.
                    .CANCELED => error.Canceled,
                    .FAULT => error.BadAddress,
                    .INVAL => error.InvalidSyscallParameters,
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
    const UringData = if (T == io.Sleep) T: {
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
pub const sleep = io.opInitOf(Io, io.Sleep);
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
