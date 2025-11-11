//! Implementation independent data structures and helpers function related to
//! I/O.

const std = @import("std");
const fs = std.fs;

const posix = @import("./posix.zig");

/// OpCode enumerates all supported I/O operation.
pub const OpCode = enum {
    noop,
    timeout,
    openat,
    close,
    pread,
    pwrite,
    fsync,
    fstat,
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
            .fstat => FStat,
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

/// OpHeader defines static fields of Op(Io, T).
pub const OpHeader = struct {
    code: OpCode,

    callback: *const fn (io: *anyopaque, op_h: *@This()) void,
    user_data: ?*anyopaque,
};

/// Op defines an I/O operation. It is made of a static header and Io / T
/// dependent fields.
pub fn Op(Io: type, T: type) type {
    return struct {
        const Impl = Io;

        header: OpHeader,

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

/// NoOp is a no-operation I/O operation. Do not perform any I/O. This is useful
/// for testing the performance of the Io implementation itself.
pub const NoOp = struct {
    pub const op_code = OpCode.noop;
};

/// TimeOut operation complete after `msec` milliseconds passed.
///
/// Windows:
/// `remaining_msec` is not used.
///
/// Linux:
/// If timer is interrupted, `remaining_msec` can be used to setup another
/// TimeOut operation and complete the specified pause.
pub const TimeOut = struct {
    pub const op_code = OpCode.timeout;

    pub const Error = error{
        BadAddress,
        SignalInterrupt,
        InvalidSyscallParameters,
        Unexpected,
    };

    msec: usize,

    // Remaining time if I/O operation was interrupted by a signal.
    remaining_msec: usize = 0,
    result: Error!void = undefined,
};

/// OpenAt operation opens the file specified by `path`. If the file does not
/// exist, it may optionally (if options.create or options.create_new is true)
/// be created.
pub const OpenAt = struct {
    pub const op_code = OpCode.openat;

    pub const Error = error{
        AccessDenied,
        DeviceBusy,
        DiskQuota,
        FileBusy,
        FileLocksNotSupported,
        FileNotFound,
        FileTooBig,
        InvalidSyscallParameters,
        InvalidDirFd,
        InvalidUtf8,
        IsDir,
        NameTooLong,
        NoDevice,
        NoSpaceLeft,
        NotDir,
        ParamsOutsideAccessibleAddressSpace,
        PathAlreadyExists,
        PermissionDenied,
        ProcessFdQuotaExceeded,
        ReadOnlyFileSystem,
        SignalInterrupt,
        SymLinkLoop,
        SystemFdQuotaExceeded,
        SystemResources,
        Unexpected,
        WouldBlock,
    };

    pub const Options = packed struct {
        read: bool = false,
        write: bool = false,
        append: bool = false,
        truncate: bool = false,
        create: bool = false,
        create_new: bool = false,
    };

    dir: fs.Dir,
    path: []const u8,
    options: Options,
    mode: u9,

    result: Error!fs.File = undefined,
};

/// Close operation closes a file, so that it no longer refers to any file and
/// may be reused. This operation never fails.
pub const Close = struct {
    pub const op_code = OpCode.close;

    pub const Error = error{
        BadFd,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
        SignalInterrupt,

        Unexpected,
    };

    file: fs.File,
    result: Error!void = undefined,
};

/// PRead operation reads up to buffer.len bytes from file at offset `offset`.
/// The file offset is not changed.
///
/// If offset is -1 the offset will use (and advance) the
/// file position like the read and write system call. This is needed to support
/// non seekable file such as stdin.
pub const PRead = struct {
    pub const op_code = OpCode.pread;

    pub const Error = error{
        BadFd,
        InputOutput,
        InvalidOffset,
        InvalidSyscallParameters,
        IsDir,
        Overflow,
        ParamsOutsideAccessibleAddressSpace,
        SignalInterrupt,
        Unseekable,
        WouldBlock,

        Unexpected,
    };

    file: fs.File,
    buffer: []u8,
    offset: isize,

    result: Error!usize = undefined,
};

/// PWrite operation writes up to buffer.len bytes to file at offset `offset`.
/// The file offset is not changed.
///
/// If offset is -1 the offset will use (and advance) the
/// file position like the read and write system call. This is needed to support
/// non seekable file such as stdout and stderr.
pub const PWrite = struct {
    pub const op_code = OpCode.pwrite;

    pub const Error = error{
        BadFd,
        BrokenPipe,
        DiskQuota,
        FileTooBig,
        InputOutput,
        InvalidOffset,
        InvalidSyscallParameters,
        NoSpaceLeft,
        Overflow,
        ParamsOutsideAccessibleAddressSpace,
        PermissionDenied,
        SignalInterrupt,
        Unseekable,
        WouldBlock,

        Unexpected,
    };

    file: fs.File,
    buffer: []const u8,
    offset: isize,

    result: Error!usize = undefined,
};

/// Synchronize file's in-core state with storage so that all information can be
/// retrieved even if the system crashed or is rebooted.
pub const FSync = struct {
    pub const op_code = OpCode.fsync;

    pub const Error = error{
        BadFd,
        DiskQuota,
        InputOutput,
        InvalidSyscallParameters,
        NoSpaceLeft,
        ReadOnlyFileSystem,
        SignalInterrupt,

        Unexpected,
    };

    file: fs.File,

    result: Error!void = undefined,
};

/// Retrieve information about a file.
pub const FStat = struct {
    pub const op_code = OpCode.fstat;

    pub const Error = error{
        AccessDenied,
        BadFd,
        BadAddress,
        SymLinkLoop,
        NameTooLong,
        OutOfMemory,
        NotDir,
        Overflow,

        Unexpected,
    };
    pub const Stat = std.fs.File.Stat;

    file: fs.File,

    result: Error!std.fs.File.Stat = undefined,
};

pub const GetCwd = struct {
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

pub const ChDir = struct {
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

pub const UnlinkAt = struct {
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

pub const Socket = struct {
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

pub const Bind = struct {
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

pub const Listen = struct {
    pub const op_code = OpCode.listen;

    pub const Error = std.posix.ListenError;

    socket: std.posix.socket_t,
    backlog: u32,

    err_code: u16 = 0,

    pub fn result(self: *Listen) Error!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Accept = struct {
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

pub const Connect = struct {
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

pub const Shutdown = struct {
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

pub const CloseSocket = struct {
    pub const op_code = OpCode.closesocket;

    socket: std.posix.socket_t,
};

pub const Recv = struct {
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

pub const Send = struct {
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

pub const Spawn = struct {
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

pub const WaitPid = struct {
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
            comptime callback: *const fn (*Io, *Op(Io, T)) void,
        ) Op(Io, T) {
            return .{
                .header = .{
                    .code = T.op_code,
                    .user_data = user_data,
                    .callback = struct {
                        fn cb(io: *anyopaque, op_h: *OpHeader) void {
                            const op: *Op(Io, T) = @alignCast(
                                @fieldParentPtr("header", op_h),
                            );
                            @call(.auto, callback, .{
                                @as(*Io, @ptrCast(@alignCast(io))),
                                op,
                            });
                        }
                    }.cb,
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
            comptime callback: *const fn (*Io, *Op(Io, T)) void,
        ) Op(Io, T);
    } else {
        return *const fn (
            T,
            user_data: ?*anyopaque,
            comptime callback: *const fn (*Io, *Op(Io, T)) void,
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
