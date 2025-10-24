const builtin = @import("builtin");

const IoUring = @import("./impl/IoUring.zig");
const ThreadPool = @import("./impl/ThreadPool.zig");

/// Impl enumerates existing implementation of Io.
pub const Impl = enum {
    const Self = @This();

    io_uring,
    thread_pool,

    /// Returns list of available implementations for current target.
    pub inline fn available() []const Self {
        return switch (builtin.os.tag) {
            .linux => &.{ .io_uring, .thread_pool },
            else => &.{},
        };
    }

    /// Returns type associated to this implementation.
    pub inline fn Impl(comptime self: Self) type {
        return switch (self) {
            .io_uring => IoUring,
            .thread_pool => ThreadPool,
        };
    }
};

/// Union of implementation specific options.
pub const Options = union(Impl) {
    io_uring: IoUring.Options,
};
