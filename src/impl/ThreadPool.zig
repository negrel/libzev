//! Thread pool based implementation of Io.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const io = @import("../io.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const ThreadPool = @import("../ThreadPool.zig");
const posix = @import("../posix.zig");

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
        std.debug.assert(@typeInfo(@TypeOf(op)) == .pointer);
        std.debug.assert(!@typeInfo(@TypeOf(op)).pointer.is_const);
    }

    if (self.batch.len + 1 == std.math.maxInt(u32)) {
        return io.QueueError.SubmissionQueueFull;
    }

    const op_h: *io.OpHeader = &op.header;
    const no_op: *Op(io.NoOp) = @ptrCast(@alignCast(op_h));
    no_op.private.io = self;
    no_op.private.task.node = .{};

    self.batch.push(ThreadPool.Batch.from(&no_op.private.task));

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
    return extern struct {
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

                    i.completed.push(@ptrCast(@alignCast(private)));
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
                        const req: posix.timespec = .{
                            .sec = std.math.cast(isize, op.data.sec) orelse
                                std.math.maxInt(isize),
                            .nsec = std.math.cast(isize, op.data.nsec) orelse
                                std.time.ns_per_s - 1,
                        };
                        var rem: posix.timespec = .{ .sec = 0, .nsec = 0 };
                        posix.nanosleep(req, &rem) catch |err| {
                            op.data.err_code = @intFromError(err);
                            return;
                        };
                        op.data.remaining_sec = @intCast(rem.sec);
                        op.data.remaining_nsec = @intCast(rem.nsec);
                    }
                },
                .openat => {
                    const d = &op.data;
                    const dir: std.fs.Dir = .{ .fd = d.dir };
                    var file: std.fs.File.OpenError!std.fs.File = undefined;

                    if (d.opts.create or d.opts.create_new) {
                        file = dir.createFileZ(d.path, .{
                            .read = d.opts.read,
                            .truncate = d.opts.truncate,
                            .exclusive = d.opts.create_new,
                            .mode = d.permissions,
                        });
                    } else {
                        var mode: std.fs.File.OpenMode = .read_only;
                        if (d.opts.write) {
                            if (d.opts.read) {
                                mode = .read_write;
                            } else {
                                mode = .write_only;
                            }
                        }
                        file = dir.openFileZ(d.path, .{
                            .mode = mode,
                        });
                    }
                    const f = file catch |err| {
                        d.err_code = @intFromError(err);
                        return;
                    };
                    d.file = f.handle;
                },
                .close => {
                    const f: std.fs.File = .{ .handle = op.data.file };
                    f.close();
                },
                .pread => {
                    const d = &op.data;
                    const f: std.fs.File = .{ .handle = d.file };
                    d.read = f.pread(
                        d.buffer[0..d.buffer_len],
                        d.offset,
                    ) catch |err| {
                        d.err_code = @intFromError(err);
                        return;
                    };
                },
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
                        ignore_fd = posix.openZ(
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
