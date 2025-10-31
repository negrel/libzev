//! Thread pool based implementation of Io.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const io = @import("../io.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const ThreadPool = @import("../ThreadPool.zig");

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
        op.private.doCallback();
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

        callback: *const fn (op_h: *io.OpHeader) callconv(.c) void,
        user_data: ?*anyopaque,

        pub fn init(opts: anytype) OpPrivateData(T) {
            return .{
                .callback = opts.callback,
                .user_data = opts.user_data,
            };
        }

        fn toOp(self: *OpPrivateData(T)) *Op(T) {
            return @alignCast(@fieldParentPtr("private", self));
        }

        fn doBlocking(self: *OpPrivateData(T)) void {
            switch (T.op_code) {
                .noop => {},
                .timeout => std.Thread.sleep(
                    self.toOp().data.ms * std.time.ns_per_ms,
                ),
                .openat => {
                    const op = self.toOp();
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
                    const op = self.toOp();
                    const f: std.fs.File = .{ .handle = op.data.file };
                    f.close();
                },
                .pread => {
                    const op = self.toOp();
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
                    const op = self.toOp();
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
                    const op = self.toOp();
                    const f: std.fs.File = .{ .handle = op.data.file };
                    f.sync() catch |err| {
                        op.data.err_code = @intFromError(err);
                    };
                },
                .stat => {
                    const op = self.toOp();
                    const f: std.fs.File = .{ .handle = op.data.file };
                    const std_stat = f.stat() catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                    op.data.stat = .fromStdFsFileStat(std_stat);
                },
                .getcwd => {
                    const op = self.toOp();
                    const cwd = std.process.getCwd(
                        op.data.buffer[0..op.data.buffer_len],
                    ) catch |err| {
                        op.data.err_code = @intFromError(err);
                        return;
                    };
                    op.data.cwd_len = cwd.len;
                },
            }
        }

        pub fn doCallback(self: *OpPrivateData(T)) void {
            self.callback(&self.toOp().header);
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
