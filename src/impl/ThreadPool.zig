//! Thread pool based implementation of Io.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const io = @import("../io.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const ThreadPool = @import("../ThreadPool.zig");

const Self = @This();
const Io = Self;

tpool: ThreadPool = undefined,
completed: queue_mpsc.Intrusive(Op) = undefined,
active: std.atomic.Value(u32) = .init(0),

pub fn init(self: *Self, opts: Options) !void {
    self.* = .{};
    self.tpool = .init(opts);
    self.completed.init();
}

pub fn deinit(self: *Self) void {
    self.tpool.shutdown();
    self.tpool.deinit();
}

pub fn submit(self: *Self, iop: *Op) !void {
    try self.submitBatch(Batch.from(iop));
}

pub fn submitBatch(self: *Self, batch: Batch) !void {
    var tpoll_batch: ThreadPool.Batch = .{};

    var b = batch;
    var submitted: u32 = 0;
    while (b.pop()) |iop| {
        iop.io = self;
        iop.task.node = .{};
        tpoll_batch.push(ThreadPool.Batch.from(&iop.task));
        submitted += 1;
    }

    _ = self.active.fetchAdd(submitted, .seq_cst);

    self.tpool.schedule(tpoll_batch);
}

pub fn poll(self: *Self, mode: io.PollMode) !u32 {
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
    while (self.completed.pop()) |op| {
        op.callback(op);
        done += 1;
    }

    return done;
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
        .data = .{ .timeout = .{ .ms = ms } },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn openat(
    dir: std.fs.Dir,
    path: [*c]const u8,
    opts: io.OpenOptions,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .openat = .{
            .dir = dir,
            .path = path,
            .opts = opts,
        } },
        .user_data = user_data,
        .callback = callback,
    };
}

pub fn close(
    f: std.fs.File,
    user_data: ?*anyopaque,
    callback: *const fn (*Op) void,
) Op {
    return .{
        .data = .{ .close = .{ .file = f } },
        .user_data = user_data,
        .callback = callback,
    };
}

pub const Op = struct {
    io: *Io = undefined,
    data: union(io.OpCode) {
        noop: void,
        timeout: struct { ms: u64 },
        openat: struct {
            dir: std.fs.Dir,
            path: [*:0]const u8,
            opts: io.OpenOptions,
            file: std.fs.File.OpenError!std.fs.File = undefined,
        },
        close: struct { file: std.fs.File },
    },
    callback: *const fn (*Op) void,
    user_data: ?*anyopaque,

    task: ThreadPool.Task = .{
        .node = .{},
        .callback = struct {
            fn cb(t: *ThreadPool.Task) void {
                const op: *Op = @fieldParentPtr("task", t);
                op.blocking();

                const i: *Io = op.io;

                i.completed.push(op);
                _ = i.active.fetchSub(1, .seq_cst);
                std.Thread.Futex.wake(&i.active, 1);
            }
        }.cb,
    },

    // Intrusive batch node field.
    node: Batch.Node = .{},

    // Intrusive MPSC queue next field.
    next: ?*Op = null,

    fn blocking(self: *Op) void {
        switch (self.data) {
            .noop => {},
            .timeout => |d| std.Thread.sleep(d.ms * std.time.ns_per_ms),
            .openat => |d| {
                if (d.opts.create or d.opts.create_new) {
                    self.data.openat.file = d.dir.createFileZ(d.path, .{
                        .read = d.opts.read,
                        .truncate = d.opts.truncate,
                        .exclusive = d.opts.create_new,
                        .mode = d.opts.mode,
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
                    self.data.openat.file = d.dir.openFileZ(d.path, .{
                        .mode = mode,
                    });
                }
            },
            .close => |d| {
                d.file.close();
            },
        }
    }
};
pub const Options = ThreadPool.Config;
pub const Batch = io.Batch(Self);
