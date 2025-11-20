const builtin = @import("builtin");

const IoUring = @import("./impl/IoUring.zig");
const ThreadPool = @import("./impl/ThreadPool.zig");
const Overlay = @import("./impl/overlay.zig").Overlay;

/// Impl enumerates existing implementation of Io.
pub const Impl = enum {
    const Self = @This();

    io_uring,
    thread_pool,

    /// Returns list of available implementations for current target.
    pub inline fn available() []const Self {
        return switch (builtin.os.tag) {
            .linux => &.{ .io_uring, .thread_pool },
            else => {
                if (builtin.single_threaded) return &.{};
                return &.{.thread_pool};
            },
        };
    }

    pub fn default() Self {
        const impls = available();
        if (impls.len == 0) {
            @compileError("no implementation available for this target");
        }
        return impls[0];
    }

    /// Returns Io type associated to this implementation.
    pub inline fn Io(comptime self: Self) type {
        return switch (self) {
            .io_uring => Overlay(IoUring, ThreadPool),
            .thread_pool => ThreadPool,
        };
    }
};
