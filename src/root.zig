const std = @import("std");

const impl = @import("./impl.zig");
const io = @import("./io.zig");

pub const ThreadPool = @import("./ThreadPool.zig");

pub const Impl = impl.Impl;
pub const Io = Impl.default().Io();

// io.Op(...)
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
pub const Socket = io.Socket;
pub const Bind = io.Bind;
pub const Listen = io.Listen;
pub const Accept = io.Accept;
pub const Connect = io.Connect;
pub const Shutdown = io.Shutdown;
pub const CloseSocket = io.CloseSocket;
pub const Recv = io.Recv;
pub const Send = io.Send;

pub const OpCode = io.OpCode;
pub const PollMode = io.PollMode;
pub const FileStat = io.FileStat;
