const std = @import("std");
const instructor = @import("instructor");

const Product = struct {
    name: []const u8,
    price: f64,
    in_stock: bool,
};

pub fn main(init: std.process.Init) !void {
    var ai = try instructor.Client.fromEnv(init, .{
        .provider = .anthropic,
        .model = "claude-haiku-4-5",
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
