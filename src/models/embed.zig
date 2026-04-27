const std = @import("std");

pub const EmbedFooter = struct {
    text: []const u8,
    icon_url: ?[]const u8 = null,
};

pub const EmbedImage = struct {
    url: []const u8,
};

pub const EmbedThumbnail = struct {
    url: []const u8,
};

pub const EmbedAuthor = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    icon_url: ?[]const u8 = null,
};

pub const EmbedField = struct {
    name: []const u8,
    value: []const u8,
    @"inline": bool = false,
};

pub const Embed = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    color: ?u32 = null,
    footer: ?EmbedFooter = null,
    image: ?EmbedImage = null,
    thumbnail: ?EmbedThumbnail = null,
    author: ?EmbedAuthor = null,
    fields: []const EmbedField = &.{},
};

test "Embed serializes nested fields" {
    const allocator = std.testing.allocator;
    const fields = [_]EmbedField{.{
        .name = "Resource",
        .value = "messages.create",
        .@"inline" = true,
    }};
    const value = Embed{
        .title = "ZCord",
        .description = "Embed sample",
        .color = 0x5865F2,
        .footer = .{ .text = "footer" },
        .fields = fields[0..],
    };

    const body = try std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"fields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"inline\"") != null);
}
