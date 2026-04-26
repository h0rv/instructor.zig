const std = @import("std");
const create_mod = @import("create.zig");
const options_mod = @import("options.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn Session(comptime Provider: type) type {
    return struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        provider: *Provider,
        usage: types.Usage = .{},
        last_usage: types.Usage = .{},
        last_text: ?[]const u8 = null,
        last_raw_response: ?[]const u8 = null,
        hooks: types.Hooks = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, provider: *Provider) Self {
            return .{
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .provider = provider,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        pub fn reset(self: *Self) void {
            self.arena.deinit();
            self.arena = std.heap.ArenaAllocator.init(self.allocator);
            self.usage = .{};
            self.last_usage = .{};
            self.last_text = null;
            self.last_raw_response = null;
        }

        pub fn setHooks(self: *Self, hooks: types.Hooks) void {
            self.hooks = hooks;
        }

        pub fn create(
            self: *Self,
            comptime T: type,
            request: anytype,
            comptime options: options_mod.Options,
        ) !T {
            const result = try self.createDetailed(T, request, options);
            return result.value;
        }

        pub fn createDetailed(
            self: *Self,
            comptime T: type,
            request: anytype,
            comptime options: options_mod.Options,
        ) !types.CreateResult(T) {
            const result = try create_mod.createDetailedWithArena(
                T,
                self.allocator,
                self.arena.allocator(),
                self.provider,
                request,
                &self.usage,
                self.hooks,
                options,
            );
            self.last_usage = result.usage;
            self.last_text = result.text;
            self.last_raw_response = result.raw_response;
            return result;
        }
    };
}

pub fn session(allocator: std.mem.Allocator, provider: anytype) Session(util.DeclType(@TypeOf(provider))) {
    return Session(util.DeclType(@TypeOf(provider))).init(allocator, provider);
}
