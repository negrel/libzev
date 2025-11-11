//! Thread pool based implementation of Io.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
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

pub fn queue(self: *Io, op: anytype) io.QueueError!u32 {
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

    return @intCast(self.batch.len);
}

pub fn submit(self: *Io) io.SubmitError!u32 {
    const submitted: u32 = @intCast(self.batch.len);

    self.tpool.schedule(self.batch);
    self.batch = .{};

    _ = self.active.fetchAdd(submitted, .seq_cst);
    return @intCast(submitted);
}

pub fn poll(self: *Io, mode: io.PollMode) !u32 {
    const active = self.active.load(.seq_cst);

    if (active > 0) {
        var i = active;
        switch (mode) {
            .nowait => {},
            .one => while (i > @max(active - 1, 0)) {
                std.Thread.Futex.wait(&self.active, i);
                i = self.active.load(.seq_cst);
            },
            .all => while (i > 0) {
                std.Thread.Futex.wait(&self.active, i);
                i = self.active.load(.seq_cst);
            },
        }
    }

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
                .timeout => {
                    if (builtin.os.tag == .windows) {
                        std.Thread.sleep(
                            self.toOp().data.ms * std.time.ns_per_ms,
                        );
                    } else {
                        doTimeout(op);
                    }
                },
                .openat => doOpenat(op),
                .close => doClose(op),
                .pread => doPRead(op),
                .pwrite => {
                    const d = &op.data;
                    const f: std.fs.File = .{ .handle = d.file };
                    d.write = f.pwrite(
                        d.buffer[0..d.buffer_len],
                        d.offset,
                    ) catch |err| {
                        d.err_code = @intFromError(err);
                        return;
                    };
                },
                .fsync => {
                    const f: std.fs.File = .{ .handle = op.data.file };
                    f.sync() catch |err| {
                        op.data.err_code = @intFromError(err);
                    };
                },
                .stat => {
                    const f: std.fs.File = .{ .handle = op.data.file };
                    const std_stat = f.stat() catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                    op.data.stat = .fromStdFsFileStat(std_stat);
                },
                .getcwd => {
                    const cwd = std.process.getCwd(
                        op.data.buffer[0..op.data.buffer_len],
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                    op.data.cwd_len = cwd.len;
                },
                .chdir => {
                    std.process.changeCurDirZ(
                        op.data.path,
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                },
                .unlinkat => {
                    const dir: std.fs.Dir = .{ .fd = op.data.dir };
                    if (op.data.remove_dir) {
                        dir.deleteDirZ(op.data.path) catch |err| {
                            op.data.err_code = @intFromError(err);
                        };
                    } else {
                        dir.deleteFileZ(op.data.path) catch |err| {
                            op.data.err_code = @intFromError(err);
                        };
                    }
                },
                .socket => {
                    op.data.socket = std.posix.socket(
                        @intFromEnum(op.data.domain),
                        @intFromEnum(op.data.socket_type),
                        @intFromEnum(op.data.protocol),
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                },
                .bind => {
                    std.posix.bind(
                        op.data.socket,
                        op.data.address,
                        op.data.address_len,
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                    };
                },
                .listen => {
                    std.posix.listen(
                        op.data.socket,
                        @intCast(op.data.backlog),
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                    };
                },
                .accept => {
                    op.data.accepted_socket = std.posix.accept(
                        op.data.socket,
                        op.data.address,
                        op.data.address_len,
                        op.data.flags,
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                },
                .connect => {
                    std.posix.connect(
                        op.data.socket,
                        op.data.address,
                        op.data.address_len,
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                    };
                },
                .shutdown => {
                    std.posix.shutdown(
                        op.data.socket,
                        @enumFromInt(@intFromEnum(op.data.how)),
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                    };
                },
                .closesocket => {
                    if (builtin.os.tag == .windows)
                        std.posix.closesocket(op.data.socket)
                    else
                        std.posix.close(op.data.socket);
                },
                .recv => {
                    op.data.recv = std.posix.recv(
                        op.data.socket,
                        op.data.buffer[0..op.data.buffer_len],
                        op.data.flags,
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                },
                .send => {
                    op.data.send = std.posix.send(
                        op.data.socket,
                        op.data.buffer[0..op.data.buffer_len],
                        op.data.flags,
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                },
                .spawn => {
                    if (builtin.os.tag == .windows) {
                        windowsSpawn(&op.data) catch |err| {
                            op.data.err_code = @intFromError(err);
                            return;
                        };
                    } else {
                        op.data.pid = posixSpawn(&op.data) catch |err| {
                            op.data.err_code = @intFromError(err);
                            return;
                        };
                    }
                },
                .waitpid => {
                    op.data.status = std.posix.waitpid(op.data.pid, 0).status;
                },
            }
        }
    };
}

pub fn windowsSpawn(data: *io.Spawn) io.Spawn.Error!void {
    _ = data;
    @compileError("TODO: implements windows spawn");
}

pub fn posixSpawn(data: *io.Spawn) anyerror!std.posix.pid_t {
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

    // Setup a pipe so child can communicate error/success setup before exec().
    const err_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    errdefer {
        std.posix.close(err_pipe[0]);
        std.posix.close(err_pipe[1]);
    }

    // Setup pipes if any.
    var stdio_pipes: [3]std.posix.pid_t = .{ -1, -1, -1 };
    errdefer for (stdio_pipes) |p| if (p != -1) std.posix.close(p);
    for (data.stdio, 0..data.stdio.len) |stdio, i| {
        if (stdio == .pipe) {
            const pipes = try std.posix.pipe2(.{});
            switch (i) {
                0 => {
                    data.stdin = pipes[1];
                    stdio_pipes[i] = pipes[0];
                },
                1 => {
                    data.stdout = pipes[0];
                    stdio_pipes[i] = pipes[1];
                },
                2 => {
                    data.stderr = pipes[0];
                    stdio_pipes[i] = pipes[1];
                },
                else => unreachable,
            }
        }
    }

    const pid = try std.posix.fork();
    if (pid == 0) { // Child.
        std.posix.close(err_pipe[0]); // Close read side.

        var ignore_fd: ?std.posix.fd_t = null;
        for (data.stdio, 0..data.stdio.len) |stdio, i| {
            switch (stdio) {
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
                    std.posix.dup2(stdio_pipes[i], @intCast(i)) catch |err|
                        Static.reportChildError(err_pipe[1], err);
                },
                .close => std.posix.close(@intCast(i)),
            }
        }

        const err = std.posix.execvpeZ(data.args[0], data.args, data.env_vars);
        Static.reportChildError(err_pipe[1], err);
        std.posix.exit(0);
    } else { // Parent.
        std.posix.close(err_pipe[1]); // Close write side.

        // Read if child reported an error.
        var buf: [2]u8 = .{ 0, 0 };
        const read = std.posix.read(err_pipe[0], buf[0..]) catch
            return error.Unexpected;
        if (read == 0) return pid;
        const err_code: *u16 = @ptrCast(@alignCast(&buf[0]));
        return @errorFromInt(err_code.*);
    }
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

const lfs64_abi = builtin.os.tag == .linux and
    builtin.link_libc and
    (builtin.abi.isGnu() or builtin.abi.isAndroid());

fn doTimeout(op: *Op(io.TimeOut)) void {
    const req: posix.system.timespec = .{
        .sec = std.math.cast(i64, op.data.msec / std.time.ms_per_s) orelse
            std.math.maxInt(i64),
        .nsec = std.math.cast(
            i64,
            (op.data.msec % std.time.ms_per_s) * std.time.ns_per_ms,
        ) orelse std.math.maxInt(i64),
    };
    var rem: posix.system.timespec = .{ .sec = 0, .nsec = 0 };

    op.data.result = switch (posix.errno(posix.system.nanosleep(&req, &rem))) {
        .SUCCESS => undefined,
        .FAULT => error.BadAddress,
        .INVAL => error.InvalidSyscallParameters,
        .INTR => E: {
            op.data.remaining_msec = @as(usize, @intCast(rem.nsec)) *
                std.time.ms_per_s +
                @as(usize, @intCast(rem.nsec)) / std.time.ns_per_ms;
            break :E error.SignalInterrupt;
        },
        else => |err| std.posix.unexpectedErrno(err),
    };
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

    op.data.result = openAtErrorFromPosixErrno(openat_sym(
        d.dir.fd,
        path[0..],
        flags,
        d.mode,
    ));
}

pub fn openAtErrorFromPosixErrno(rc: anytype) io.OpenAt.Error!std.fs.File {
    if (rc > 0) return .{ .handle = @as(std.fs.File.Handle, @intCast(rc)) };
    return switch (posix.errno(rc)) {
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .BADF => error.InvalidDirFd,
        .BUSY => error.DeviceBusy,
        .DQUOT => error.DiskQuota,
        .EXIST => error.PathAlreadyExists,
        .FAULT => error.ParamsOutsideAccessibleAddressSpace,
        .FBIG => error.FileTooBig,
        .ILSEQ => |err| if (builtin.os.tag == .wasi)
            error.InvalidUtf8
        else
            posix.unexpectedErrno(err),
        .INTR => error.SignalInterrupt,
        .INVAL => error.InvalidArguments,
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
    op.data.result = closeErrorFromPosixErrno(
        system.close(op.data.file.handle),
    );
}

pub fn closeErrorFromPosixErrno(rc: anytype) io.Close.Error!void {
    if (rc >= 0) return;
    return switch (posix.errno(rc)) {
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
        rc = system.read(
            op.data.file.handle,
            op.data.buffer.ptr,
            op.data.buffer.len,
        );
    } else {
        const pread_sym = if (lfs64_abi) system.pread64 else system.pread;
        rc = pread_sym(
            op.data.file.handle,
            op.data.buffer.ptr,
            op.data.buffer.len,
            op.data.offset,
        );
    }

    op.data.result = preadErrorFromPosixErrno(rc);
}

pub fn preadErrorFromPosixErrno(rc: anytype) io.PRead.Error!usize {
    return switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFd,
        .FAULT => error.ParamsOutsideAccessibleAddressSpace,
        .INTR => error.SignalInterrupt,
        .INVAL => error.BadFd,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .NXIO => error.InvalidOffset,
        // Should never happen.
        // .OVERFLOW => error.Overflow,
        .SPIPE => error.BadFd,
        else => |err| posix.unexpectedErrno(err),
    };
}
