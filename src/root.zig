const std = @import("std");

const impl = @import("./impl.zig");
const iopkg = @import("./io.zig");

pub const Impl = impl.Impl;
pub const Io = Impl.default().Io();

pub const NoOp = iopkg.NoOp;
pub const TimeOut = iopkg.TimeOut;
pub const OpenAt = iopkg.OpenAt;
pub const Close = iopkg.Close;
pub const PRead = iopkg.PRead;
pub const PWrite = iopkg.PWrite;
pub const FSync = iopkg.FSync;
pub const Stat = iopkg.Stat;
pub const GetCwd = iopkg.GetCwd;
pub const ChDir = iopkg.ChDir;
pub const UnlinkAt = iopkg.UnlinkAt;

pub const FileStat = iopkg.FileStat;
