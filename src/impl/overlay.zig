const std = @import("std");

const io = @import("../io.zig");
const computils = @import("../computils.zig");
const Deref = computils.Deref;

/// Overlay implementation merges two implementation into a lower and upper one.
/// If an I/O operation is not supported by the upper implementation, it is
/// forwarded to the lower one.
pub fn Overlay(Upper: type, Lower: type) type {
    if (Upper == Lower) return Upper;

    return struct {
        const Io = @This();

        upper: Upper = undefined,
        lower: Lower = undefined,

        pub fn init(self: *Io, opts: Options) !void {
            try self.upper.init(opts.upper);
            errdefer self.upper.deinit();
            try self.lower.init(opts.lower);
        }

        pub fn deinit(self: *Io) void {
            self.upper.deinit();
            self.lower.deinit();
        }

        pub fn submit(
            self: *Io,
            op: anytype,
        ) (error{UnsupportedOp} || anyerror)!void {
            comptime {
                std.debug.assert(
                    std.mem.startsWith(u8, @typeName(@TypeOf(op)), "*io.Op("),
                );
            }

            if (Upper.supports(@TypeOf(op))) {
                return self.upper.submit(op);
            }
            return self.lower.submit(
                @as(*Lower.Op(Deref(@TypeOf(op)).Data), @ptrCast(op)),
            );
        }

        pub fn poll(self: *Io, mode: io.PollMode) !u32 {
            return switch (mode) {
                .all => {
                    return std.math.add(
                        u32,
                        try self.upper.poll(.all),
                        try self.lower.poll(.all),
                    ) catch std.math.maxInt(u32);
                },
                .one => {
                    const upper_done = try self.upper.poll(.nowait);
                    const lower_done = try self.lower.poll(
                        if (upper_done > 0)
                            .nowait
                        else
                            .one,
                    );

                    return std.math.add(u32, lower_done, upper_done) catch
                        std.math.maxInt(u32);
                },
                .nowait => {
                    return std.math.add(
                        u32,
                        try self.upper.poll(.nowait),
                        try self.lower.poll(.nowait),
                    ) catch std.math.maxInt(u32);
                },
            };
        }

        pub const Options = struct {
            upper: Upper.Options = .{},
            lower: Lower.Options = .{},
        };

        fn OpIo(T: type) type {
            if (Upper.supports(*Upper.Op(T)))
                return Upper;
            return Lower;
        }

        pub fn Op(T: type) type {
            return OpIo(T).Op(T);
        }

        pub fn OpPrivateData(T: type) type {
            return OpIo(T).OpPrivateData(T);
        }

        fn opInitOf(T: type) io.OpConstructor(Io, T) {
            return struct {
                fn func(
                    data: if (@hasDecl(T, "Intern")) T.Intern else T,
                    user_data: ?*anyopaque,
                    comptime callback: *const fn (*Io, *Op(T)) void,
                ) Op(T) {
                    const cb = struct {
                        fn cb(i: *OpIo(T), op: *OpIo(T).Op(T)) void {
                            if (OpIo(T) == Upper) {
                                callback(
                                    @fieldParentPtr("upper", i),
                                    op,
                                );
                            } else {
                                callback(
                                    @fieldParentPtr("lower", i),
                                    op,
                                );
                            }
                        }
                    }.cb;

                    return io.opInitOf(OpIo(T), T)(
                        data,
                        user_data,
                        cb,
                    );
                }
            }.func;
        }

        pub const noOp = opInitOf(io.NoOp);
        pub const sleep = opInitOf(io.Sleep);
        pub const openAt = opInitOf(io.OpenAt);
        pub const close = opInitOf(io.Close);
        pub const pRead = opInitOf(io.PRead);
        pub const pWrite = opInitOf(io.PWrite);
        pub const fSync = opInitOf(io.FSync);
        pub const fStat = opInitOf(io.FStat);
        pub const getCwd = opInitOf(io.GetCwd);
        pub const chDir = opInitOf(io.ChDir);
        pub const unlinkAt = opInitOf(io.UnlinkAt);
        pub const spawn = opInitOf(io.Spawn);
        pub const waitPid = opInitOf(io.WaitPid);
    };
}
