/// All currently supported asynchronous I/O operation.
pub const Type = enum {
    sleep,
};

/// State enumerates possible I/O operation's state.
pub const State = enum {
    submitted,
    dead,
};

pub const Callback = *const fn (op: *anyopaque) void;
