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

            _ = try testutils.pollAtLeast(Io, &io, 1, std.time.ns_per_s);

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

            _ = try testutils.pollAtLeast(Io, &io, iops.len, std.time.ns_per_s);

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

            var iops: [256]Io.Op = undefined;
            var batch: Io.Batch = .{};

            for (0..iops.len) |i| {
                iops[i] = Io.timeout(i % 5, null, &Static.callback);
                batch.push(&iops[i]);
            }
            try io.submitBatch(batch);

            var start = try std.time.Timer.start();
            _ = try testutils.pollAtLeast(Io, &io, iops.len, std.time.ns_per_s);

            try std.testing.expect(Static.called == iops.len);
            try std.testing.expect(start.read() < std.time.ns_per_s);
        }
    }.tcase);
}

test "openat/pread/close" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var openAtCalled: bool = undefined;
                var preadCalled: bool = undefined;
                var closeCalled: bool = undefined;
                var file: anyerror!std.fs.File = undefined;
                var read: std.fs.File.PReadError!usize = undefined;

                fn openAtCallback(iop: *Io.Op) void {
                    openAtCalled = true;
                    file = iop.data.openat.file;
                }

                fn preadCallback(iop: *Io.Op) void {
                    preadCalled = true;
                    read = iop.data.pread.read;
                }

                fn closeCallback(iop: *Io.Op) void {
                    closeCalled = true;
                    _ = iop.data.close;
                }
            };
            Static.openAtCalled = false;
            Static.preadCalled = false;
            Static.closeCalled = false;
            Static.file = undefined;
            Static.read = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            const f = try testutils.openat(
                Io,
                &io,
                std.fs.cwd(),
                "./src/testdata/file.txt",
                .{ .read = true },
            );

            // Read.
            {
                var buf: [64]u8 = undefined;
                var pread = Io.pread(f, buf[0..], 0, null, Static.preadCallback);

                try io.submit(&pread);

                _ = try testutils.pollAtLeast(Io, &io, 1, std.time.ns_per_s);

                const read = try Static.read;

                try std.testing.expectEqualStrings(
                    "Hello from text file!\n",
                    buf[0..read],
                );
            }

            // Close.
            try testutils.close(Io, &io, f);
        }
    }.tcase);
}

test "openat/pwrite/fsync/close" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var openAtCalled: bool = undefined;
                var pwriteCalled: bool = undefined;
                var fsyncCalled: bool = undefined;
                var closeCalled: bool = undefined;
                var file: anyerror!std.fs.File = undefined;
                var write: std.fs.File.PWriteError!usize = undefined;
                var fsyncResult: std.fs.File.SyncError!void = undefined;

                fn openAtCallback(iop: *Io.Op) void {
                    openAtCalled = true;
                    file = iop.data.openat.file;
                }

                fn pwriteCallback(iop: *Io.Op) void {
                    pwriteCalled = true;
                    write = iop.data.pwrite.write;
                }

                fn fsyncCallback(iop: *Io.Op) void {
                    fsyncCalled = true;
                    fsyncResult = iop.data.fsync.result;
                }

                fn closeCallback(iop: *Io.Op) void {
                    closeCalled = true;
                    _ = iop.data.close;
                }
            };
            Static.openAtCalled = false;
            Static.pwriteCalled = false;
            Static.closeCalled = false;
            Static.file = undefined;
            Static.write = undefined;
            Static.fsyncResult = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            const tmpDir = std.testing.tmpDir(.{});

            const f = try testutils.openat(
                Io,
                &io,
                tmpDir.dir,
                "./file.txt",
                .{
                    .read = true,
                    .write = true,
                    .create = true,
                    .truncate = true,
                },
            );

            // Write.
            {
                var buf: []const u8 = "Hello world!";
                var pwrite = Io.pwrite(f, buf[0..], 0, null, Static.pwriteCallback);

                try io.submit(&pwrite);

                _ = try testutils.pollAtLeast(Io, &io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.pwriteCalled);

                const write = try Static.write;

                try std.testing.expect(write == buf.len);

                var rbuf: [64]u8 = undefined;
                const read = try f.pread(rbuf[0..], 0);

                try std.testing.expect(read == 12);
                try std.testing.expectEqualStrings(buf, rbuf[0..read]);
            }

            // FSync.
            {
                var fsync = Io.fsync(f, null, Static.fsyncCallback);

                try io.submit(&fsync);

                _ = try testutils.pollAtLeast(Io, &io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.fsyncCalled);

                try Static.fsyncResult;
            }

            // Close.
            try testutils.close(Io, &io, f);
        }
    }.tcase);
}

test "openat/stat/close" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var openAtCalled: bool = undefined;
                var statCalled: bool = undefined;
                var closeCalled: bool = undefined;
                var file: anyerror!std.fs.File = undefined;
                var stat: std.fs.File.StatError!std.fs.File.Stat = undefined;

                fn openAtCallback(iop: *Io.Op) void {
                    openAtCalled = true;
                    file = iop.data.openat.file;
                }

                fn statCallback(iop: *Io.Op) void {
                    statCalled = true;
                    stat = iop.data.stat.stat;
                }

                fn closeCallback(iop: *Io.Op) void {
                    closeCalled = true;
                    _ = iop.data.close;
                }
            };
            Static.openAtCalled = false;
            Static.statCalled = false;
            Static.closeCalled = false;
            Static.file = undefined;
            Static.stat = undefined;

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

                _ = try testutils.pollAtLeast(Io, &io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.openAtCalled);
            }

            const f = try Static.file;

            // Stat.
            {
                var stat = Io.stat(f, null, Static.statCallback);

                try io.submit(&stat);

                _ = try testutils.pollAtLeast(Io, &io, 1, std.time.ns_per_s);

                const s = try Static.stat;

                try std.testing.expect(s.inode != 0);
                try std.testing.expect(s.atime > 0);
                try std.testing.expect(s.mtime > 0);
                try std.testing.expect(s.ctime > 0);
                try std.testing.expect(s.size == 22);
                //try std.testing.expect(s.mode == 0);
            }

            // Close.
            try testutils.close(Io, &io, f);
        }
    }.tcase);
}

const testutils = struct {
    const iopkg = @import("./io.zig");

    fn pollAtLeast(
        Io: type,
        io: *Io,
        completed: usize,
        ns: u64,
    ) !usize {
        var done: usize = 0;
        var start = try std.time.Timer.start();
        while (done < completed and start.read() < ns) {
            done += try io.poll(.all);
        }

        try std.testing.expect(done >= completed);
        return done;
    }

    fn openat(
        Io: type,
        io: *Io,
        dir: std.fs.Dir,
        path: [:0]const u8,
        opts: iopkg.OpenOptions,
    ) !std.fs.File {
        const Static = struct {
            var callbackCalled: bool = undefined;
            var file: std.fs.File.OpenError!std.fs.File = undefined;

            fn openAtCallback(iop: *Io.Op) void {
                callbackCalled = true;
                file = iop.data.openat.file;
            }
        };
        Static.callbackCalled = false;

        var op = Io.openat(dir, path, opts, null, Static.openAtCallback);

        try io.submit(&op);
        _ = try pollAtLeast(Io, io, 1, std.time.ns_per_s);

        try std.testing.expect(Static.callbackCalled);

        return try Static.file;
    }

    fn close(
        Io: type,
        io: *Io,
        f: std.fs.File,
    ) !void {
        const Static = struct {
            var callbackCalled: bool = undefined;

            fn closeCallback(iop: *Io.Op) void {
                callbackCalled = true;
                _ = iop.data.close;
            }
        };
        Static.callbackCalled = false;

        var op = Io.close(f, null, Static.closeCallback);

        try io.submit(&op);

        _ = try pollAtLeast(Io, io, 1, std.time.ns_per_s);

        try std.testing.expect(Static.callbackCalled);
    }
};
