//! Implementation independent data structures and helpers function related to
//! I/O.

const std = @import("std");
const fs = std.fs;

const posix = @import("./posix.zig");

pub const OpCode = enum(c_int) {
    noop,
    timeout,
    openat,
    close,
    pread,
    pwrite,
    fsync,
    stat,
    getcwd,
    chdir,
    unlinkat,
    socket,
    bind,
    listen,
    accept,
    connect,
    shutdown,
    closesocket,
    recv,
    send,
    spawn,
    waitpid,

    pub fn Data(self: @This()) type {
        return switch (self) {
            .noop => NoOp,
            .timeout => TimeOut,
            .openat => OpenAt,
            .close => Close,
            .pread => PRead,
            .pwrite => PWrite,
            .fsync => FSync,
            .stat => Stat,
            .getcwd => GetCwd,
            .chdir => ChDir,
            .unlinkat => UnlinkAt,
            .socket => Socket,
            .bind => Bind,
            .listen => Listen,
            .accept => Accept,
            .connect => Connect,
            .shutdown => Shutdown,
            .closesocket => CloseSocket,
            .recv => Recv,
            .send => Send,
            .spawn => Spawn,
            .waitpid => WaitPid,
        };
    }
};

/// OpHeader defines field at the beginning of Op(Io, T) that don't depend on
/// Io and T. It is always safe to read OpHeader even if Io and T are unknown.
pub const OpHeader = extern struct {
    code: OpCode,

    callback: *const fn (*anyopaque, op_h: *OpHeader) callconv(.c) void,
    user_data: ?*anyopaque,
};

/// Op defines an I/O operation structure. It is made of a static header and
/// Io / T dependent fields:
///
/// +----------+---------------+
/// | OpHeader | OpBody(Io, T) |
/// +----------+---------------+
///
pub fn Op(Io: type, T: type) type {
    return extern struct {
        const Impl = Io;

        header: OpHeader = undefined,

        // Implementation specific fields.
        private: Impl.OpPrivateData(T),

        // Operation data.
        data: T,

        pub fn fromHeader(h: *OpHeader) *Op(Io, T) {
            std.debug.assert(h.code == T.op_code);
            return @alignCast(@fieldParentPtr("header", h));
        }
    };
}

pub const NoOp = extern struct {
    pub const op_code = OpCode.noop;
};

/// TimeOut operation complete after `sec` seconds and `nsec` nanoseconds has
/// passed. The value of nanoseconds MUST be in the range of [0, 999999999].
///
/// Windows:
/// Time precision is limited to milliseconds. `remaining_sec` and
/// `remaining_nsec` is not used.
///
/// Linux:
/// If timer is interrupted, `remaining_sec` and `remaining_sec` can be used to
/// setup another TimeOut operation and complete the specified pause.
pub const TimeOut = extern struct {
    pub const op_code = OpCode.timeout;

    pub const Error = (error.Cancelled || posix.NanoSleepError);

    sec: usize,
    nsec: usize,

    remaining_sec: usize = 0,
    remaining_nsec: usize = 0,
    err_code: u16 = 0,

    pub fn result(self: *OpenAt) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const OpenAt = extern struct {
    pub const op_code = OpCode.openat;

    pub const Error = fs.File.OpenError;

    pub const Intern = struct {
        dir: fs.Dir,
        path: [:0]const u8,
        opts: Options,
        permissions: u32 = 0o0666,

        fn toExtern(self: Intern) OpenAt {
            return .{
                .dir = self.dir.fd,
                .path = self.path.ptr,
                .opts = self.opts,
                .permissions = self.permissions,
            };
        }
    };

    pub const Options = extern struct {
        read: bool = true,
        write: bool = false,
        append: bool = false,
        truncate: bool = false,
        create_new: bool = false,
        create: bool = true,
    };

    dir: fs.File.Handle,
    path: [*c]const u8,
    opts: Options,
    permissions: u32 = 0o0666,

    file: fs.File.Handle = -1,
    err_code: u16 = 0,

    pub fn result(self: *OpenAt) Error!fs.File {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return .{ .handle = self.file };
    }
};

pub const Close = extern struct {
    pub const op_code = OpCode.close;

    pub const Intern = struct {
        file: fs.File,

        fn toExtern(self: Intern) Close {
            return .{ .file = self.file.handle };
        }
    };

    file: fs.File.Handle,
};

pub const PRead = extern struct {
    pub const op_code = OpCode.pread;

    pub const Error = fs.File.PReadError;

    pub const Intern = struct {
        file: fs.File,
        buffer: []u8,
        offset: u64,

        fn toExtern(self: Intern) PRead {
            return .{
                .file = self.file.handle,
                .buffer = self.buffer.ptr,
                .buffer_len = self.buffer.len,
                .offset = self.offset,
            };
        }
    };

    file: fs.File.Handle,
    buffer: [*c]u8,
    buffer_len: usize,
    offset: u64,

    read: usize = 0,
    err_code: u16 = 0,

    pub fn result(self: *PRead) Error!usize {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.read;
    }
};

pub const PWrite = extern struct {
    pub const op_code = OpCode.pwrite;

    pub const Error = fs.File.PWriteError;

    pub const Intern = struct {
        file: fs.File,
        buffer: []const u8,
        offset: u64,

        fn toExtern(self: Intern) PWrite {
            return .{
                .file = self.file.handle,
                .buffer = self.buffer.ptr,
                .buffer_len = self.buffer.len,
                .offset = self.offset,
            };
        }
    };

    file: fs.File.Handle,
    buffer: [*c]const u8,
    buffer_len: usize,
    offset: u64,

    write: usize = 0,
    err_code: u16 = 0,

    pub fn result(self: *PWrite) Error!usize {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.write;
    }
};

pub const FSync = extern struct {
    pub const op_code = OpCode.fsync;

    pub const Error = fs.File.SyncError;

    pub const Intern = struct {
        file: fs.File,

        pub fn toExtern(self: Intern) FSync {
            return .{ .file = self.file.handle };
        }
    };

    file: fs.File.Handle,

    err_code: u16 = 0,

    pub fn result(self: *FSync) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Stat = extern struct {
    pub const op_code = OpCode.stat;

    pub const Error = fs.File.StatError;

    pub const Intern = struct {
        file: fs.File,

        pub fn toExtern(self: Intern) Stat {
            return .{ .file = self.file.handle };
        }
    };

    file: fs.File.Handle,

    err_code: u16 = 0,
    stat: FileStat = undefined,

    pub fn result(self: *Stat) Error!FileStat {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.stat;
    }
};

pub const FileStat = extern struct {
    const FileKind = enum(c_int) {
        block_device = @intFromEnum(fs.File.Kind.block_device),
        character_device = @intFromEnum(fs.File.Kind.character_device),
        directory = @intFromEnum(fs.File.Kind.directory),
        named_pipe = @intFromEnum(fs.File.Kind.named_pipe),
        sym_link = @intFromEnum(fs.File.Kind.sym_link),
        file = @intFromEnum(fs.File.Kind.file),
        unix_domain_socket = @intFromEnum(fs.File.Kind.unix_domain_socket),
        whiteout = @intFromEnum(fs.File.Kind.whiteout),
        door = @intFromEnum(fs.File.Kind.door),
        event_port = @intFromEnum(fs.File.Kind.event_port),
        unknown = @intFromEnum(fs.File.Kind.unknown),

        comptime {
            std.debug.assert(@typeInfo(@This()).@"enum".fields.len ==
                @typeInfo(fs.File.Kind).@"enum".fields.len);
        }
    };

    /// A number that the system uses to point to the file metadata. This
    /// number is not guaranteed to be unique across time, as some file
    /// systems may reuse an inode after its file has been deleted. Some
    /// systems may change the inode of a file over time.
    ///
    /// On Linux, the inode is a structure that stores the metadata, and
    /// the inode _number_ is what you see here: the index number of the
    /// inode.
    ///
    /// The FileIndex on Windows is similar. It is a number for a file that
    /// is unique to each filesystem.
    inode: fs.File.INode,
    size: u64,
    /// This is available on POSIX systems and is always 0 otherwise.
    mode: fs.File.Mode,
    kind: FileKind,

    /// Last access time in nanoseconds, relative to UTC 1970-01-01.
    atime: i128,
    /// Last modification time in nanoseconds, relative to UTC 1970-01-01.
    mtime: i128,
    /// Last status/metadata change time in nanoseconds, relative to UTC 1970-01-01.
    ctime: i128,

    pub fn fromStdFsFileStat(s: fs.File.Stat) FileStat {
        return .{
            .inode = s.inode,
            .size = s.size,
            .mode = s.mode,
            .kind = @enumFromInt(@as(c_int, @intFromEnum(s.kind))),
            .atime = s.atime,
            .mtime = s.mtime,
            .ctime = s.ctime,
        };
    }
};

pub const GetCwd = extern struct {
    pub const op_code = OpCode.getcwd;

    pub const Error = error{
        CurrentWorkingDirectoryUnlinked,
        NameTooLong,
        Unexpected,
    };

    pub const Intern = struct {
        buffer: []u8,

        pub fn toExtern(self: Intern) GetCwd {
            return .{
                .buffer = self.buffer.ptr,
                .buffer_len = self.buffer.len,
            };
        }
    };

    buffer: [*c]u8,
    buffer_len: usize,

    cwd_len: usize = undefined,
    err_code: u16 = 0,

    pub fn result(self: GetCwd) Error![]u8 {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.buffer[0..self.cwd_len];
    }
};

pub const ChDir = extern struct {
    pub const op_code = OpCode.chdir;

    pub const Error = std.posix.ChangeCurDirError;

    pub const Intern = struct {
        path: [:0]const u8,

        pub fn toExtern(self: Intern) ChDir {
            return .{ .path = self.path.ptr };
        }
    };

    path: [*c]const u8,
    err_code: u16 = 0,

    pub fn result(self: ChDir) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const UnlinkAt = extern struct {
    pub const op_code = OpCode.unlinkat;

    pub const Error = (fs.Dir.DeleteFileError || fs.Dir.DeleteDirError);

    pub const Intern = struct {
        dir: fs.Dir,
        path: [:0]const u8,
        remove_dir: bool,

        pub fn toExtern(self: Intern) UnlinkAt {
            return .{
                .dir = self.dir.fd,
                .path = self.path.ptr,
                .remove_dir = self.remove_dir,
            };
        }
    };

    dir: fs.Dir.Handle,
    path: [*c]const u8,
    remove_dir: bool,

    err_code: u16 = 0,

    pub fn result(self: *UnlinkAt) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Socket = extern struct {
    pub const op_code = OpCode.socket;

    pub const Error = std.posix.SocketError;

    pub const Domain = enum(u32) {
        Inet = std.posix.AF.INET,
        Inet6 = std.posix.AF.INET6,
    };

    pub const Type = enum(u32) {
        Stream = std.posix.SOCK.STREAM,
        Datagram = std.posix.SOCK.DGRAM,
        Raw = std.posix.SOCK.RAW,
    };

    pub const Protocol = enum(u32) {
        Ip = std.posix.IPPROTO.IP,
        IpV6 = std.posix.IPPROTO.IPV6,
        Tcp = std.posix.IPPROTO.TCP,
        Udp = std.posix.IPPROTO.UDP,
        Icmp = std.posix.IPPROTO.ICMP,
        IcmpV6 = std.posix.IPPROTO.ICMPV6,
    };

    domain: Domain,
    socket_type: Type,
    protocol: Protocol,

    socket: std.posix.socket_t = undefined,
    err_code: u16 = 0,

    pub fn result(self: *Socket) Error!std.posix.socket_t {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.socket;
    }
};

pub const Bind = extern struct {
    pub const op_code = OpCode.bind;

    pub const Error = std.posix.BindError;

    socket: std.posix.socket_t,
    address: *std.posix.sockaddr,
    address_len: std.posix.socklen_t,

    err_code: u16 = 0,

    pub fn result(self: *Bind) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Listen = extern struct {
    pub const op_code = OpCode.listen;

    pub const Error = std.posix.ListenError;

    socket: std.posix.socket_t,
    backlog: u32,

    err_code: u16 = 0,

    pub fn result(self: *Listen) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Accept = extern struct {
    pub const op_code = OpCode.accept;

    pub const Error = std.posix.AcceptError;

    socket: std.posix.socket_t,
    address: ?*std.posix.sockaddr,
    address_len: ?*std.posix.socklen_t,
    flags: u32,

    accepted_socket: std.posix.socket_t = undefined,
    err_code: u16 = 0,

    pub fn result(self: *Accept) Error!std.posix.socket_t {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.accepted_socket;
    }
};

pub const Connect = extern struct {
    pub const op_code = OpCode.connect;

    pub const Error = std.posix.ConnectError;

    socket: std.posix.socket_t,
    address: *std.posix.sockaddr,
    address_len: std.posix.socklen_t,

    err_code: u16 = 0,

    pub fn result(self: *Connect) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Shutdown = extern struct {
    pub const op_code = OpCode.shutdown;

    pub const Error = std.posix.ShutdownError;

    pub const How = enum(u32) {
        recv,
        send,
        both,
    };

    socket: std.posix.socket_t,
    how: How,

    err_code: u16 = 0,

    pub fn result(self: *Shutdown) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const CloseSocket = extern struct {
    pub const op_code = OpCode.closesocket;

    socket: std.posix.socket_t,
};

pub const Recv = extern struct {
    pub const op_code = OpCode.recv;

    pub const Error = std.posix.RecvFromError;

    pub const Intern = struct {
        socket: std.posix.socket_t,
        buffer: []u8,
        flags: u32,

        pub fn toExtern(self: Intern) Recv {
            return .{
                .socket = self.socket,
                .buffer = self.buffer.ptr,
                .buffer_len = self.buffer.len,
                .flags = self.flags,
            };
        }
    };

    socket: std.posix.socket_t,
    buffer: [*c]u8,
    buffer_len: usize,
    flags: u32,

    recv: usize = undefined,
    err_code: u16 = 0,

    pub fn result(self: *Recv) Error!usize {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.recv;
    }
};

pub const Send = extern struct {
    pub const op_code = OpCode.send;

    pub const Error = std.posix.SendError;

    pub const Intern = struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
        flags: u32,

        pub fn toExtern(self: Intern) Send {
            return .{
                .socket = self.socket,
                .buffer = self.buffer.ptr,
                .buffer_len = self.buffer.len,
                .flags = self.flags,
            };
        }
    };

    socket: std.posix.socket_t,
    buffer: [*c]const u8,
    buffer_len: usize,
    flags: u32,

    send: usize = undefined,
    err_code: u16 = 0,

    pub fn result(self: *Send) Error!usize {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.send;
    }
};

pub const Spawn = extern struct {
    pub const op_code = OpCode.spawn;

    pub const Error = std.process.Child.SpawnError;

    pub const StdIo = enum(c_int) {
        /// Inherit the stream from the parent process.
        inherit,
        /// Pass a null stream to the child process. This is /dev/null on POSIX
        /// and NUL on Windows.
        ignore,
        /// Create a pipe for the stream. The corresponding field (stdout,
        /// stderr, or stdin) will be assigned a File object that can be used to
        /// read from or write to the pipe.
        pipe,
        /// Close the stream after the child process spawns.
        close,
    };

    pub const Intern = struct {
        args: [*:null]const ?[*:0]const u8,
        env_vars: [*:null]const ?[*:0]const u8,
        stdin: StdIo,
        stdout: StdIo,
        stderr: StdIo,

        pub fn toExtern(self: Intern) Spawn {
            return .{
                .args = self.args,
                .env_vars = self.env_vars,
                .stdio = .{ self.stdin, self.stdout, self.stderr },
            };
        }
    };

    args: [*c]const [*c]const u8,
    env_vars: [*c]const [*c]const u8,
    stdio: [3]StdIo,

    pid: std.posix.pid_t = undefined,
    stdin: std.posix.pid_t = undefined,
    stdout: std.posix.pid_t = undefined,
    stderr: std.posix.pid_t = undefined,
    err_code: u16 = 0,

    pub fn result(self: *Spawn) Error!std.posix.pid_t {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.pid;
    }
};

pub const WaitPid = extern struct {
    pub const op_code = OpCode.waitpid;

    pub const Error = error{
        // Process does not have any unwaited-for children.
        NoChild,
        SignalInterrupt,
        InvalidSyscallParameters,
    };

    pid: std.posix.pid_t,

    status: u32 = 0,
    err_code: u16 = 0,

    pub fn result(self: *WaitPid) Error!u32 {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.status;
    }
};

pub fn opInitOf(Io: type, T: type) OpConstructor(Io, T) {
    return struct {
        pub fn func(
            data: if (@hasDecl(T, "Intern")) T.Intern else T,
            user_data: ?*anyopaque,
            callback: *const fn (*Io, *Op(Io, T)) callconv(.c) void,
        ) Op(Io, T) {
            return .{
                .header = .{
                    .code = T.op_code,
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*anyopaque, *OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                },
                .data = if (@hasDecl(T, "Intern")) data.toExtern() else data,
                .private = Io.OpPrivateData(T).init(.{}),
            };
        }
    }.func;
}

pub fn OpConstructor(Io: type, T: type) type {
    if (@hasDecl(T, "Intern")) {
        return *const fn (
            T.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Io, *Op(Io, T)) callconv(.c) void,
        ) Op(Io, T);
    } else {
        return *const fn (
            T,
            user_data: ?*anyopaque,
            callback: *const fn (*Io, *Op(Io, T)) callconv(.c) void,
        ) Op(Io, T);
    }
}

pub const QueueError = error{SubmissionQueueFull};

pub const SubmitError = error{
    // The kernel was unable to allocate memory or ran out of resources for the
    // request.
    // The application should wait for some completions and try again:
    SystemResources,
    // The application attempted to overcommit the number of requests it can
    // have pending.
    // The application should wait for some completions and try again:
    CompletionQueueOvercommitted,
    // The submitted operation is malformed/invalid.
    InvalidOp,
    // The Operating System returned an undocumented error code.
    // This error is in theory not possible, but it would be better to handle
    // this error than to invoke undefined behavior.
    // When this error code is observed, it usually means the libzev needs a
    // small patch to add the error code to the error set for the respective
    // function.
    Unexpected,
};

/// Io.poll() mode.
pub const PollMode = enum(c_int) {
    /// Poll events until all I/O operations complete.
    all = 0,
    /// Poll events until at most one I/O operations complete.
    one = 1,
    /// Poll events I/O operation if any without blocking.
    nowait = 2,
};
