const std = @import("std");

/// All currently supported asynchronous I/O operation.
pub const Type = enum {
    sleep,
    cancel,
    open_file,
    pread,
};

/// State enumerates possible I/O operation's state.
pub const State = enum(u8) {
    submitted,
    cancelled,
    dead,
};

pub const Result = union(Type) {
    pub fn of(t: Type) type {
        return switch (t) {
            .sleep => error{CancelError}!void,
            .cancel => error{OperationDone}!void,
            .open_file => (std.fs.File.OpenError || error{CancelError})!std.fs.File,
            .pread => (std.fs.File.PReadError || error{CancelError})!usize,
        };
    }

    sleep: of(.sleep),
    cancel: of(.cancel),
    open_file: of(.open_file),
    pread: of(.pread),
};

pub const Data = union(Type) {
    fn callback(t: Type) type {
        return *const fn (op: *anyopaque, Data.of(t)) void;
    }

    pub fn of(t: Type) type {
        return switch (t) {
            .sleep => struct {
                ms: usize,
                result: Result.of(.sleep) = undefined,
                callback: callback(.sleep),
            },
            .cancel => struct {
                op: *anyopaque,
                result: Result.of(.cancel) = undefined,
                callback: callback(.cancel),
            },
            .open_file => struct {
                dir: std.fs.Dir,
                sub_path: []const u8,
                flags: std.fs.File.OpenFlags,
                result: Result.of(.open_file) = undefined,
                callback: callback(.open_file),
            },
            .pread => struct {
                f: std.fs.File,
                buf: []u8,
                offset: u64,
                result: Result.of(.pread) = undefined,
                callback: callback(.pread),
            },
        };
    }

    sleep: of(.sleep),
    cancel: of(.cancel),
    open_file: of(.open_file),
    pread: of(.pread),
};
