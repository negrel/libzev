const std = @import("std");

/// All currently supported asynchronous I/O operation.
pub const Type = enum {
    sleep,
    cancel,
};

/// State enumerates possible I/O operation's state.
pub const State = enum(c_int) {
    submitted,
    cancelled,
    dead,
};

pub const Result = union(Type) {
    pub fn of(t: Type) type {
        return switch (t) {
            .sleep => error{CancelError}!void,
            .cancel => error{OperationDone}!void,
        };
    }

    sleep: of(.sleep),
    cancel: of(.cancel),
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
        };
    }

    sleep: of(.sleep),
    cancel: of(.cancel),
};
