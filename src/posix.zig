//! POSIX API layer.
//!
//! This file contains minimal set of POSIX functions used by libzev. It is
//! similar to Zig's std.posix) but returns all possible errors (including
//! EFAULT and EINTR).
//!
//! Non POSIX-compliant platforms are supported by this API layer if possible or
//! in their specific Io implementation.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const system = posix.system;
const native_os = builtin.os.tag;

const lfs64_abi = native_os == .linux and
    builtin.link_libc and
    (builtin.abi.isGnu() or builtin.abi.isAndroid());

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

pub const OpenError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to open a new resource relative to it.
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    /// Either:
    /// * One of the path components does not exist.
    /// * Cwd was used, but cwd has been deleted.
    /// * The path associated with the open directory handle has been deleted.
    /// * On macOS, multiple processes or threads raced to create the same file
    ///   with `O.EXCL` set to `false`.
    FileNotFound,

    /// Syscall is interrupted by a signal.
    SignalInterrupt,

    InvalidSyscallParameters,

    // Path is relative but dir_fd isn't AT_FDCWD.
    InvalidDirFd,

    /// The path exceeded `max_path_bytes` bytes.
    NameTooLong,

    /// Insufficient kernel memory was available, or
    /// the named file is a FIFO and per-user hard limit on
    /// memory allocation for pipes has been reached.
    SystemResources,

    /// The file is too large to be opened. This error is unreachable
    /// for 64-bit targets, as well as when opening directories.
    FileTooBig,

    /// The path refers to directory but the `DIRECTORY` flag was not provided.
    IsDir,

    /// A new path cannot be created because the device has no room for the new
    /// file. This error is only reachable when the `CREAT` flag is provided.
    NoSpaceLeft,

    /// A component used as a directory in the path was not, in fact, a
    /// directory, or `DIRECTORY` was specified and the path was not a
    /// directory.
    NotDir,

    /// The path already exists and the `CREAT` and `EXCL` flags were provided.
    PathAlreadyExists,
    DeviceBusy,

    /// The underlying filesystem does not support file locks
    FileLocksNotSupported,

    /// Path contains characters that are disallowed by the underlying
    /// filesystem.
    BadPathName,

    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,

    /// This error occurs in Linux if the process to be open was not found.
    ProcessNotFound,

    /// One of these three things:
    /// * pathname  refers to an executable image which is currently being
    ///   executed and write access was requested.
    /// * pathname refers to a file that is currently in  use  as  a  swap
    ///   file, and the O_TRUNC flag was specified.
    /// * pathname  refers  to  a file that is currently being read by the
    ///   kernel (e.g., for module/firmware loading), and write access was
    ///   requested.
    FileBusy,

    WouldBlock,

    Unexpected,
};

/// Open and possibly create a file.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no
/// particular encoding.
pub fn openatZ(dir_fd: fd_t, file_path: [*:0]const u8, flags: O, mode: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        @compileError("WASI does not support POSIX without linking libc");
    }

    const openat_sym = if (lfs64_abi) system.openat64 else system.openat;
    const rc = openat_sym(dir_fd, file_path, flags, mode);
    return switch (errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.SignalInterrupt,
        .FAULT => error.InvalidSyscallParameters,
        .INVAL => error.BadPathName,
        .BADF => error.InvalidDirFd,
        .ACCES => error.AccessDenied,
        .FBIG => error.FileTooBig,
        .OVERFLOW => error.FileTooBig,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .SRCH => error.ProcessNotFound,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .PERM => error.PermissionDenied,
        .EXIST => error.PathAlreadyExists,
        .BUSY => error.DeviceBusy,
        .OPNOTSUPP => error.FileLocksNotSupported,
        .AGAIN => error.WouldBlock,
        .TXTBSY => error.FileBusy,
        .NXIO => error.NoDevice,
        .ILSEQ => |err| if (native_os == .wasi)
            error.InvalidUtf8
        else
            unexpectedErrno(err),
        else => |err| unexpectedErrno(err),
    };
}

// Reexported functions.
pub const unexpectedErrno = posix.unexpectedErrno;
pub const exit = posix.exit;
pub const errno = posix.errno;
pub const O = posix.O;
pub const AT = posix.AT;
pub const mode_t = posix.mode_t;
pub const fd_t = posix.fd_t;
