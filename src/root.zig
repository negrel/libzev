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

test "openat/close" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var openAtCalled: bool = undefined;
                var closeCalled: bool = undefined;
                var file: anyerror!std.fs.File = undefined;

                fn openAtCallback(iop: *Io.Op) void {
                    openAtCalled = true;
                    file = iop.data.openat.file;
                }

                fn closeCallback(iop: *Io.Op) void {
                    closeCalled = true;
                    _ = iop.data.close;
                }
            };
            Static.openAtCalled = false;
            Static.file = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            // Open.
            {
                var openat = Io.openat(
                    std.fs.cwd(),
                    "./src/testdata/file.txt",
                    .{ .read = true },
                    null,
                    Static.openAtCallback,
                );

                try io.submit(&openat);

                var done: usize = 0;
                while (done == 0) {
                    done = try io.poll(.all);
                    try std.Thread.yield();
                }

                try std.testing.expect(done == 1);
                try std.testing.expect(Static.openAtCalled);
            }

            const f = try Static.file;

            // Read.
            {
                var buf: [64]u8 = undefined;
                const read = try f.read(buf[0..buf.len]);
                try std.testing.expectEqualStrings(
                    "Hello from text file!\n",
                    buf[0..read],
                );
            }

            // Close.
            {
                var close = Io.close(f, null, Static.closeCallback);

                try io.submit(&close);

                var done: usize = 0;
                while (done == 0) {
                    done = try io.poll(.all);
                }

                try std.testing.expect(done == 1);
                try std.testing.expect(Static.closeCalled);
            }
        }
    }.tcase);
}
