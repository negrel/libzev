//! Implementation independent data structures and helpers function related to
//! I/O.

const std = @import("std");

/// I/O operation code.
pub const OpCode = enum(c_int) {
    noop = 0,
    timeout = 1,
    openat = 2,
};

/// open() I/O operation options.
pub const OpenOptions = struct {
    read: bool = true,
    write: bool = false,
    append: bool = false,
    truncate: bool = false,
    create_new: bool = false,
    create: bool = true,
    mode: u32 = 0o0666,
};

/// Callback type for given implementation.
pub fn Callback(Io: type) type {
    return *const fn (*Io.Op) void;
}

/// Io.poll() mode.
pub const PollMode = enum(c_int) {
    /// Poll events until all I/O operations complete.
    all = 0,
    /// Poll events until at most one I/O operations complete.
    one = 1,
    /// Poll events I/O operation if any without blocking.
    nowait = 2,
};

pub fn Batch(Io: type) type {
    return struct {
        const Self = @This();
        pub const Node = std.SinglyLinkedList.Node;

        list: std.SinglyLinkedList = .{},

        pub fn from(op: *Io.Op) Self {
            var self: Self = .{ .list = .{} };
            self.push(op);
            return self;
        }

        pub fn push(self: *Self, op: *Io.Op) void {
            self.list.prepend(&op.node);
        }

        pub fn pop(self: *Self) ?*Io.Op {
            const n = self.list.popFirst() orelse return null;
            return @fieldParentPtr("node", n);
        }
    };
}
