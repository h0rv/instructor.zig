const std = @import("std");
const instructor = @import("instructor");

const Product = struct {
    name: []const u8,
    price: f64,
    in_stock: bool,
};

// This demonstration performs no network I/O. A real adapter can use any client.
fn send(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: instructor.http.Request) !instructor.http.Response {
    const body =
        \\{"output_text":"{\"name\":\"Coffee mug\",\"price\":12.50,\"in_stock\":true}"}
    ;
    return .{
        .allocator = allocator,
        .status = .ok,
        .body = try allocator.dupe(u8, body),
    };
}

pub fn main(init: std.process.Init) !void {
    var ai = try instructor.Client.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .provider = .{ .openai = .{ .api_key = "" } },
        .model = "example-model",
        .transport = .{ .send_fn = send },
    });
    defer ai.deinit();

    var product = try ai.responses.parse(Product, .{
        .input = "Extract the product: Coffee mug costs $12.50 and is in stock.",
    });
    defer product.deinit();

    std.debug.print("{s}: {d:.2}, in stock={}\n", .{
        product.value.name,
        product.value.price,
        product.value.in_stock,
    });
}
