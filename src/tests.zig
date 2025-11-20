const std = @import("std");
const zev = @import("./root.zig");

fn forEachAvailableImpl(tcase: anytype) !void {
    inline for (zev.Impl.available()) |i| {
        const ImplIo = i.Io();
        @call(.auto, tcase, .{ImplIo}) catch |err| {
            std.debug.print("\nIo={s} error={s}\n\n", .{ @typeName(ImplIo), @errorName(err) });
            return err;
        };
    }
}

test "single noop" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: bool = undefined;

                fn callback(_: *Io, _: *Io.Op(zev.NoOp)) void {
                    called = true;
                }
            };
            Static.called = false;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var op: Io.Op(zev.NoOp) = Io.noOp(.{}, null, Static.callback);
            try testutils.queue(&io, &op, 1);
            try testutils.submit(&io, 1);

            _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

            try std.testing.expect(Static.called);
        }
    }.tcase);
}

test "batch of noop" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: usize = undefined;
                fn callback(_: *Io, _: *Io.Op(zev.NoOp)) void {
                    called += 1;
                }
            };
            Static.called = 0;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var noops: [16]Io.Op(zev.NoOp) = undefined;

            for (0..noops.len) |i| {
                noops[i] = Io.noOp(.{}, null, &Static.callback);
                try testutils.queue(&io, &noops[i], i + 1);
            }
            try testutils.submit(&io, noops.len);

            _ = try testutils.pollAtLeast(&io, noops.len, std.time.ns_per_s);

            try std.testing.expect(Static.called == noops.len);
        }
    }.tcase);
}

test "batch of timeout" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var called: usize = undefined;
                fn callback(_: *Io, _: *Io.Op(zev.TimeOut)) void {
                    called += 1;
                }
            };
            Static.called = 0;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var timeouts: [16]Io.Op(zev.TimeOut) = undefined;

            for (0..timeouts.len) |i| {
                timeouts[i] = Io.timeOut(.{
                    .msec = i % 5,
                }, null, &Static.callback);
                try testutils.queue(&io, &timeouts[i], i + 1);
            }
            try testutils.submit(&io, timeouts.len);

            var start = try std.time.Timer.start();
            _ = try testutils.pollAtLeast(&io, timeouts.len, std.time.ns_per_s);

            try std.testing.expect(Static.called == timeouts.len);
            try std.testing.expect(start.read() < 16 * 5 * std.time.ns_per_ms);
            try std.testing.expect(start.read() > 5 * std.time.ns_per_ms);
        }
    }.tcase);
}

test "openat/pread/close" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var preadCalled: bool = undefined;
                var read: zev.PRead.Error!usize = undefined;

                fn preadCallback(_: *Io, iop: *Io.Op(zev.PRead)) void {
                    preadCalled = true;
                    read = iop.data.result;
                }
            };
            Static.preadCalled = false;
            Static.read = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            const f = try testutils.openAt(
                &io,
                .{
                    .dir = std.fs.cwd(),
                    .path = "./src/testdata/file.txt",
                    .options = .{ .read = true },
                    .mode = 0,
                },
            );

            // Read offset -1.
            {
                var buf: [64]u8 = undefined;
                var pread = Io.pRead(.{
                    .file = f,
                    .buffer = buf[0..6],
                    .offset = -1,
                }, null, Static.preadCallback);

                try testutils.queue(&io, &pread, 1);
                try testutils.submit(&io, 1);

                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                const read = try Static.read;

                try std.testing.expectEqualStrings(
                    "Hello ",
                    buf[0..read],
                );
            }

            // Read offset 0.
            {
                var buf: [64]u8 = undefined;
                var pread = Io.pRead(.{
                    .file = f,
                    .buffer = buf[0..],
                    .offset = 0,
                }, null, Static.preadCallback);

                try testutils.queue(&io, &pread, 1);
                try testutils.submit(&io, 1);

                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                const read = try Static.read;

                try std.testing.expectEqualStrings(
                    "Hello from text file!\n",
                    buf[0..read],
                );
            }

            // Close.
            try testutils.close(&io, .{ .file = f });
        }
    }.tcase);
}

test "openat/pwrite/fsync/close/unlinkat" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var pwriteCalled: bool = undefined;
                var fsyncCalled: bool = undefined;
                var unlinkAtCalled: bool = undefined;
                var write: zev.PWrite.Error!usize = undefined;
                var fsync: zev.FSync.Error!void = undefined;
                var unlinkAt: zev.UnlinkAt.Error!void = undefined;

                fn pwriteCallback(_: *Io, iop: *Io.Op(zev.PWrite)) void {
                    pwriteCalled = true;
                    write = iop.data.result;
                }

                fn fsyncCallback(_: *Io, iop: *Io.Op(zev.FSync)) void {
                    fsyncCalled = true;
                    fsync = iop.data.result;
                }

                fn unlinkAtCallback(_: *Io, iop: *Io.Op(zev.UnlinkAt)) void {
                    unlinkAtCalled = true;
                    unlinkAt = iop.data.result();
                }
            };
            Static.pwriteCalled = false;
            Static.fsyncCalled = false;
            Static.unlinkAtCalled = false;
            Static.write = undefined;
            Static.fsync = undefined;
            Static.unlinkAt = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            const tmpDir = std.testing.tmpDir(.{});

            const f = try testutils.openAt(
                &io,
                .{
                    .dir = tmpDir.dir,
                    .path = "file.txt",
                    .options = .{
                        .read = true,
                        .write = true,
                        .create = true,
                        .truncate = true,
                    },
                    .mode = 0o666,
                },
            );

            // Write.
            {
                var buf: []const u8 = "Hello world!";
                var pwrite = Io.pWrite(.{
                    .file = f,
                    .buffer = buf[0..],
                    .offset = 0,
                }, null, Static.pwriteCallback);

                try testutils.queue(&io, &pwrite, 1);
                try testutils.submit(&io, 1);
                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

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
                var fsync = Io.fSync(.{ .file = f }, null, Static.fsyncCallback);

                try testutils.queue(&io, &fsync, 1);
                try testutils.submit(&io, 1);
                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.fsyncCalled);

                try Static.fsync;
            }

            // Close.
            try testutils.close(&io, .{ .file = f });

            // Unlink.
            {
                var unlinkAt = Io.unlinkAt(.{
                    .dir = tmpDir.dir,
                    .path = "file.txt",
                    .remove_dir = false,
                }, null, Static.unlinkAtCallback);

                try testutils.queue(&io, &unlinkAt, 1);
                try testutils.submit(&io, 1);
                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.unlinkAtCalled);

                try Static.unlinkAt;
            }
        }
    }.tcase);
}

test "openat/stat/close" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var statCalled: bool = undefined;
                var stat: zev.FStat.Error!zev.FStat.Stat = undefined;

                fn statCallback(_: *Io, iop: *Io.Op(zev.FStat)) void {
                    statCalled = true;
                    stat = iop.data.result;
                }
            };
            Static.statCalled = false;
            Static.stat = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            // Open.
            const f = try testutils.openAt(&io, .{
                .dir = std.fs.cwd(),
                .path = "./src/testdata/file.txt",
                .options = .{ .read = true },
                .mode = 0,
            });

            // Stat.
            {
                var stat = Io.fStat(.{ .file = f }, null, Static.statCallback);

                try testutils.queue(&io, &stat, 1);
                try testutils.submit(&io, 1);
                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                const s = try Static.stat;

                try std.testing.expect(s.inode != 0);
                try std.testing.expect(s.atime > 0);
                try std.testing.expect(s.mtime > 0);
                try std.testing.expect(s.ctime > 0);
                try std.testing.expect(s.size == 22);
                //try std.testing.expect(s.mode == 0);
            }

            // Close.
            try testutils.close(&io, .{ .file = f });
        }
    }.tcase);
}

test "getcwd" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var callbackCalled: bool = undefined;
                var cwd: zev.GetCwd.Error![]u8 = undefined;

                fn getCwdCallback(_: *Io, iop: *Io.Op(zev.GetCwd)) void {
                    callbackCalled = true;
                    cwd = iop.data.result();
                }
            };
            Static.callbackCalled = false;
            Static.cwd = undefined;

            var allocator = std.heap.smp_allocator;
            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var buffer: [4096]u8 = undefined;
            var getcwd = Io.getCwd(.{
                .buffer = buffer[0..],
            }, null, Static.getCwdCallback);

            try testutils.queue(&io, &getcwd, 1);
            try testutils.submit(&io, 1);
            _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

            try std.testing.expect(Static.callbackCalled);

            const expected = try std.process.getCwdAlloc(allocator);
            defer allocator.free(expected);

            const actual = try Static.cwd;

            try std.testing.expectEqualStrings(expected, actual);
        }
    }.tcase);
}

test "chdir" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var callbackCalled: bool = undefined;
                var result: std.posix.ChangeCurDirError!void = undefined;

                fn chdirCallback(_: *Io, iop: *Io.Op(zev.ChDir)) void {
                    callbackCalled = true;
                    result = iop.data.result();
                }
            };
            Static.callbackCalled = false;
            Static.result = undefined;

            var initial_cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
            const initial_cwd = try std.process.getCwd(initial_cwd_buf[0..]);

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            var chdir = Io.chDir(.{ .path = ".." }, null, Static.chdirCallback);

            try testutils.queue(&io, &chdir, 1);
            try testutils.submit(&io, 1);
            _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

            try Static.result;

            try std.testing.expect(Static.callbackCalled);

            var new_cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
            const new_cwd = try std.process.getCwd(new_cwd_buf[0..]);

            try std.testing.expect(!std.mem.eql(u8, initial_cwd, new_cwd));
        }
    }.tcase);
}

test "spawn/wait" {
    try forEachAvailableImpl(struct {
        fn tcase(Io: type) !void {
            const Static = struct {
                var spawnCalled: bool = undefined;
                var waitPidCalled: bool = undefined;
                var spawn: zev.Spawn.Error!std.posix.pid_t = undefined;
                var waitPid: zev.WaitPid.Error!u32 = undefined;

                fn spawnCallback(
                    _: *Io,
                    op: *Io.Op(zev.Spawn),
                ) void {
                    spawn = op.data.result();
                    spawnCalled = true;
                }

                fn waitPidCallback(
                    _: *Io,
                    op: *Io.Op(zev.WaitPid),
                ) void {
                    waitPid = op.data.result();
                    waitPidCalled = true;
                }
            };
            Static.spawnCalled = false;
            Static.waitPidCalled = false;
            Static.spawn = undefined;
            Static.waitPid = undefined;

            var io: Io = .{};
            try io.init(.{});
            defer io.deinit();

            // Spawn.
            {
                var spawn = Io.spawn(.{
                    .args = &.{ "ls", null },
                    .env_vars = &.{null},
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }, null, Static.spawnCallback);

                try testutils.queue(&io, &spawn, 1);
                try testutils.submit(&io, 1);
                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.spawnCalled);
            }

            const pid = try Static.spawn;

            // Wait pid.
            {
                var waitpid = Io.waitPid(.{
                    .pid = pid,
                }, null, Static.waitPidCallback);

                try testutils.queue(&io, &waitpid, 1);
                try testutils.submit(&io, 1);
                _ = try testutils.pollAtLeast(&io, 1, std.time.ns_per_s);

                try std.testing.expect(Static.waitPidCalled);

                const status = Static.waitPid;
                try std.testing.expectEqual(0, status);
            }
        }
    }.tcase);
}

const testutils = struct {
    fn Deref(T: type) type {
        return @typeInfo(T).pointer.child;
    }

    fn queue(io: anytype, op: anytype, queued: usize) !void {
        const actual = try io.queue(op);
        try std.testing.expectEqual(queued, actual);
    }

    fn submit(io: anytype, submitted: usize) !void {
        const actual = try io.submit();
        try std.testing.expectEqual(submitted, actual);
    }

    fn pollAtLeast(
        io: anytype,
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

    fn openAt(
        io: anytype,
        data: zev.OpenAt,
    ) !std.fs.File {
        const Io = Deref(@TypeOf(io));

        const Static = struct {
            var callbackCalled: bool = undefined;
            var file: zev.OpenAt.Error!std.fs.File = undefined;

            fn openAtCallback(_: *Io, op: *Io.Op(zev.OpenAt)) void {
                callbackCalled = true;
                file = op.data.result;
            }
        };
        Static.callbackCalled = false;

        var op = Io.openAt(data, null, Static.openAtCallback);

        _ = try io.queue(&op);
        _ = try io.submit();
        _ = try pollAtLeast(io, 1, std.time.ns_per_s);

        try std.testing.expect(Static.callbackCalled);

        return try Static.file;
    }

    fn close(
        io: anytype,
        data: zev.Close,
    ) !void {
        const Io = Deref(@TypeOf(io));

        const Static = struct {
            var callbackCalled: bool = undefined;
            var result: zev.Close.Error!void = undefined;

            fn closeCallback(_: *Io, op: *Io.Op(zev.Close)) void {
                callbackCalled = true;
                result = op.data.result;
            }
        };
        Static.callbackCalled = false;

        var op = Io.close(data, null, Static.closeCallback);

        _ = try io.queue(&op);
        _ = try io.submit();
        _ = try pollAtLeast(io, 1, std.time.ns_per_s);

        try std.testing.expect(Static.callbackCalled);
        try Static.result;
    }
};
