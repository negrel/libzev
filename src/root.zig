const std = @import("std");

const impl = @import("./impl.zig");

fn forEachAvailableImpl(tcase: anytype) !void {
    inline for (impl.Impl.available()) |i| {
        try @call(.auto, tcase, .{i.Impl()});
    }
}

test "single noop" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: bool = undefined;

                fn callback(_: *Io.Op) void {
                    called = true;
                }
            };
            Static.called = false;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var noopOp = Io.noop(null, &Static.callback);
            try io.submit(&noopOp);

            var done: usize = 0;
            var start = try std.time.Timer.start();
            while (done < 1 and start.read() < std.time.ns_per_s) {
                done += try io.poll(.one);
            }

            try std.testing.expect(done == 1);
            try std.testing.expect(Static.called);
        }
    }.tcase);
}

test "batch of noop" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: usize = undefined;
                fn callback(_: *Io.Op) void {
                    called += 1;
                }
            };
            Static.called = 0;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var iops: [4096]Io.Op = undefined;
            var batch: Io.Batch = .{};

            for (0..iops.len) |i| {
                iops[i] = Io.noop(null, &Static.callback);
                batch.push(&iops[i]);
            }
            try io.submitBatch(batch);

            var done: usize = 0;
            var start = try std.time.Timer.start();
            while (done < iops.len and start.read() < std.time.ns_per_s) {
                done += try io.poll(.all);
            }

            try std.testing.expect(Static.called == iops.len);
        }
    }.tcase);
}

test "batch of timeout" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: usize = undefined;
                fn callback(_: *Io.Op) void {
                    called += 1;
                }
            };
            Static.called = 0;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var iops: [4096]Io.Op = undefined;
            var batch: Io.Batch = .{};

            for (0..iops.len) |i| {
                iops[i] = Io.timeout(5, null, &Static.callback);
                batch.push(&iops[i]);
            }
            try io.submitBatch(batch);

            var done: usize = 0;
            for (0..iops.len) |_| {
                const polled = try io.poll(.all);
                done += polled;

                if (done >= iops.len) break;
            }
            try std.testing.expect(Static.called == iops.len);
        }
    }.tcase);
}

test "openat" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: bool = undefined;
                var file: anyerror!std.fs.File = undefined;
                fn callback(iop: *Io.Op) void {
                    called = true;
                    file = iop.data.openat.file;
                }
            };
            Static.called = false;
            Static.file = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var openat = Io.openat(
                std.fs.cwd(),
                "./src/testdata/file.txt",
                .{ .read = true },
                null,
                Static.callback,
            );

            try io.submit(&openat);
            var done: usize = 0;
            while (true) {
                done = io.poll(.all) catch |err| @panic(@errorName(err));
                if (done != 0) break;
                try std.Thread.yield();
            }

            try std.testing.expect(done == 1);
            try std.testing.expect(Static.called);

            const f = try Static.file;

            var buf: [64]u8 = undefined;
            const read = try f.read(buf[0..buf.len]);
            try std.testing.expectEqualStrings(
                "Hello from text file!\n",
                buf[0..read],
            );
        }
    }.tcase);
}
