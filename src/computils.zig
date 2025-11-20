//! This file contains comptime utils function.

const std = @import("std");

/// Checks that type *From can be casted to *To. Only structs are supported for
/// now.
/// A type can be safely casted if all fields of From exists in To and have the
/// same offset.
pub fn canPtrCast(From: type, To: type) void {
    const from = @typeInfo(From).@"struct";
    const to = @typeInfo(To).@"struct";

    for (from.fields) |f| {
        var found = false;
        for (to.fields) |t| {
            if (std.mem.eql(u8, f.name, t.name)) {
                if (@offsetOf(From, f.name) != @offsetOf(To, t.name)) {
                    @compileError(f.name ++ " field have differents offset");
                }
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("field " ++ f.name ++ " missing in struct To");
        }
    }
}

/// Returns T.*.
pub fn Deref(T: type) type {
    return @typeInfo(T).pointer.child;
}
