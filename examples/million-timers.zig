const std = @import("std");
const zev = @import("zev");

var timer_cb_called: usize = 0;

pub fn main() !void {
    const before_all = try std.time.Instant.now();

    var io: zev.Io = undefined;
    try io.init(
        if (zev.Impl.io_uring.Io() == zev.Io) .{
            .entries = std.math.pow(u13, 2, 12),
        } else .{},
    );
    defer io.deinit();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var allocator = gpa.allocator();

    var timers = try allocator.alloc(zev.Io.Op(zev.TimeOut), 10_000_000);
    defer allocator.free(timers);

    const before_submit = try std.time.Instant.now();

    // Submit all timers.
    {
        for (timers[0..timers.len]) |*t| {
            t.* = zev.Io.timeOut(.{ .ms = 1 }, null, timerCallback);

            _ = io.queue(t) catch {
                _ = try io.submit();
                _ = try io.queue(t);
            };
        }
        _ = try io.submit();
    }

    const before_poll = try std.time.Instant.now();
    // Poll all timers.
    {
        _ = try io.poll(.all);
    }
    const after_poll = try std.time.Instant.now();

    std.log.info("{d:.2} seconds total", .{@as(f64, @floatFromInt(after_poll.since(before_all))) / std.time.ns_per_s});
    std.log.info("{d:.2} seconds init", .{@as(f64, @floatFromInt(before_submit.since(before_all))) / std.time.ns_per_s});
    std.log.info("{d:.2} seconds submit", .{@as(f64, @floatFromInt(before_poll.since(before_submit))) / std.time.ns_per_s});
    std.log.info("{d:.2} seconds poll", .{@as(f64, @floatFromInt(after_poll.since(before_poll))) / std.time.ns_per_s});

    if (timer_cb_called != timers.len) return error.MissingTimers;
}

fn timerCallback(_: *zev.Io, _: *zev.Io.Op(zev.TimeOut)) callconv(.c) void {
    timer_cb_called += 1;
}
