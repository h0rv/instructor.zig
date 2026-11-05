# Extract an invoice

Convert invoice text into a record with nested line items. Request integer cents so your application does not need floating-point arithmetic for money.

## Extract nested fields

Pass the OpenRouter session from the [shared setup](../cookbook.md#shared-setup). This uses the lower-level `Session` API, not `Client.responses`.

```zig
const std = @import("std");
const instructor = @import("instructor");
comptime { @setEvalBranchQuota(10_000); }

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

fn extractInvoice(session: *instructor.Session(instructor.OpenAI)) !void {
    const text =
        \\ACME Cloud Services, invoice INV-2026-0042
        \\2 x hosting seats @ $120.00 = $240.00
        \\1 x support @ $80.00 = $80.00
        \\Subtotal $320.00, tax $28.80, total $348.80 USD
    ;
    const invoice = try session.create(Invoice, instructor.OpenAI.Request{
        .model = "anthropic/claude-haiku-5.5",
        .messages = &.{.{ .role = .user, .content = "Extract this invoice in cents.\n" ++ text }},
    }, .{});
    std.debug.print("{s} #{s}: {} {s}\n", .{
        invoice.vendor, invoice.invoice_number, invoice.total_cents, @tagName(invoice.currency),
    });
    for (invoice.line_items) |item| {
        std.debug.print("{}x {s}: {} cents\n", .{ item.quantity, item.description, item.total_cents });
    }
}
```

## Check amounts before use

`total_cents` is the invoice total. Each line item's `total_cents` is its line total, not its unit price. Tax in the input means the line totals need not sum to the invoice total. The schema checks field types, not accounting consistency. Check amounts against the source before using them for payment.

The result is an `Invoice` value, not an owned wrapper. Its strings and line items belong to the session arena. Read or copy them before resetting or deinitializing the session.

[Full source](../../examples/invoice_extraction.zig)
