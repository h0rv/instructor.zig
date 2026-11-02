pub const OpenAI = @import("openai.zig").Client;
pub const Anthropic = @import("anthropic.zig").Client;
pub const anthropic_schema_options = @import("anthropic.zig").anthropic_schema_options;
pub const testing = @import("testing.zig");

test {
    _ = @import("openai.zig");
    _ = @import("anthropic.zig");
    _ = @import("testing.zig");
}
