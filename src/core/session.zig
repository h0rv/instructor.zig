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
        }

        pub fn create(
            self: *Self,
            comptime T: type,
            request: anytype,
            comptime options: options_mod.Options,
        ) !T {
            return create_mod.createWithArena(
                T,
                self.allocator,
                self.arena.allocator(),
                self.provider,
                request,
                &self.usage,
                options,
            );
        }
    };
}

pub fn session(allocator: std.mem.Allocator, provider: anytype) Session(util.DeclType(@TypeOf(provider))) {
    return Session(util.DeclType(@TypeOf(provider))).init(allocator, provider);
}
