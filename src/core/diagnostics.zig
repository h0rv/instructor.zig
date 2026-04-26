const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

pub const Diagnostic = types.Diagnostic;

pub fn diagnostic(provider: anytype) ?Diagnostic {
    const Provider = util.DeclType(@TypeOf(provider));
    if (comptime @hasDecl(Provider, "diagnostic")) return provider.diagnostic();
    return null;
}

pub fn writeError(writer: *std.Io.Writer, err: anyerror, provider: anytype) !void {
    if (diagnostic(provider)) |diag| {
        try diag.writeError(writer, err);
    } else {
        try writer.print("error: {s}\n", .{@errorName(err)});
    }
}

pub fn printError(err: anyerror, provider: anytype) void {
    var buffer: [2048]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    writeError(&stderr.file_writer.interface, err, provider) catch {};
}

test "writeError includes provider diagnostics" {
    const Provider = struct {
        pub fn diagnostic(_: *@This()) Diagnostic {
            return .{
                .provider = "test",
                .status = .bad_request,
                .body = "bad schema",
            };
        }
    };

    var provider_value: Provider = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeError(&out.writer, error.ProviderHttpError, &provider_value);
    const text = out.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "error: ProviderHttpError") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "provider: test") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "status: 400 Bad Request") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "body: bad schema") != null);
}
