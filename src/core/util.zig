pub fn DeclType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}
