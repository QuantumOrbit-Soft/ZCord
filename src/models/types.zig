const std = @import("std");

pub const Snowflake = []const u8;

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

pub const ComponentType = enum(u8) {
    action_row = 1,
    button = 2,
};

pub const ButtonStyle = enum(u8) {
    primary = 1,
    secondary = 2,
    success = 3,
    danger = 4,
    link = 5,
};

pub const Emoji = struct {
    id: ?Snowflake = null,
    name: ?[]const u8 = null,
    animated: ?bool = null,
};

pub const Button = struct {
    type: u8 = @intFromEnum(ComponentType.button),
    style: u8,
    label: ?[]const u8 = null,
    custom_id: ?[]const u8 = null,
    url: ?[]const u8 = null,
    emoji: ?Emoji = null,
    disabled: bool = false,
};

pub const ActionRow = struct {
    type: u8 = @intFromEnum(ComponentType.action_row),
    components: []const Button,
};

pub const MessageReaction = struct {
    count: u32 = 0,
    me: bool = false,
    emoji: Emoji,
};

pub const ApplicationCommand = struct {
    id: Snowflake,
    application_id: Snowflake,
    name: []const u8,
    description: []const u8 = "",
    type: u8 = 1,
};

test "Button serializes unicode emoji object" {
    const allocator = std.testing.allocator;
    const button = Button{
        .style = @intFromEnum(ButtonStyle.primary),
        .label = "Open modal",
        .custom_id = "sample:open",
        .emoji = .{ .name = "\u{1F4DD}" },
    };

    const body = try std.json.Stringify.valueAlloc(allocator, button, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"emoji\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\"") != null);
}
