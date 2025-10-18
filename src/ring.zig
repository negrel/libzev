/// Buffer returns a ring buffer for type T backed by fixed size array.
pub fn Buffer(T: type, comptime cap: usize) type {
    if (cap % 2 != 0) @compileError("capacity must be a power of two");

    return struct {
        const Self = @This();

        pub const capacity = cap;
        // (x & mask) is used as a fast (x % capacity).
        pub const mask = capacity - 1;

        arr: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,

        /// Returns whether ring buffer is full (i.e it contains capacity - 1
        /// items).
        pub fn isFull(self: *Self) bool {
            return self.tail - self.head == capacity;
        }

        /// Returns whether ring buffer is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.head == self.tail;
        }

        /// Reserve a slot, returns a pointer to it and move write cursor.
        pub fn push(self: *Self) ?*T {
            if (self.len() >= capacity) return null; // full.
            const ptr = &self.arr[self.tail & mask];
            self.tail += 1;
            return ptr;
        }

        /// Peeks an entry to be read without consuming it. You must call
        /// `skip()` to move read cursor once you're done with T.
        pub fn peek(self: *Self) ?*T {
            if (self.isEmpty()) return null;
            return &self.arr[self.head & mask];
        }

        /// Skips at most `n` entries to be read and returns actual number of
        /// skipped entries.
        pub fn skip(self: *Self, n: usize) usize {
            const skipped = @min(self.len(), n);
            self.head = (self.head + skipped);
            return skipped;
        }

        /// Returns number of entries to be read.
        pub fn len(self: *Self) usize {
            return self.tail - self.head;
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

    for (0..1024) |i| {
        rbuf.push().?.* = i;
    }
    try std.testing.expect(rbuf.push() == null);
    try std.testing.expect(!rbuf.isEmpty());
    try std.testing.expect(rbuf.isFull());
    try std.testing.expect(rbuf.len() == 1024);

    for (0..1024) |i| {
        try std.testing.expect(rbuf.peek().?.* == i);
        try std.testing.expect(rbuf.skip(1) == 1);
    }

    try std.testing.expect(rbuf.len() == 0);

    for (0..1024) |i| {
        rbuf.push().?.* = i;
    }
    for (0..1024) |i| {
        try std.testing.expect(rbuf.peek().?.* == i);
        try std.testing.expect(rbuf.skip(1) == 1);
    }
    try std.testing.expect(rbuf.len() == 0);
}
