//! This files contains POSIX functions copied from Zig's std library but with
//! 0 unreachable statement.

const std = @import("std");
const posix = std.posix;

pub const timespec = posix.timespec;

pub const NanoSleepError = error{
    BadAddress,
    SignalInterrupt,
    InvalidSyscallParameters,
    Unexpected,
};

pub fn nanosleep(req: timespec, rem: *timespec) NanoSleepError!void {
    return switch (posix.errno(posix.system.nanosleep(&req, rem))) {
        .SUCCESS => {},
        .FAULT => NanoSleepError.BadAddress,
        .INVAL => NanoSleepError.InvalidSyscallParameters,
        .INTR => NanoSleepError.SignalInterrupt,
        else => |err| unexpectedErrno(err),
    };
}

// TODO:
pub const openZ = posix.openZ;

// Reexported functions.
pub const unexpectedErrno = posix.unexpectedErrno;
pub const exit = posix.exit;
pub const errno = posix.errno;
pub const O = posix.O;
pub const AT = posix.AT;
