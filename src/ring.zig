/// Buffer returns a ring buffer for type T backed by fixed size array.
pub fn Buffer(T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = cap;

        arr: [capacity]T = undefined,
        r: usize = 0,
        w: usize = 0,

        /// Returns whether ring buffer is full (i.e it contains capacity - 1
        /// items).
        fn isFull(self: *Self) bool {
            return self.r == (self.w + 1) % capacity;
        }

        /// Returns whether ring buffer is empty.
        fn isEmpty(self: *Self) bool {
            return self.r == self.w;
        }

        /// Reserve a slot, returns a pointer to it and move write cursor.
        fn push(self: *Self) ?*T {
            const nw = (self.w + 1) % capacity;
            if (self.r == nw) return null; // full.

            const ptr = &self.arr[self.w];
            self.w = nw;
            return ptr;
        }

        /// Peeks an entry to be read without consuming it. You must call
        /// `skip()` to move read cursor once you're done with T.
        fn peek(self: *Self) ?*T {
            if (self.isEmpty()) return null;
            return &self.arr[self.r];
        }

        /// Skips at most `n` entries to be read and returns actual number of
        /// skipped entries.
        fn skip(self: *Self, n: usize) usize {
            const skipped = @min(self.len(), n);
            self.r += skipped;
            return skipped;
        }

        /// Returns number of entries to be read.
        fn len(self: *Self) usize {
            if (self.r > self.w) {
                return capacity - self.r + self.w;
            } else {
                return self.w - self.r;
            }
        }
    };
}

test {
    const std = @import("std");

    var rbuf: Buffer(usize, 1024) = .{};
    try std.testing.expect(rbuf.isEmpty());
    try std.testing.expect(!rbuf.isFull());
    try std.testing.expect(rbuf.len() == 0);
    try std.testing.expect(rbuf.skip(100) == 0);
    try std.testing.expect(rbuf.peek() == null);

    rbuf.push().?.* = 1;
    try std.testing.expect(rbuf.peek().?.* == 1);
    try std.testing.expect(rbuf.len() == 1);
    try std.testing.expect(!rbuf.isEmpty());
    try std.testing.expect(!rbuf.isFull());

    try std.testing.expect(rbuf.skip(100) == 1);
    try std.testing.expect(rbuf.peek() == null);
    try std.testing.expect(rbuf.len() == 0);

    for (0..1023) |i| {
        rbuf.push().?.* = i;
    }
    try std.testing.expect(rbuf.push() == null);
    try std.testing.expect(!rbuf.isEmpty());
    try std.testing.expect(rbuf.isFull());

    try std.testing.expect(rbuf.r > rbuf.w);
    try std.testing.expect(rbuf.len() == 1023);

    for (0..1023) |i| {
        try std.testing.expect(rbuf.peek().?.* == i);
        try std.testing.expect(rbuf.skip(1) == 1);
    }

    try std.testing.expect(rbuf.len() == 0);
}
