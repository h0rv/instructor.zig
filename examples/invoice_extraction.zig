const std = @import("std");
const instructor = @import("instructor");

comptime {
    @setEvalBranchQuota(10_000);
}

const Currency = enum { usd, eur, gbp, other };

const LineItem = struct {
    description: []const u8,
    quantity: u32,
    total_cents: u32,
};

const Invoice = struct {
    vendor: []const u8,
    invoice_number: []const u8,
    currency: Currency,
    total_cents: u32,
    line_items: []const LineItem,

    pub const jsonschema = .{
        .name = "Invoice",
        .description = "Extract normalized invoice fields. Return money as integer cents.",
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const api_key = init.environ_map.get("OPENROUTER_API_KEY") orelse return error.MissingApiKey;

    var client = instructor.OpenAI.init(.{
        .allocator = gpa,
        .io = init.io,
        .api_key = api_key,
        .base_url = "https://openrouter.ai/api/v1",
        .endpoint = .chat_completions,
        .http_referer = "https://github.com/h0rv/instructor.zig",
        .app_name = "instructor.zig",
    });
    defer client.deinit();

    var session = instructor.session(gpa, &client);
    defer session.deinit();

    const raw_invoice =
        \\ACME Cloud Services
        \\Invoice INV-2026-0042
        \\Issued 2026-04-15, due 2026-05-15
        \\2 x Zig hosting seats @ $120.00 = $240.00
        \\1 x Priority support @ $80.00 = $80.00
        \\Subtotal $320.00, tax $28.80, total $348.80 USD
    ;

    const invoice = session.create(Invoice, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Extract this invoice. Return cents as integers.\n\n" ++ raw_invoice }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("{s} #{s} total={} {s}\n", .{ invoice.vendor, invoice.invoice_number, invoice.total_cents, @tagName(invoice.currency) });
    for (invoice.line_items) |item| {
        std.debug.print("{}x {s}: {} cents\n", .{ item.quantity, item.description, item.total_cents });
    }
}
