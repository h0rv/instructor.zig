const core = @import("core/mod.zig");
const providers = @import("providers/mod.zig");
const client = @import("client.zig");

pub const http = @import("transport.zig");
pub const Client = client.Client;
pub const ClientConfig = client.Config;
pub const EnvConfig = client.EnvConfig;
pub const Provider = client.Provider;
pub const Backend = client.Backend;
pub const Request = client.Request;
pub const Message = client.Message;
pub const Role = client.Role;
pub const Response = client.Response;
pub const Owned = client.Owned;
pub const ExtractionOptions = client.ExtractionOptions;

pub const Mode = core.Mode;
pub const Usage = core.Usage;
pub const StructuredSchema = core.StructuredSchema;
pub const RetryMessage = core.RetryMessage;
pub const Completion = core.Completion;
pub const Diagnostic = core.Diagnostic;
pub const HookEvent = core.HookEvent;
pub const HookInfo = core.HookInfo;
pub const Hooks = core.Hooks;
pub const CreateResult = core.CreateResult;

pub const Options = core.Options;
pub const FieldNaming = core.FieldNaming;
pub const RootWrapper = core.RootWrapper;
pub const ObjectRootWrapper = core.ObjectRootWrapper;
pub const Error = core.Error;
pub const Session = core.Session;
pub const createWithArena = core.createWithArena;
pub const createDetailedWithArena = core.createDetailedWithArena;
pub const schemaAlloc = core.schemaAlloc;
pub const diagnostic = core.diagnostic;
pub const printError = core.printError;
pub const writeError = core.writeError;
pub const openai_schema_options = core.openai_schema_options;
pub const session = core.session;

pub const OpenAI = providers.OpenAI;
pub const Anthropic = providers.Anthropic;
pub const anthropic_schema_options = providers.anthropic_schema_options;
pub const testing_provider = providers.testing;
pub const provider = providers;

test {
    _ = core;
    _ = providers;
    _ = client;
    _ = http;
}
