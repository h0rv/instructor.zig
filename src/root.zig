const core = @import("core/mod.zig");
const providers = @import("providers/mod.zig");

pub const Mode = core.Mode;
pub const Usage = core.Usage;
pub const StructuredSchema = core.StructuredSchema;
pub const RetryMessage = core.RetryMessage;
pub const Completion = core.Completion;
pub const Diagnostic = core.Diagnostic;

pub const Options = core.Options;
pub const Error = core.Error;
pub const Session = core.Session;
pub const createWithArena = core.createWithArena;
pub const diagnostic = core.diagnostic;
pub const printError = core.printError;
pub const writeError = core.writeError;
pub const openai_schema_options = core.openai_schema_options;
pub const session = core.session;

pub const OpenAI = providers.OpenAI;
pub const testing_provider = providers.testing;
pub const provider = providers;

test {
    _ = core;
    _ = providers;
}
