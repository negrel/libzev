//! Implementation independent data structures and helpers function related to
//! I/O.

const std = @import("std");
const fs = std.fs;

const posix = @import("./posix.zig");

/// OpCode enumerates all supported I/O operation.
pub const OpCode = enum {
    noop,
    sleep,
    openat,
    close,
    pread,
    pwrite,
    fsync,
    fstat,
    getcwd,
    chdir,
    unlinkat,
    spawn,
    waitpid,

    pub fn Data(self: @This()) type {
        return switch (self) {
            .noop => NoOp,
            .sleep => Sleep,
            .openat => OpenAt,
            .close => Close,
            .pread => PRead,
            .pwrite => PWrite,
            .fsync => FSync,
            .fstat => FStat,
            .getcwd => GetCwd,
            .chdir => ChDir,
            .unlinkat => UnlinkAt,
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
        pub const Data = T;

        header: OpHeader,

        // Implementation specific fields.
        private: Impl.OpPrivateData(T),

        // Operation data.
        data: Data,

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

/// Sleep operation complete after specified milliseconds elapsed. Time is
/// relative to Io.poll().
pub const Sleep = struct {
    pub const op_code = OpCode.sleep;

    pub const Error = error{
        BadAddress,
        Canceled,
        InvalidSyscallParameters,
        Unexpected,
    };

    msec: usize,

    result: Error!void = undefined,
};

/// OpenAt operation opens the file specified by `path`. If the file does not
/// exist, it may optionally (if options.create or options.create_new is true)
/// be created.
pub const OpenAt = struct {
    pub const op_code = OpCode.openat;

    pub const Error = error{
        AccessDenied,
        BadAddress,
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
        BadAddress,
        CurrentWorkingDirectoryUnlinked,
        InvalidBuffer,
        NameTooLong,
        PermissionDenied,
        SystemResources,
        Unexpected,
    };

    buffer: []u8,
    result: Error![]u8 = undefined,
};

pub const ChDir = struct {
    pub const op_code = OpCode.chdir;

    pub const Error = error{
        AccessDenied,
        BadAddress,
        FileNotFound,
        FileSystem,
        InvalidUtf8,
        NameTooLong,
        NotDir,
        SymLinkLoop,
        SystemResources,
        Unexpected,
    };

    path: []const u8,
    result: Error!void = undefined,
};

pub const UnlinkAt = struct {
    pub const op_code = OpCode.unlinkat;

    pub const Error = error{
        AccessDenied,
        BadAddress,
        DirNotEmpty,
        FileBusy,
        FileNotFound,
        FileSystem,
        InvalidDirFd,
        InvalidUtf8,
        IsDir,
        NameTooLong,
        NotDir,
        PermissionDenied,
        ReadOnlyFileSystem,
        SymLinkLoop,
        SystemResources,
        Unexpected,
    };

    dir: fs.Dir,
    path: []const u8,
    remove_dir: bool,

    result: Error!void = undefined,
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

    pub const Result = struct {
        pid: std.process.Child.Id,
        stdin: std.fs.File,
        stdout: std.fs.File,
        stderr: std.fs.File,
    };

    args: [*:null]const ?[*:0]const u8,
    env_vars: [*:null]const ?[*:0]const u8,
    stdin: StdIo,
    stdout: StdIo,
    stderr: StdIo,

    result: Error!Result = undefined,
};

pub const WaitPid = struct {
    pub const op_code = OpCode.waitpid;

    pub const Error = error{
        NoChild,
        Unexpected,
    };

    pid: std.process.Child.Id,

    result: Error!u32 = undefined,
};

pub fn opInitOf(Io: type, T: type) OpConstructor(Io, T) {
    return struct {
        pub fn func(
            data: T,
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
                .data = data,
                .private = Io.OpPrivateData(T).init(.{}),
            };
        }
    }.func;
}

pub fn OpConstructor(Io: type, T: type) type {
    return *const fn (
        T,
        user_data: ?*anyopaque,
        comptime callback: *const fn (*Io, *Io.Op(T)) void,
    ) Io.Op(T);
}

pub const QueueError = error{
    /// Queue is full.
    SubmissionQueueFull,
};

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
