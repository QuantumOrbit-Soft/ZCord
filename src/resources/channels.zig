const std = @import("std");
const zrqwest = @import("zrqwest");
const DiscordHttpClient = @import("../discord/http_client.zig").DiscordHttpClient;
const DiscordResult = @import("../discord/result.zig").DiscordResult;
const models = @import("../models/mod.zig");
const Routes = @import("../routes/mod.zig").Routes;

allocator: std.mem.Allocator,
client: *DiscordHttpClient,

pub const ChannelsResource = @This();

pub const Channel = models.Channel;
pub const get_channel_result = DiscordResult.Of(Channel);

const Self = @This();
const route_path_bytes_max: usize = 128;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    client: *DiscordHttpClient,
) void {
    self.* = .{ .allocator = allocator, .client = client };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn get(self: *Self, channel_id: []const u8) !get_channel_result {
    const response = try self.get_response(channel_id);
    return self.get_result_from_response(response);
}

fn get_response(self: *Self, channel_id: []const u8) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Self.channel_get_path(path_buffer[0..], channel_id);
    return self.client.get(path);
}

fn channel_get_path(path_buffer: []u8, channel_id: []const u8) ![]const u8 {
    return Routes.channels.get(path_buffer, channel_id);
}

fn get_result_from_response(self: *Self, response: zrqwest.Response) !get_channel_result {
    return get_channel_result.from_zrqwest_response(self.allocator, response);
}

test "ChannelsResource exposes get API" {
    comptime {
        try std.testing.expect(@hasDecl(ChannelsResource, "get"));
        try std.testing.expect(@hasDecl(ChannelsResource, "Channel"));
        try std.testing.expect(@hasDecl(ChannelsResource, "get_channel_result"));
    }
}

test "ChannelsResource route comes from centralized Routes module" {
    var path_buffer: [64]u8 = undefined;
    const path = try Routes.channels.get(path_buffer[0..], "123");
    try std.testing.expectEqualStrings("/channels/123", path);
}

test "ChannelsResource keeps route assembly in private helper" {
    try std.testing.expect(@hasDecl(ChannelsResource, "channel_get_path"));
    try std.testing.expect(@hasDecl(ChannelsResource, "get_response"));
}

test "ChannelsResource parses channel payload with single response owner" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "{\"id\":\"123\",\"name\":\"general\"}");

    var fake_client: DiscordHttpClient = undefined;
    var channels: ChannelsResource = undefined;
    channels.init(allocator, &fake_client);

    var result = try channels.get_result_from_response(.{
        .allocator = allocator,
        .status = .ok,
        .body = body,
    });
    defer result.deinit();

    const channel = result.data() orelse unreachable;
    try std.testing.expectEqualStrings("123", channel.id);
    try std.testing.expectEqualStrings("general", channel.name orelse unreachable);
}
