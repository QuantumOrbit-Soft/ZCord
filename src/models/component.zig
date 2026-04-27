const std = @import("std");
const Emoji = @import("emoji.zig").Emoji;

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
