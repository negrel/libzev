pub const ThreadPool = @import("./backend/ThreadPool.zig");

/// Submit & Poll implementations.
pub const Backend = enum {
    thread_pool,

    pub fn default() Backend {
        return .thread_pool;
    }

    pub fn impl(comptime self: Backend) type {
        switch (self) {
            .thread_pool => ThreadPool,
        }
    }
};

test {
    _ = ThreadPool;
}
