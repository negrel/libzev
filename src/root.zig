const std = @import("std");

const impl = @import("./impl.zig");
const io = @import("./io.zig");

pub const ThreadPool = @import("./ThreadPool.zig");

pub const Impl = impl.Impl;
pub const Io = Impl.default().Io();
pub const Overlay = @import("./impl/overlay.zig").Overlay;

// io.Op(...)
pub const NoOp = io.NoOp;
pub const Sleep = io.Sleep;
pub const OpenAt = io.OpenAt;
pub const Close = io.Close;
pub const PRead = io.PRead;
pub const PWrite = io.PWrite;
pub const FSync = io.FSync;
pub const FStat = io.FStat;
pub const GetCwd = io.GetCwd;
pub const ChDir = io.ChDir;
pub const UnlinkAt = io.UnlinkAt;
pub const Spawn = io.Spawn;
pub const WaitPid = io.WaitPid;
pub const Pipe = io.Pipe;

pub const OpHeader = io.OpHeader;
pub const OpCode = io.OpCode;
pub const PollMode = io.PollMode;

pub const QueueError = io.QueueError;
pub const SubmitError = io.SubmitError;
