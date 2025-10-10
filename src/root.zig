const std = @import("std");

pub const Backend = @import("./backend.zig");

test {
    _ = Backend;
}

// const TPool = @import("./ThreadPool.zig");
// const queue_mpsc = @import("./queue_mpsc.zig");
//
// /// A submit and poll asynchronous I/O event loop.
// pub const Loop = struct {
//     backend: Backend.Impl,
//
//     fn init() Loop {
//         const self: Loop = .{ .backend = Backend.init() };
//         return self;
//     }
//
//     fn deinit(self: *Loop) void {
//         self.backend.deinit();
//     }
//
//     /// Submits an asynchronous I/O operations.
//     fn submit(self: *Loop, op: *Operation) void {
//         std.debug.assert(op.state == .dead);
//         op.state = .submitted;
//     }
//
//     /// Poll until an asynchronous I/O operation completes.
//     fn poll(self: *Loop) void {
//         if (self.active == 0) return;
//     }
// };
//
// /// An asynchronous I/O operation.
// pub const Operation = struct {
//     /// BackendData holds operation data depending on backend.
//     const BackendData = union {
//         thread_pool: struct {
//             const ThreadPoolData = @This();
//
//             task: TPool.Task = .{
//                 .callback = struct {
//                     pub fn cb(t: *TPool.Task) void {
//                         const tpd: *ThreadPoolData = @fieldParentPtr("task", t);
//                         const op: *Operation = @fieldParentPtr("bdata", tpd);
//                         op.sync();
//                         op.loop.backend.done.push(op);
//                     }
//                 }.cb,
//             },
//         },
//     };
//
//     // UAIO owner.
//     loop: *Loop = undefined,
//
//     // Operation state.
//     state: State = .dead,
//
//     // Backend data.
//     bdata: BackendData = .{},
//
//     // Operation data.
//     data: Data,
//
//     // Callback executed after completion.
//     callback: *const fn (_: *Loop, _: *Operation) void,
// };
//
// /// Backend is the underlying implementation of interface:
// /// {
// ///   fn submit(*Self, *Operation) void
// ///   fn poll(*Self) void
// /// }
// const Backend = enum {
//     thread_pool,
//
//     const Impl = union(Backend) {
//         thread_pool: struct {
//             const Self = @This();
//
//             // Number of pending operations.
//             pending: usize = 0,
//
//             // Thread pool and done queue.
//             tpool: TPool = .{},
//             done: queue_mpsc.Intrusive(Operation) = .{},
//
//             // Futex to wake up blocking poll.
//             futex: std.Thread.Futex,
//             futex_v: std.atomic.Value(u32),
//
//             fn submit(self: *Self, op: *Operation) void {
//                 const batch = TPool.Batch.from(op.bdata);
//                 self.tpool.schedule(batch);
//                 self.active += 1;
//             }
//
//             fn poll(self: *Self, l: *Loop) void {
//                 if (self.pending == 0) return 0;
//
//                 if (self.done.pop()) |op| {
//                     op.callback(l, op);
//                 } else {
//                     self.futex_v.store(1, .unordered);
//                     self.futex.wait(&self.futex_v, 1);
//                 }
//
//                 while (self.done.pop()) |op| {
//                     op.callback(l, op);
//                 }
//             }
//         },
//     };
//
//     const Data = union(Backend) {
//         thread_pool: struct {
//             const Self = @This();
//         },
//     };
// };
