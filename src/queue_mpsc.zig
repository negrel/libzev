// Copied from https://github.com/mitchellh/libxev/blob/34fa50878aec6e5fa8f532867001ab3c36fae23e/src/queue_mpsc.zig

const std = @import("std");
const assert = std.debug.assert;

/// An intrusive MPSC (multi-provider, single consumer) queue implementation.
/// The type T must have a field "next" of type `?*T`.
///
/// Once initialized the queue can't be moved, its reference must remain stable
/// and you should never make copy of it.
///
/// This is an implementatin of a Vyukov Queue[1].
/// TODO(mitchellh): I haven't audited yet if I got all the atomic operations
/// correct. I was short term more focused on getting something that seemed
/// to work; I need to make sure it actually works.
///
/// For those unaware, an intrusive variant of a data structure is one in which
/// the data type in the list has the pointer to the next element, rather
/// than a higher level "node" or "container" type. The primary benefit
/// of this (and the reason we implement this) is that it defers all memory
/// management to the caller: the data structure implementation doesn't need
/// to allocate "nodes" to contain each element. Instead, the caller provides
/// the element and how its allocated is up to them.
///
/// [1]: https://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
pub fn Intrusive(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head is the front of the queue and tail is the back of the queue.
        head: *T,
        tail: *T,
        stub: T,

        /// Initialize the queue. This requires a stable pointer to itself.
        /// This must be called before the queue is used concurrently.
        pub fn init(self: *Self) void {
            self.head = &self.stub;
            self.tail = &self.stub;
            self.stub.next = null;
        }

        /// Push an item onto the queue. This can be called by any number
        /// of producers.
        pub fn push(self: *Self, v: *T) void {
            @atomicStore(?*T, &v.next, null, .unordered);
            const prev = @atomicRmw(*T, &self.head, .Xchg, v, .acq_rel);
            @atomicStore(?*T, &prev.next, v, .release);
        }

        /// Pop the first in element from the queue. This must be called
        /// by only a single consumer at any given time.
        pub fn pop(self: *Self) ?*T {
            var tail = @atomicLoad(*T, &self.tail, .unordered);
            var next_ = @atomicLoad(?*T, &tail.next, .acquire);
            if (tail == &self.stub) {
                const next = next_ orelse return null;
                @atomicStore(*T, &self.tail, next, .unordered);
                tail = next;
                next_ = @atomicLoad(?*T, &tail.next, .acquire);
            }

            if (next_) |next| {
                @atomicStore(*T, &self.tail, next, .release);
                tail.next = null;
                return tail;
            }

            const head = @atomicLoad(*T, &self.head, .unordered);
            if (tail != head) return null;
            self.push(&self.stub);

            next_ = @atomicLoad(?*T, &tail.next, .acquire);
            if (next_) |next| {
                @atomicStore(*T, &self.tail, next, .unordered);
                tail.next = null;
                return tail;
            }

            return null;
        }
    };
}

test "single thread" {
    const testing = std.testing;

    // Types
    const Elem = struct {
        const Self = @This();
        next: ?*Self = null,
    };
    const Queue = Intrusive(Elem);
    var q: Queue = undefined;
    q.init();

    // Elems
    var elems: [10]Elem = .{Elem{}} ** 10;

    // One
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop() == null);

    // Two
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);

    // // Interleaved
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);
}

test "multi thread" {
    const threads_count = 4;
    const iter_count = 2000;

    const Elem = struct {
        const Self = @This();
        next: ?*Self = null,
    };
    const Queue = Intrusive(Elem);
    var q: Queue = undefined;
    q.init();

    var elems: [threads_count * iter_count]Elem = undefined;
    var threads: [threads_count]std.Thread = undefined;
    var pushed: std.atomic.Value(u32) = .init(0);

    for (0..threads_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn worker(queue: *Queue, els: []Elem, count: *std.atomic.Value(u32)) void {
                var qq = queue;
                for (0..els.len) |j| {
                    qq.push(&els[j]);
                }

                _ = count.fetchAdd(@intCast(els.len), .seq_cst);
            }
        }.worker, .{ &q, elems[i * iter_count .. (i + 1) * iter_count], &pushed });
    }

    var start = try std.time.Timer.start();
    var popped: usize = 0;
    while (popped < threads_count * iter_count and start.read() <= std.time.ns_per_s) {
        const count = pushed.load(.seq_cst) - popped;

        if (count == 0) {
            std.Thread.yield() catch {};
            continue;
        }

        for (0..count) |_| {
            try std.testing.expect(q.pop() != null);
        }

        popped += count;
    }

    try std.testing.expect(popped == threads_count * iter_count);
}
