//! Implementation independent data structures and helpers function related to
//! I/O.

const std = @import("std");

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
};

/// OpHeader defines field at the beginning of Op(Io, T) that don't depend on
/// Io and T. It is always safe to read OpHeader even if Io and T are unknown.
pub const OpHeader = extern struct {
    code: OpCode,
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
        const op_code = T.op_code;

        header: OpHeader = .{ .code = op_code },

        // Implementation specific fields.
        private: Impl.OpPrivateData(T),

        // Operation data.
        data: T,

        pub fn fromHeaderUnsafe(h: *OpHeader) *Op(Io, T) {
            return @alignCast(@fieldParentPtr("header", h));
        }
    };
}

pub const NoOp = extern struct {
    pub const op_code = OpCode.noop;
};

pub const TimeOut = extern struct {
    pub const op_code = OpCode.timeout;

    ms: u64,
};

pub const OpenAt = extern struct {
    pub const op_code = OpCode.openat;

    pub const Intern = struct {
        dir: std.fs.Dir,
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

    dir: std.fs.File.Handle,
    path: [*c]const u8,
    opts: Options,
    permissions: u32 = 0o0666,

    file: std.fs.File.Handle = -1,
    err_code: u16 = 0,

    pub fn result(self: *OpenAt) std.fs.File.OpenError!std.fs.File {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return .{ .handle = self.file };
    }
};

pub const Close = extern struct {
    pub const op_code = OpCode.close;

    pub const Intern = struct {
        file: std.fs.File,

        fn toExtern(self: Intern) Close {
            return .{ .file = self.file.handle };
        }
    };

    file: std.fs.File.Handle,
};

pub const PRead = extern struct {
    pub const op_code = OpCode.pread;

    pub const Intern = struct {
        file: std.fs.File,
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

    file: std.fs.File.Handle,
    buffer: [*c]u8,
    buffer_len: usize,
    offset: u64,

    read: usize = 0,
    err_code: u16 = 0,

    pub fn result(self: *PRead) std.fs.File.PReadError!usize {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.read;
    }
};

pub const PWrite = extern struct {
    pub const op_code = OpCode.pwrite;

    pub const Intern = struct {
        file: std.fs.File,
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

    file: std.fs.File.Handle,
    buffer: [*c]const u8,
    buffer_len: usize,
    offset: u64,

    write: usize = 0,
    err_code: u16 = 0,

    pub fn result(self: *PWrite) std.fs.File.PWriteError!usize {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.write;
    }
};

pub const FSync = extern struct {
    pub const op_code = OpCode.fsync;

    pub const Intern = struct {
        file: std.fs.File,

        pub fn toExtern(self: Intern) FSync {
            return .{ .file = self.file.handle };
        }
    };

    file: std.fs.File.Handle,

    err_code: u16 = 0,

    pub fn result(self: *FSync) std.fs.File.SyncError!void {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
    }
};

pub const Stat = extern struct {
    pub const op_code = OpCode.stat;

    pub const Intern = struct {
        file: std.fs.File,

        pub fn toExtern(self: Intern) Stat {
            return .{ .file = self.file.handle };
        }
    };

    file: std.fs.File.Handle,

    err_code: u16 = 0,
    stat: FileStat = undefined,

    pub fn result(self: *Stat) std.fs.File.StatError!FileStat {
        if (self.err_code != 0) return @errorCast(@errorFromInt(self.err_code));
        return self.stat;
    }
};

pub const FileStat = extern struct {
    const FileKind = enum(c_int) {
        block_device = @intFromEnum(std.fs.File.Kind.block_device),
        character_device = @intFromEnum(std.fs.File.Kind.character_device),
        directory = @intFromEnum(std.fs.File.Kind.directory),
        named_pipe = @intFromEnum(std.fs.File.Kind.named_pipe),
        sym_link = @intFromEnum(std.fs.File.Kind.sym_link),
        file = @intFromEnum(std.fs.File.Kind.file),
        unix_domain_socket = @intFromEnum(std.fs.File.Kind.unix_domain_socket),
        whiteout = @intFromEnum(std.fs.File.Kind.whiteout),
        door = @intFromEnum(std.fs.File.Kind.door),
        event_port = @intFromEnum(std.fs.File.Kind.event_port),
        unknown = @intFromEnum(std.fs.File.Kind.unknown),

        comptime {
            std.debug.assert(@typeInfo(@This()).@"enum".fields.len ==
                @typeInfo(std.fs.File.Kind).@"enum".fields.len);
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
    inode: std.fs.File.INode,
    size: u64,
    /// This is available on POSIX systems and is always 0 otherwise.
    mode: std.fs.File.Mode,
    kind: FileKind,

    /// Last access time in nanoseconds, relative to UTC 1970-01-01.
    atime: i128,
    /// Last modification time in nanoseconds, relative to UTC 1970-01-01.
    mtime: i128,
    /// Last status/metadata change time in nanoseconds, relative to UTC 1970-01-01.
    ctime: i128,

    pub fn fromStdFsFileStat(s: std.fs.File.Stat) FileStat {
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

    pub const Intern = struct {
        buffer: []u8,

        pub fn toExtern(self: Intern) GetCwd {
            return .{
                .buffer = self.buffer.ptr,
                .buffer_len = self.buffer.len,
            };
        }
    };

    pub const Error = error{
        CurrentWorkingDirectoryUnlinked,
        NameTooLong,
        Unexpected,
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

pub fn OpConstructor(Io: type, T: type) type {
    if (@hasDecl(T, "Intern")) {
        return *const fn (
            T.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, T)) callconv(.c) void,
        ) Op(Io, T);
    } else {
        return *const fn (
            T,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, T)) callconv(.c) void,
        ) Op(Io, T);
    }
}

pub fn noOp(Io: type) OpConstructor(Io, NoOp) {
    return struct {
        pub fn func(
            data: NoOp,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, NoOp)) callconv(.c) void,
        ) Op(Io, NoOp) {
            return .{
                .data = data,
                .private = Io.OpPrivateData(NoOp).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn timeOut(Io: type) OpConstructor(Io, TimeOut) {
    return struct {
        pub fn func(
            data: TimeOut,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, TimeOut)) callconv(.c) void,
        ) Op(Io, TimeOut) {
            return .{
                .data = data,
                .private = Io.OpPrivateData(TimeOut).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn openAt(Io: type) OpConstructor(Io, OpenAt) {
    return struct {
        pub fn func(
            data: OpenAt.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, OpenAt)) callconv(.c) void,
        ) Op(Io, OpenAt) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(OpenAt).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn close(Io: type) OpConstructor(Io, Close) {
    return struct {
        pub fn func(
            data: Close.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, Close)) callconv(.c) void,
        ) Op(Io, Close) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(Close).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn pRead(Io: type) OpConstructor(Io, PRead) {
    return struct {
        pub fn func(
            data: PRead.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, PRead)) callconv(.c) void,
        ) Op(Io, PRead) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(PRead).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn pWrite(Io: type) OpConstructor(Io, PWrite) {
    return struct {
        pub fn func(
            data: PWrite.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, PWrite)) callconv(.c) void,
        ) Op(Io, PWrite) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(PWrite).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn fSync(Io: type) OpConstructor(Io, FSync) {
    return struct {
        pub fn func(
            data: FSync.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, FSync)) callconv(.c) void,
        ) Op(Io, FSync) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(FSync).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn stat(Io: type) OpConstructor(Io, Stat) {
    return struct {
        pub fn func(
            data: Stat.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, Stat)) callconv(.c) void,
        ) Op(Io, Stat) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(Stat).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
}

pub fn getCwd(Io: type) OpConstructor(Io, GetCwd) {
    return struct {
        pub fn func(
            data: GetCwd.Intern,
            user_data: ?*anyopaque,
            callback: *const fn (*Op(Io, GetCwd)) callconv(.c) void,
        ) Op(Io, GetCwd) {
            return .{
                .data = data.toExtern(),
                .private = Io.OpPrivateData(GetCwd).init(.{
                    .user_data = user_data,
                    .callback = @as(
                        *const fn (*OpHeader) callconv(.c) void,
                        @ptrCast(callback),
                    ),
                }),
            };
        }
    }.func;
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
