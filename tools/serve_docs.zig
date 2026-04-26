const std = @import("std");

const net = std.Io.net;
const Dir = std.Io.Dir;
const max_file_size = 256 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();

    const root = args.next() orelse "zig-out/docs";
    const port_text = args.next() orelse "8000";
    const port = try std.fmt.parseInt(u16, port_text, 10);

    var address = net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("serving {s} at http://127.0.0.1:{}/\n", .{ root, port });
    std.debug.print("press Ctrl-C to stop\n", .{});

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.debug.print("accept error: {t}\n", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(gpa, io, root, stream) catch |err| {
            std.debug.print("request error: {t}\n", .{err});
        };
    }
}

fn handleConnection(gpa: std.mem.Allocator, io: std.Io, root: []const u8, stream: net.Stream) !void {
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader_state = stream.reader(io, &read_buffer);
    var writer_state = stream.writer(io, &write_buffer);
    const reader = &reader_state.interface;
    const writer = &writer_state.interface;

    const request_line_raw = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
    const request_line = trimCr(request_line_raw);

    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (trimCr(line).len == 0) break;
    }

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return respondText(writer, 400, "Bad Request", "bad request\n");
    const target = parts.next() orelse return respondText(writer, 400, "Bad Request", "bad request\n");

    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        return respondText(writer, 405, "Method Not Allowed", "method not allowed\n");
    }

    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const raw_path = target[0..question];
    const rel_path = try safePath(gpa, raw_path);
    defer gpa.free(rel_path);

    const full_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel_path });
    defer gpa.free(full_path);

    const body = Dir.cwd().readFileAlloc(io, full_path, gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return respondText(writer, 404, "Not Found", "not found\n"),
        error.IsDir => return respondText(writer, 404, "Not Found", "not found\n"),
        error.AccessDenied => return respondText(writer, 403, "Forbidden", "forbidden\n"),
        error.StreamTooLong => return respondText(writer, 413, "Payload Too Large", "file too large\n"),
        else => return respondText(writer, 500, "Internal Server Error", "internal server error\n"),
    };
    defer gpa.free(body);

    try writer.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: {}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ body.len, contentType(rel_path) },
    );
    if (!std.mem.eql(u8, method, "HEAD")) try writer.writeAll(body);
    try writer.flush();
}

fn respondText(writer: *std.Io.Writer, status: u16, phrase: []const u8, body: []const u8) !void {
    try writer.print(
        "HTTP/1.1 {} {s}\r\n" ++
            "Content-Length: {}\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, phrase, body.len, body },
    );
    try writer.flush();
}

fn safePath(gpa: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    if (raw_path.len == 0 or raw_path[0] != '/') return error.BadPath;
    if (std.mem.indexOfScalar(u8, raw_path, '\\') != null) return error.BadPath;

    const path = if (std.mem.eql(u8, raw_path, "/")) "/index.html" else raw_path;
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    var writer = &out.writer;

    var it = std.mem.splitScalar(u8, path[1..], '/');
    var first = true;
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.BadPath;
        if (!first) try writer.writeByte('/');
        try percentDecodeSegment(writer, segment);
        first = false;
    }

    const result = try out.toOwnedSlice();
    return if (result.len == 0) blk: {
        gpa.free(result);
        break :blk try gpa.dupe(u8, "index.html");
    } else result;
}

fn percentDecodeSegment(writer: *std.Io.Writer, segment: []const u8) !void {
    var i: usize = 0;
    while (i < segment.len) {
        if (segment[i] == '%') {
            if (i + 2 >= segment.len) return error.BadPath;
            const byte = try std.fmt.parseInt(u8, segment[i + 1 .. i + 3], 16);
            if (byte == '/' or byte == '\\' or byte == 0) return error.BadPath;
            try writer.writeByte(byte);
            i += 3;
        } else {
            try writer.writeByte(segment[i]);
            i += 1;
        }
    }
}

fn trimCr(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r")) return line[0 .. line.len - 1];
    return line;
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".tar")) return "application/x-tar";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    return "application/octet-stream";
}
