const std = @import("std");
const jsonschema = @import("jsonschema");
const types = @import("types.zig");

pub const FieldNaming = jsonschema.FieldNaming;
pub const RootWrapper = jsonschema.RootWrapper;
pub const ObjectRootWrapper = jsonschema.ObjectRootWrapper;

pub const openai_schema_options = jsonschema.strict_options;

pub const Options = struct {
    mode: types.Mode = .json_schema,
    max_retries: u8 = 3,
    schema_options: jsonschema.Options = openai_schema_options,
    parse_options: std.json.ParseOptions = .{ .allocate = .alloc_always },
};
