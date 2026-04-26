pub const OpenAI = @import("openai.zig").Client;
pub const testing = @import("testing.zig");

test {
    _ = @import("openai.zig");
    _ = @import("testing.zig");
}
