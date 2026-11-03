const std = @import("std");

/// All request data is borrowed for the duration of send only.
pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
};

/// The body is owned. A sender must allocate it with the supplied allocator.
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// The context is borrowed. Its owner controls its lifetime and cleanup.
/// Custom implementations must honor response limits and must not follow redirects.
pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send_fn: *const fn (?*anyopaque, std.Io, std.mem.Allocator, Request) anyerror!Response,

    /// Borrow an existing standard-library client without owning its cleanup.
    /// Its address and initialization-time I/O must stay valid while in use.
    pub fn fromStd(client: *std.http.Client) Transport {
        return .{ .ctx = client, .send_fn = StdHttp.send };
    }

    pub fn send(self: Transport, io: std.Io, allocator: std.mem.Allocator, request: Request) !Response {
        var response = try self.send_fn(self.ctx, io, allocator, request);
        if (response.body.len > request.max_response_bytes) {
            response.deinit();
            return error.ResponseTooLarge;
        }
        return response;
    }
};

/// Owns a stable client allocation, so moving this handle never invalidates
/// pooled connections or previously borrowed transports. Deinitialize once,
/// after all sends finish; borrowed transports must not outlive this owner.
/// The allocator must be thread-safe and `io` must outlive the owner.
pub const StdHttp = struct {
    client: *std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !StdHttp {
        const client = try allocator.create(std.http.Client);
        client.* = .{ .allocator = allocator, .io = io };
        return .{ .client = client };
    }

    pub fn deinit(self: *StdHttp) void {
        const allocator = self.client.allocator;
        self.client.deinit();
        allocator.destroy(self.client);
        self.* = undefined;
    }

    pub fn transport(self: *StdHttp) Transport {
        return Transport.fromStd(self.client);
    }

    // A default client always uses its initialization-time I/O implementation.
    // Never mutate client.io per call: existing connections retain the client.
    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: Request) !Response {
        const client: *std.http.Client = @ptrCast(@alignCast(ctx.?));
        if (request.body != null and !request.method.requestHasBody())
            return error.InvalidRequestBody;
        var req = try client.request(request.method, try std.Uri.parse(request.url), .{
            .redirect_behavior = .unhandled,
            .extra_headers = request.headers,
        });
        defer req.deinit();
        // In particular, do not let Request.deinit drain an unbounded response
        // after an allocation failure before the body reader is initialized.
        errdefer if (req.connection) |connection| {
            connection.closing = true;
        };

        if (request.method.requestHasBody()) {
            const payload = request.body orelse "";
            req.transfer_encoding = .{ .content_length = payload.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(payload);
            try body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        if (!request.method.responseHasBody() or status.class() == .informational or
            status == .no_content or status == .not_modified)
        {
            // Avoid treating representation Content-Length as a body length.
            req.connection.?.closing = true;
            return .{ .allocator = allocator, .status = status, .body = try allocator.alloc(u8, 0) };
        }

        const decompress_buffer = try allocator.alloc(u8, switch (response.head.content_encoding) {
            .identity => 0,
            .gzip, .deflate => std.compress.flate.max_window_len,
            .zstd => std.compress.zstd.default_window_len,
            .compress => return error.UnsupportedCompressionMethod,
        });
        defer allocator.free(decompress_buffer);
        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        const body = reader.allocRemaining(allocator, .limited(request.max_response_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => return err,
        };
        return .{ .allocator = allocator, .status = status, .body = body };
    }
};

const BorrowedFake = struct {
    calls: usize = 0,
    cleaned: bool = false,

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: Request) !Response {
        const self: *BorrowedFake = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return .{ .allocator = allocator, .status = .ok, .body = try allocator.dupe(u8, request.body orelse "fake") };
    }

    fn deinit(self: *BorrowedFake) void {
        self.cleaned = true;
    }
};

test "borrowed transport forwards request and never cleans up context" {
    var fake: BorrowedFake = .{};
    const transport: Transport = .{ .ctx = &fake, .send_fn = BorrowedFake.send };
    var response = try transport.send(std.testing.io, std.testing.allocator, .{
        .method = .POST,
        .url = "unused",
        .body = "borrowed body",
    });
    try std.testing.expectEqualStrings("borrowed body", response.body);
    response.deinit();
    try std.testing.expectEqual(1, fake.calls);
    try std.testing.expect(!fake.cleaned);
    fake.deinit();
    try std.testing.expect(fake.cleaned);
}

test "oversized injected response is rejected and freed" {
    var fake: BorrowedFake = .{};
    const transport: Transport = .{ .ctx = &fake, .send_fn = BorrowedFake.send };
    try std.testing.expectError(error.ResponseTooLarge, transport.send(std.testing.io, std.testing.allocator, .{
        .method = .GET,
        .url = "unused",
        .max_response_bytes = 3,
    }));
    try std.testing.expect(!fake.cleaned);
}

fn wrapperAllocationFailures(allocator: std.mem.Allocator) !void {
    var fake: BorrowedFake = .{};
    const transport: Transport = .{ .ctx = &fake, .send_fn = BorrowedFake.send };
    var response = try transport.send(std.testing.io, allocator, .{ .method = .GET, .url = "unused" });
    response.deinit();
    var oversized = transport.send(std.testing.io, allocator, .{
        .method = .GET,
        .url = "unused",
        .max_response_bytes = 0,
    }) catch |err| switch (err) {
        error.ResponseTooLarge => return,
        else => return err,
    };
    oversized.deinit();
    return error.ExpectedResponseTooLarge;
}

test "wrapper allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, wrapperAllocationFailures, .{});
}

fn ownerAllocationFailures(allocator: std.mem.Allocator) !void {
    var http = try StdHttp.init(allocator, std.testing.io);
    defer http.deinit();
}

test "default client allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownerAllocationFailures, .{});
}

// A single local connection with scripted wire responses, never an external API.
const Loopback = struct {
    listener: std.Io.net.Server,
    responses: []const []const u8,
    method: std.http.Method = .GET,
    body: []const u8 = "",
    authorization: ?[]const u8 = null,

    fn init(responses: []const []const u8) !Loopback {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .listener = try address.listen(std.testing.io, .{}), .responses = responses };
    }

    fn deinit(self: *Loopback) void {
        self.listener.deinit(std.testing.io);
    }

    fn url(self: *Loopback, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/test", .{self.listener.socket.address.getPort()});
    }

    fn serve(self: *Loopback) !void {
        const io = std.testing.io;
        const stream = try self.listener.accept(io);
        defer stream.close(io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var input = stream.reader(io, &read_buffer);
        var output = stream.writer(io, &write_buffer);
        for (self.responses) |wire_response| {
            var line_buffer: [128]u8 = undefined;
            const expected_line = try std.fmt.bufPrint(&line_buffer, "{s} /test HTTP/1.1\r", .{@tagName(self.method)});
            try std.testing.expectEqualStrings(expected_line, (try input.interface.takeDelimiter('\n')) orelse return error.EndOfStream);
            var content_length: usize = 0;
            var found_auth = false;
            while (true) {
                const line = (try input.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
                if (std.mem.eql(u8, line, "\r")) break;
                const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidHeader;
                const name = line[0..colon];
                const value = std.mem.trim(u8, line[colon + 1 ..], " \r");
                if (std.ascii.eqlIgnoreCase(name, "content-length"))
                    content_length = try std.fmt.parseInt(usize, value, 10);
                if (std.ascii.eqlIgnoreCase(name, "authorization")) {
                    try std.testing.expectEqualStrings(self.authorization orelse return error.UnexpectedAuthorization, value);
                    found_auth = true;
                }
            }
            try std.testing.expectEqual(self.authorization != null, found_auth);
            try std.testing.expectEqual(self.body.len, content_length);
            try std.testing.expectEqualStrings(self.body, try input.interface.take(content_length));
            try output.interface.writeAll(wire_response);
            try output.interface.flush();
        }
    }
};

test "default loopback forwards authorization and body and returns success and error bodies" {
    var server = try Loopback.init(&.{
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 7\r\n\r\ninvalid",
    });
    defer server.deinit();
    server.method = .POST;
    server.body = "{\"x\":1}";
    server.authorization = "Bearer local-test-secret";
    var serving = try std.testing.io.concurrent(Loopback.serve, .{&server});
    defer serving.cancel(std.testing.io) catch {};
    var http = try StdHttp.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var url_buffer: [128]u8 = undefined;
    const request: Request = .{
        .method = .POST,
        .url = try server.url(&url_buffer),
        .headers = &.{.{ .name = "Authorization", .value = "Bearer local-test-secret" }},
        .body = server.body,
    };
    var success = try http.transport().send(std.testing.io, std.testing.allocator, request);
    defer success.deinit();
    try std.testing.expectEqual(.ok, success.status);
    try std.testing.expectEqualStrings("ok", success.body);
    var failure = try http.transport().send(std.testing.io, std.testing.allocator, request);
    defer failure.deinit();
    try std.testing.expectEqual(.bad_request, failure.status);
    try std.testing.expectEqualStrings("invalid", failure.body);
    try serving.await(std.testing.io);
}

fn checkWireResponse(wire: []const u8, limit: usize, expected: ?[]const u8, status: std.http.Status) !void {
    var server = try Loopback.init(&.{wire});
    defer server.deinit();
    var serving = try std.testing.io.concurrent(Loopback.serve, .{&server});
    defer serving.cancel(std.testing.io) catch {};
    var http = try StdHttp.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var url_buffer: [128]u8 = undefined;
    const result = http.transport().send(std.testing.io, std.testing.allocator, .{
        .method = .GET,
        .url = try server.url(&url_buffer),
        .max_response_bytes = limit,
    });
    if (expected) |body| {
        var response = try result;
        defer response.deinit();
        try std.testing.expectEqual(status, response.status);
        try std.testing.expectEqualStrings(body, response.body);
    } else {
        try std.testing.expectError(error.ResponseTooLarge, result);
    }
    try serving.await(std.testing.io);
}

test "default loopback does not follow redirects and preserves redirect body" {
    // Port zero cannot be connected to: following this Location would fail.
    try checkWireResponse("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:0/never\r\nContent-Length: 4\r\n\r\nhere", 4, "here", .found);
}

test "default loopback content-length bodies at and above limit including errors" {
    try checkWireResponse("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n1234", 4, "1234", .ok);
    try checkWireResponse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n12345", 4, null, .ok);
    try checkWireResponse("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\n\r\n12345", 4, null, .internal_server_error);
    try checkWireResponse("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 0, "", .ok);
    try checkWireResponse("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx", 0, null, .ok);
}

test "default loopback chunked and close-delimited bodies are bounded" {
    try checkWireResponse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n12\r\n2\r\n34\r\n0\r\n\r\n", 4, "1234", .ok);
    try checkWireResponse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n12345\r\n0\r\n\r\n", 4, null, .ok);
    try checkWireResponse("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n1234", 4, "1234", .ok);
    try checkWireResponse("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n12345", 4, null, .ok);
}

test "default loopback bounds decompressed gzip bodies including errors" {
    // A 40-byte gzip stream that expands to 4096 'a' bytes.
    const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x13\xed\xc1\x01\x0d\x00\x00\x00\xc2\xa0\xac\xef\x5f\xc2\x1e\x0e\x28\x00\x00\x00\xe0\xdd\x00\x73\xdc\x99\x9c\x00\x10\x00\x00";
    const wire = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 40\r\n\r\n" ++ gzip;
    const expanded: [4096]u8 = @splat('a');
    try checkWireResponse(wire, expanded.len, &expanded, .ok);
    try checkWireResponse(wire, expanded.len - 1, null, .ok);
    try checkWireResponse(wire, gzip.len, null, .ok);
    try checkWireResponse("HTTP/1.1 500 Internal Server Error\r\nContent-Encoding: gzip\r\nContent-Length: 40\r\n\r\n" ++ gzip, expanded.len - 1, null, .internal_server_error);
}

test "default loopback bodyless statuses ignore representation length" {
    try checkWireResponse("HTTP/1.1 204 No Content\r\nContent-Length: 999\r\n\r\n", 0, "", .no_content);
    try checkWireResponse("HTTP/1.1 304 Not Modified\r\nContent-Length: 999\r\n\r\n", 0, "", .not_modified);
}

test "moving default owner before and after requests preserves borrowed transport and pool" {
    var server = try Loopback.init(&.{
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    });
    defer server.deinit();
    var serving = try std.testing.io.concurrent(Loopback.serve, .{&server});
    defer serving.cancel(std.testing.io) catch {};
    var original = try StdHttp.init(std.testing.allocator, std.testing.io);
    const transport = original.transport();
    var moved = original;
    original = undefined;
    var owner = &moved;
    defer owner.deinit();
    var url_buffer: [128]u8 = undefined;
    const request: Request = .{ .method = .GET, .url = try server.url(&url_buffer) };
    // The callback's io cannot replace the client's initialization-time io.
    var first = try transport.send(std.Io.failing, std.testing.allocator, request);
    defer first.deinit();
    // Keep the connection open between requests, exercising Connection.client.
    try std.testing.expectEqual(1, moved.client.connection_pool.free_len);
    var moved_again = moved;
    moved = undefined;
    owner = &moved_again;
    try std.testing.expectEqual(transport.ctx, moved_again.transport().ctx);
    var second = try transport.send(std.testing.io, std.testing.allocator, request);
    defer second.deinit();
    try std.testing.expectEqualStrings("ok", second.body);
    try serving.await(std.testing.io);
}
