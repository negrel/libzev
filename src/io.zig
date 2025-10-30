//! Implementation independent data structures and helpers function related to
//! I/O.

const std = @import("std");

pub const OpCode = enum(c_int) {
    noop,
    timeout,
    openat,
};

/// OpHeader defines field at the beginning of Op(Io, T) that don't depend on
/// Io and T. It is always safe to read OpHeader even if Io and T are unknown.
pub const OpHeader = extern struct {
    code: OpCode,
    next: ?*OpHeader = null,
};

/// Op defines an I/O operation structure. It is made of a static header and
/// Io / T dependent fields:
///
/// +----------+---------------+
/// | OpHeader | OpBody(Io, T) |
/// +----------+---------------+
///
pub fn Op(Io: type, T: type) type {
    return extern struct {
        const Impl = Io;
        const op_code = T.op_code;

        header: OpHeader = .{ .code = op_code },

        // Implementation specific fields.
        private: Impl.OpPrivateData(T),

        // Operation data.
        data: T,

        pub fn fromHeaderUnsafe(h: *OpHeader) *Op(Io, T) {
            return @fieldParentPtr("header", h);
        }
    };
}

pub const NoOp = extern struct {
    pub const op_code = OpCode.noop;
};

pub const TimeOut = extern struct {
    pub const op_code = OpCode.timeout;

    ms: u64,
};

pub const OpenAt = extern struct {
    pub const op_code = OpCode.openat;

    pub const Options = extern struct {
        read: bool = true,
        write: bool = false,
        append: bool = false,
        truncate: bool = false,
        create_new: bool = false,
        create: bool = true,
    };

    dir: std.fs.File.Handle,
    path: [*c]const u8,
    opts: Options,
    permissions: u32 = 0o0666,

    file: std.fs.File.Handle = -1,
    err_code: usize = 0,

    pub fn result(self: *OpenAt) std.fs.File.OpenError!std.fs.File {
        if (self.err_code != 0) return @errorFromInt(self.err_code);
        return .{ .handle = self.file };
    }
};

pub fn OpConstructor(Io: type, T: type) type {
    return *const fn (
        T,
        user_data: ?*anyopaque,
        callback: *const fn (T) callconv(.c) void,
    ) Op(Io, T);
}

pub fn noOp(Io: type) OpConstructor(Io, NoOp) {
    return struct {
        pub fn func(
            data: NoOp,
            user_data: ?*anyopaque,
            callback: *const fn (NoOp) callconv(.c) void,
        ) Op(Io, NoOp) {
            return .{
                .data = data,
                .private = Io.OpPrivateData(NoOp).init(.{
                    .user_data = user_data,
                    .callback = callback,
                }),
            };
        }
    }.func;
}

pub fn timeOut(Io: type) OpConstructor(Io, TimeOut) {
    return struct {
        pub fn func(
            data: TimeOut,
            user_data: ?*anyopaque,
            callback: *const fn (TimeOut) callconv(.c) void,
        ) Op(Io, TimeOut) {
            return .{
                .data = data,
                .private = Io.OpPrivateData(TimeOut).init(.{
                    .user_data = user_data,
                    .callback = callback,
                }),
            };
        }
    }.func;
}

pub fn openAt(Io: type) OpConstructor(Io, OpenAt) {
    return struct {
        pub fn func(
            data: OpenAt,
            user_data: ?*anyopaque,
            callback: *const fn (OpenAt) callconv(.c) void,
        ) Op(Io, OpenAt) {
            return .{
                .data = data,
                .private = Io.OpPrivateData(OpenAt).init(.{
                    .user_data = user_data,
                    .callback = callback,
                }),
            };
        }
    }.func;
}

pub const QueueError = error{SubmissionQueueFull};

pub const SubmitError = error{
    // The kernel was unable to allocate memory or ran out of resources for the
    // request.
    // The application should wait for some completions and try again:
    SystemResources,
    // The application attempted to overcommit the number of requests it can
    // have pending.
    // The application should wait for some completions and try again:
    CompletionQueueOvercommitted,
    // The submitted operation is malformed/invalid.
    InvalidOp,
    // The Operating System returned an undocumented error code.
    // This error is in theory not possible, but it would be better to handle
    // this error than to invoke undefined behavior.
    // When this error code is observed, it usually means the libzev needs a
    // small patch to add the error code to the error set for the respective
    // function.
    Unexpected,
};

/// Io.poll() mode.
pub const PollMode = enum(c_int) {
    /// Poll events until all I/O operations complete.
    all = 0,
    /// Poll events until at most one I/O operations complete.
    one = 1,
    /// Poll events I/O operation if any without blocking.
    nowait = 2,
};

pub const GetCwdError = error{
    CurrentWorkingDirectoryUnlinked,
    NameTooLong,
    Unexpected,
};

pub fn close(Io: type) *const fn (
    f: std.fs.File,
    user_data: ?*anyopaque,
    callback: *const fn (*Io.Op) void,
) Io.Op {
    return struct {
        fn func(
            file: std.fs.File,
            user_data: ?*anyopaque,
            callback: *const fn (*Io.Op) void,
        ) Io.Op {
            return .{
                .data = .{ .close = .{ .file = file } },
                .user_data = user_data,
                .callback = callback,
            };
        }
    }.func;
}

pub fn pread(Io: type) *const fn (
    file: std.fs.File,
    buf: []u8,
    offset: u64,
    user_data: ?*anyopaque,
    callback: *const fn (*Io.Op) void,
) Io.Op {
    return struct {
        fn func(
            file: std.fs.File,
            buf: []u8,
            offset: u64,
            user_data: ?*anyopaque,
            callback: *const fn (*Io.Op) void,
        ) Io.Op {
            return .{
                .data = .{ .pread = .{
                    .file = file,
                    .buffer = buf,
                    .offset = offset,
                } },
                .user_data = user_data,
                .callback = callback,
            };
        }
    }.func;
}

pub fn pwrite(Io: type) *const fn (
    file: std.fs.File,
    buf: []const u8,
    offset: u64,
    user_data: ?*anyopaque,
    callback: *const fn (*Io.Op) void,
) Io.Op {
    return struct {
        fn func(
            file: std.fs.File,
            buf: []const u8,
            offset: u64,
            user_data: ?*anyopaque,
            callback: *const fn (*Io.Op) void,
        ) Io.Op {
            return .{
                .data = .{ .pwrite = .{
                    .file = file,
                    .buffer = buf,
                    .offset = offset,
                } },
                .user_data = user_data,
                .callback = callback,
            };
        }
    }.func;
}

pub fn fsync(Io: type) *const fn (
    file: std.fs.File,
    user_data: ?*anyopaque,
    callback: *const fn (*Io.Op) void,
) Io.Op {
    return struct {
        fn func(
            file: std.fs.File,
            user_data: ?*anyopaque,
            callback: *const fn (*Io.Op) void,
        ) Io.Op {
            return .{
                .data = .{ .fsync = .{ .file = file } },
                .user_data = user_data,
                .callback = callback,
            };
        }
    }.func;
}

pub fn stat(Io: type) *const fn (
    file: std.fs.File,
    user_data: ?*anyopaque,
    callback: *const fn (*Io.Op) void,
) Io.Op {
    return struct {
        fn func(
            file: std.fs.File,
            user_data: ?*anyopaque,
            callback: *const fn (*Io.Op) void,
        ) Io.Op {
            return .{
                .data = .{ .stat = .{ .file = file } },
                .user_data = user_data,
                .callback = callback,
            };
        }
    }.func;
}
