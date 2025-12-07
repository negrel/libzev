//! Thread pool based implementation of Io. All operations are supported and
//! executed on a separate thread in a blocking manner.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const windows = std.os.windows;
const posix = std.posix;
const system = posix.system;

const io = @import("../io.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const ThreadPool = @import("../ThreadPool.zig");
const computils = @import("../computils.zig");

const Io = @This();

tpool: ThreadPool = undefined,
completed: queue_mpsc.Intrusive(OpPrivateData(io.NoOp)) = undefined,
active: std.atomic.Value(u32) = .init(0),
batch: ThreadPool.Batch = .{},

pub fn init(self: *Io, opts: Options) !void {
    self.* = .{};
    self.tpool = .init(opts);
    self.completed.init();
}

pub fn deinit(self: *Io) void {
    self.tpool.shutdown();
    self.tpool.deinit();
}

pub fn supports(_: anytype) bool {
    return true;
}

pub fn submit(self: *Io, op: anytype) io.QueueError!void {
    comptime {
        std.debug.assert(
            std.mem.startsWith(u8, @typeName(@TypeOf(op)), "*io.Op("),
        );
    }

    if (self.batch.len + 1 == std.math.maxInt(u32)) {
        return io.QueueError.SubmissionQueueFull;
    }

    op.private.io = self;
    op.private.task.node = .{};

    self.batch.push(ThreadPool.Batch.from(&op.private.task));
}

pub fn poll(self: *Io, mode: io.PollMode) !u32 {
    var active = self.active.load(.seq_cst);

    // Don't submit if it will overflow active.
    if (std.math.add(u32, active, self.batch.len) != error.Overflow) {
        // Submit batch.
        _ = self.active.fetchAdd(self.batch.len, .seq_cst);
        active += self.batch.len;

        self.tpool.schedule(self.batch);
        self.batch = .{};
    }

    const target: u32 = switch (mode) {
        .nowait => return self.execCallbacks(),
        .one => if (active > 0) active - 1 else 0,
        .all => 0,
    };

    var done: u32 = 0;
    while (active > target) {
        std.Thread.Futex.wait(&self.active, active);
        done += self.execCallbacks();
        active = self.active.load(.seq_cst);
    }

    return done;
}

fn execCallbacks(self: *Io) u32 {
    var done: u32 = 0;
    while (self.completed.pop()) |priv| {
        const op: *Op(io.NoOp) = @fieldParentPtr("private", priv);
        op.header.callback(self, &op.header);
        done += 1;
    }

    return done;
}

pub const Options = ThreadPool.Config;

pub fn Op(T: type) type {
    return io.Op(Io, T);
}

/// I/O operation data specific to this ThreadPool.
pub fn OpPrivateData(T: type) type {
    return struct {
        io: *Io = undefined,

        task: ThreadPool.Task = .{
            .node = .{},
            .callback = struct {
                fn cb(t: *ThreadPool.Task) callconv(.c) void {
                    const private: *OpPrivateData(T) = @alignCast(
                        @fieldParentPtr("task", t),
                    );

                    private.doBlocking();

                    const i: *Io = private.io;

                    // Safety: OpPrivateData(T) must have the same layout as
                    // OpPrivateData(io.NoOp) to be casted and pushed in
                    // completion queue.
                    comptime {
                        computils.canPtrCast(@This(), OpPrivateData(io.NoOp));
                    }
                    i.completed.push(@ptrCast(private));

                    _ = i.active.fetchSub(1, .seq_cst);
                    std.Thread.Futex.wake(&i.active, 1);
                }
            }.cb,
        },

        // queue_mpsc intrusive field.
        next: ?*OpPrivateData(T) = null,

        pub fn init(_: anytype) OpPrivateData(T) {
            return .{};
        }

        fn toOp(self: *OpPrivateData(T)) *Op(T) {
            const op: *Op(T) = @alignCast(@fieldParentPtr("private", self));
            std.debug.assert(op.header.code == T.op_code);
            return op;
        }

        fn toNoOp(self: *OpPrivateData(io.NoOp)) *Op(io.NoOp) {
            return @alignCast(@fieldParentPtr("private", self));
        }

        fn doBlocking(self: *OpPrivateData(T)) void {
            const op = self.toOp();
            switch (T.op_code) {
                .noop => {},
                .sleep => {
                    if (builtin.os.tag == .windows) {
                        std.Thread.sleep(
                            self.toOp().data.ms * std.time.ns_per_ms,
                        );
                    } else {
                        doSleep(op);
                    }
                },
                .openat => doOpenat(op),
                .close => doClose(op),
                .pread => doPRead(op),
                .pwrite => doPWrite(op),
                .fsync => doFSync(op),
                .fstat => doFStat(op),
                .getcwd => doGetCwd(op),
                .chdir => doChDir(op),
                .unlinkat => doUnlinkAt(op),
                .spawn => doSpawn(op),
                .waitpid => doWaitPid(op),
                .pipe => doPipe(op),
            }
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
pub const pipe = io.opInitOf(Io, io.Pipe);

const lfs64_abi = builtin.os.tag == .linux and
    builtin.link_libc and
    (builtin.abi.isGnu() or builtin.abi.isAndroid());

fn doSleep(op: *Op(io.Sleep)) void {
    var req: posix.system.timespec = .{
        .sec = std.math.cast(i64, op.data.msec / std.time.ms_per_s) orelse
            std.math.maxInt(i64),
        .nsec = std.math.cast(
            i64,
            (op.data.msec % std.time.ms_per_s) * std.time.ns_per_ms,
        ) orelse std.math.maxInt(i64),
    };
    var rem: posix.system.timespec = .{ .sec = 0, .nsec = 0 };

    while (true) {
        op.data.result = switch (posix.errno(posix.system.nanosleep(&req, &rem))) {
            .SUCCESS => undefined,
            .FAULT => error.BadAddress,
            .INVAL => error.InvalidSyscallParameters,
            .INTR => {
                req = rem;
                continue;
            },
            else => |err| std.posix.unexpectedErrno(err),
        };
        return;
    }
}

fn doOpenat(op: *Op(io.OpenAt)) void {
    const openat_sym = if (lfs64_abi) system.openat64 else system.openat;

    const d = &op.data;

    const path = posix.toPosixPath(d.path) catch |err| {
        d.result = err;
        return;
    };
    const flags: posix.O = .{
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
        .CREAT = d.options.create or op.data.options.create_new,
        .EXCL = d.options.create_new,
        .APPEND = d.options.append,
        .CLOEXEC = true,
    };

    const rc = openat_sym(
        d.dir.fd,
        path[0..],
        flags,
        d.mode,
    );
    openAtErrorFromPosixE(posix.errno(rc)) catch |err| {
        op.data.result = err;
        return;
    };

    op.data.result = .{ .handle = @intCast(rc) };
}

pub fn openAtErrorFromPosixE(e: posix.E) io.OpenAt.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .BADF => error.InvalidDirFd,
        .BUSY => error.DeviceBusy,
        .DQUOT => error.DiskQuota,
        .EXIST => error.PathAlreadyExists,
        .FAULT => error.BadAddress,
        .FBIG => error.FileTooBig,
        .ILSEQ => |err| if (builtin.os.tag == .wasi)
            error.InvalidUtf8
        else
            posix.unexpectedErrno(err),
        .INTR => error.SignalInterrupt,
        .INVAL => error.InvalidSyscallParameters,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .NXIO => error.NoDevice,
        .OPNOTSUPP => error.FileLocksNotSupported,
        .OVERFLOW => error.FileTooBig,
        .PERM => error.PermissionDenied,
        .ROFS => error.ReadOnlyFileSystem,
        .TXTBSY => error.FileBusy,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doClose(op: *Op(io.Close)) void {
    const rc =
        system.close(op.data.file.handle);
    op.data.result = closeErrorFromPosixE(posix.errno(rc));
}

pub fn closeErrorFromPosixE(e: posix.E) io.Close.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .BADF => error.BadFd,
        .INTR => error.SignalInterrupt,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doPRead(op: *Op(io.PRead)) void {
    var rc: usize = 0;
    if (op.data.offset == -1) {
        rc = @intCast(system.read(
            op.data.file.handle,
            op.data.buffer.ptr,
            op.data.buffer.len,
        ));
    } else {
        const pread_sym = if (lfs64_abi) system.pread64 else system.pread;
        rc = @intCast(pread_sym(
            op.data.file.handle,
            op.data.buffer.ptr,
            op.data.buffer.len,
            @intCast(op.data.offset),
        ));
    }

    preadErrorFromPosixE(posix.errno(rc)) catch |err| {
        op.data.result = err;
        return;
    };
    op.data.result = @intCast(rc);
}

pub fn preadErrorFromPosixE(e: posix.E) io.PRead.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFd,
        .FAULT => error.ParamsOutsideAccessibleAddressSpace,
        .INTR => error.SignalInterrupt,
        .INVAL => error.InvalidSyscallParameters,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .NXIO => error.InvalidOffset,
        // Should never happen.
        .OVERFLOW => error.Overflow,
        .SPIPE => error.Unseekable,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doPWrite(op: *Op(io.PWrite)) void {
    var rc: usize = 0;
    if (op.data.offset == -1) {
        rc = @intCast(system.write(
            op.data.file.handle,
            op.data.buffer.ptr,
            op.data.buffer.len,
        ));
    } else {
        const pwrite_sym = if (lfs64_abi) system.pwrite64 else system.pwrite;
        rc = @intCast(pwrite_sym(
            op.data.file.handle,
            op.data.buffer.ptr,
            op.data.buffer.len,
            @intCast(op.data.offset),
        ));
    }

    pwriteErrorFromPosixE(posix.errno(rc)) catch |err| {
        op.data.result = err;
        return;
    };
    op.data.result = @intCast(rc);
}

pub fn pwriteErrorFromPosixE(e: posix.E) io.PWrite.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFd,
        // Should never happen, we only write to file.
        // .DESTADDRREQ => ...
        .DQUOT => error.DiskQuota,
        .FAULT => error.ParamsOutsideAccessibleAddressSpace,
        .FBIG => error.FileTooBig,
        .INTR => error.SignalInterrupt,
        .INVAL => error.InvalidSyscallParameters,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .NXIO => error.InvalidOffset,
        .OVERFLOW => error.Overflow,
        .PERM => error.PermissionDenied,
        .PIPE => error.BrokenPipe,
        .SPIPE => error.Unseekable,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doFSync(op: *Op(io.FSync)) void {
    const rc = system.fsync(op.data.file.handle);
    op.data.result = fsyncErrorFromPosixE(posix.errno(rc));
}

pub fn fsyncErrorFromPosixE(e: posix.E) io.FSync.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .BADF => error.BadFd,
        .INTR => error.SignalInterrupt,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .INVAL => error.InvalidSyscallParameters,
        .DQUOT => error.DiskQuota,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doFStat(op: *Op(io.FStat)) void {
    const fstat_sym = if (lfs64_abi) system.fstat64 else system.fstat;

    var stat: posix.Stat = undefined;
    const rc = fstat_sym(op.data.file.handle, &stat);
    fstatErrorFromPosixE(posix.errno(rc)) catch |err| {
        op.data.result = err;
        return;
    };
    op.data.result = .fromPosix(stat);
}

pub fn fstatErrorFromPosixE(e: posix.E) io.FStat.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .BADF => error.BadFd,
        .FAULT => error.BadAddress,
        // stat/lstat/fstatat only
        // .INVAL => ...
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        // stat/lstat/fstatat only
        // .NOENT => ...
        .NOMEM => error.OutOfMemory,
        .NOTDIR => error.NotDir,
        .OVERFLOW => error.Overflow,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doGetCwd(op: *Op(io.GetCwd)) void {
    if (builtin.os.tag == .windows) {
        op.data.result = windows.GetCurrentDirectory(op.data.buffer);
    } else if (builtin.os.tag == .wasi and !builtin.link_libc) {
        const path = ".";
        if (op.data.buffer.len < path.len) return error.NameTooLong;
        const result = op.data.buffer[0..path.len];
        @memcpy(result, path);
        return result;
    }

    const err: posix.E = if (builtin.link_libc) err: {
        const c_err = if (std.c.getcwd(
            op.data.buffer.ptr,
            op.data.buffer.len,
        )) |_| 0 else std.c._errno().*;
        break :err @enumFromInt(c_err);
    } else err: {
        break :err posix.errno(system.getcwd(
            op.data.buffer.ptr,
            op.data.buffer.len,
        ));
    };
    op.data.result = switch (err) {
        .SUCCESS => std.mem.sliceTo(op.data.buffer, 0),
        .ACCES => error.PermissionDenied,
        .FAULT => error.BadAddress,
        .INVAL => error.InvalidBuffer,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.CurrentWorkingDirectoryUnlinked,
        .NOMEM => error.SystemResources,
        .RANGE => error.NameTooLong,
        else => posix.unexpectedErrno(err),
    };
}

fn doChDir(op: *Op(io.ChDir)) void {
    const dir_path = posix.toPosixPath(op.data.path) catch |err| {
        op.data.result = err;
        return;
    };

    if (builtin.os.tag == .windows) {
        const dir_path_span = std.mem.span(dir_path);
        var wtf16_dir_path: [windows.PATH_MAX_WIDE]u16 = undefined;
        if (try std.unicode.checkWtf8ToWtf16LeOverflow(dir_path_span, &wtf16_dir_path)) {
            return error.NameTooLong;
        }
        const len = try std.unicode.wtf8ToWtf16Le(&wtf16_dir_path, dir_path_span);
        return posix.chdirW(wtf16_dir_path[0..len]);
    }
    op.data.result = switch (posix.errno(system.chdir(&dir_path))) {
        .SUCCESS => undefined,
        .ACCES => error.AccessDenied,
        .FAULT => error.BadAddress,
        .IO => error.FileSystem,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        .ILSEQ => |err| if (builtin.os.tag == .wasi)
            error.InvalidUtf8
        else
            posix.unexpectedErrno(err),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doUnlinkAt(op: *Op(io.UnlinkAt)) void {
    const flags: u32 = if (op.data.remove_dir) posix.AT.REMOVEDIR else 0;

    if (builtin.os.tag == .windows) {
        const file_path_w = windows.sliceToPrefixedFileW(
            op.data.dir.fd,
            op.data.path,
        ) catch |err| {
            op.data.result = err;
            return;
        };

        return posix.unlinkatW(
            op.data.dir.fd,
            file_path_w.span(),
            flags,
        );
    } else {
        const file_path_c = posix.toPosixPath(op.data.path) catch |err| {
            op.data.result = err;
            return;
        };
        const rc = system.unlinkat(op.data.dir.fd, file_path_c[0..], flags);
        op.data.result = unlinkAtErrorFromErrno(posix.errno(rc));
    }
}

pub fn unlinkAtErrorFromErrno(e: posix.E) io.UnlinkAt.Error!void {
    return switch (e) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .BADF => error.InvalidDirFd,
        .BUSY => error.FileBusy,
        .EXIST => error.DirNotEmpty,
        .FAULT => error.BadAddress,
        .ILSEQ => |err| if (builtin.os.tag == .wasi)
            error.InvalidUtf8
        else
            posix.unexpectedErrno(err),
        // Flag is invalid.
        // .INVAL => unreachable,
        .IO => error.FileSystem,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        .NOTEMPTY => error.DirNotEmpty,
        .PERM => error.PermissionDenied,
        .ROFS => error.ReadOnlyFileSystem,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doSpawn(op: *Op(io.Spawn)) void {
    op.data.result = posixSpawn(&op.data);
}

pub fn posixSpawn(data: *io.Spawn) io.Spawn.Error!io.Spawn.Result {
    const Static = struct {
        fn reportChildError(
            fd: std.posix.fd_t,
            err: anyerror,
        ) noreturn {
            const err_code: u16 = @intFromError(err);
            const err_slice: [*c]const u8 = @ptrCast(&err_code);
            _ = std.posix.write(fd, err_slice[0..2]) catch {};
            // If we're linking libc, some naughty applications may have
            // registered atexit handlers which we really do not want to run in
            // the fork child. I caught LLVM doing this and
            // it caused a deadlock instead of doing an exit syscall. In the
            // words of Avril Lavigne, "Why'd you have to go and make things so
            // complicated?"
            if (builtin.link_libc) {
                // The _exit(2) function does nothing but make the exit syscall,
                // unlike exit(3)
                std.c._exit(1);
            }
            posix.exit(1);
        }
    };
    var result: io.Spawn.Result = undefined;

    // Setup a pipe so child can communicate error/success setup before exec().
    const err_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });

    // Setup pipes if any.
    const stdio: [3]io.Spawn.StdIo = .{ data.stdin, data.stdout, data.stderr };
    var child_pipes: [3]?std.fs.File.Handle = .{ null, null, null };
    inline for (stdio, 0..stdio.len) |s, i| {
        if (s == .pipe) {
            const pipes = try std.posix.pipe2(.{});
            switch (i) {
                0 => {
                    result.stdin = .{ .handle = pipes[1] };
                    child_pipes[i] = pipes[0];
                },
                1 => {
                    result.stdout = .{ .handle = pipes[0] };
                    child_pipes[i] = pipes[1];
                },
                2 => {
                    result.stderr = .{ .handle = pipes[0] };
                    child_pipes[i] = pipes[1];
                },
                else => unreachable,
            }
        }
    }

    const pid = try std.posix.fork();
    if (pid == 0) { // Child.
        // Close parent pipes or child pipes on error.
        std.posix.close(err_pipe[0]);
        defer std.posix.close(err_pipe[1]);
        errdefer for (child_pipes) |p| if (p) |fd| std.posix.close(fd);

        var ignore_fd: ?std.posix.fd_t = null;
        for (stdio, 0..stdio.len) |s, i| {
            switch (s) {
                .inherit => {},
                .ignore => {
                    if (ignore_fd == null) {
                        ignore_fd = std.posix.openZ(
                            "/dev/null",
                            .{ .ACCMODE = .RDWR },
                            0,
                        ) catch |err| Static.reportChildError(err_pipe[1], err);
                    }
                    std.posix.dup2(ignore_fd.?, @intCast(i)) catch |err|
                        Static.reportChildError(err_pipe[1], err);
                },
                .pipe => {
                    std.posix.dup2(child_pipes[i].?, @intCast(i)) catch |err|
                        Static.reportChildError(err_pipe[1], err);
                },
                .close => std.posix.close(@intCast(i)),
            }
        }

        const err = std.posix.execvpeZ(data.args[0].?, data.args, data.env_vars);
        Static.reportChildError(err_pipe[1], err);
        std.posix.exit(0);
    } else { // Parent.
        // Close child pipes.
        std.posix.close(err_pipe[1]);
        for (child_pipes) |p| if (p) |fd| std.posix.close(fd);
        defer std.posix.close(err_pipe[0]);

        result.pid = pid;

        // Read if child reported an error.
        var buf: [2]u8 = .{ 0, 0 };
        const read = std.posix.read(err_pipe[0], buf[0..]) catch
            return error.Unexpected;
        if (read == 0) return result;
        const err_code: *u16 = @ptrCast(@alignCast(&buf[0]));
        return @errorCast(@errorFromInt(err_code.*));
    }
}

fn doWaitPid(op: *Op(io.WaitPid)) void {
    const Status = if (builtin.link_libc) c_int else u32;

    var status: Status = undefined;
    while (true) {
        const rc = system.waitpid(op.data.pid, &status, 0);
        waitPidErrorFromErrno(posix.errno(rc)) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => |e| {
                op.data.result = e;
                return;
            },
        };

        op.data.result = @intCast(status);
        return;
    }
}

pub fn waitPidErrorFromErrno(
    e: posix.E,
) (io.WaitPid.Error || error{SignalInterrupt})!void {
    return switch (e) {
        .SUCCESS => {},
        .INTR => error.SignalInterrupt,
        .CHILD => error.NoChild,
        // .INVAL => unreachable, // Invalid flags.
        else => |err| posix.unexpectedErrno(err),
    };
}

fn doPipe(op: *Op(io.Pipe)) void {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = system.pipe(&fds);
    pipeErrorFromErrno(posix.errno(rc)) catch |err| {
        op.data.result = err;
        return;
    };
    op.data.result = @bitCast(fds);
}

pub fn pipeErrorFromErrno(e: posix.E) io.Pipe.Error!void {
    switch (e) {
        .SUCCESS => {},
        // .INVAL => unreachable, // pipe2() only.
        // .FAULT => unreachable, // Invalid fds pointer.
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return posix.unexpectedErrno(err),
    }
}

// Queuing and polling 0s sleep operations on a threadpool with 1 thread is
// faster than sleeping on the main thread.

// test "benchmark sleep 0s" {
//     const Static = struct {
//         fn callback(_: *Io, _: *Op(io.Sleep)) void {}
//     };
//
//     var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
//     defer _ = gpa.deinit();
//     var arena = std.heap.ArenaAllocator.init(gpa.allocator());
//     defer arena.deinit();
//     var allocator = arena.allocator();
//
//     var tpool: Io = undefined;
//     try tpool.init(.{ .max_threads = 1 });
//
//     var timer = try std.time.Timer.start();
//
//     const batch_size = 4096;
//     var batch = try allocator.alloc(Op(io.Sleep), batch_size);
//
//     var queued: usize = 0;
//     var done: usize = 0;
//     while (timer.read() < std.time.ns_per_s) {
//         queued += 1;
//         if (queued % batch_size == 0) {
//             done += try tpool.poll(.nowait);
//             batch = try allocator.alloc(Op(io.Sleep), batch_size);
//         }
//
//         batch[queued % batch_size] = Io.sleep(
//             .{ .msec = 0 },
//             null,
//             Static.callback,
//         );
//         try tpool.submit(&batch[queued % batch_size]);
//     }
//
//     std.debug.print("{} 0s sleep operations completed in 1s\n", .{done});
//
//     _ = try tpool.poll(.all);
// }
//
// test "benchmark sleep 0s single thread" {
//     var timer = try std.time.Timer.start();
//
//     var done: usize = 0;
//     while (timer.read() < std.time.ns_per_s) {
//         posix.nanosleep(0, 0);
//         done += 1;
//     }
//
//     std.debug.print("{} 0s sleep operations completed in 1s\n", .{done});
// }
