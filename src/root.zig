const std = @import("std");

const impl = @import("./impl.zig");
const io = @import("./io.zig");

pub const Impl = impl.Impl;
pub const Io = Impl.default().Io();

pub const PollMode = io.PollMode;

pub const NoOp = io.NoOp;
pub const TimeOut = io.TimeOut;
pub const OpenAt = io.OpenAt;
pub const Close = io.Close;
pub const PRead = io.PRead;
pub const PWrite = io.PWrite;
pub const FSync = io.FSync;
pub const Stat = io.Stat;
pub const GetCwd = io.GetCwd;
pub const ChDir = io.ChDir;
pub const UnlinkAt = io.UnlinkAt;

pub const FileStat = io.FileStat;
