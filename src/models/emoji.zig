const Snowflake = @import("snowflake.zig").Snowflake;

pub const Emoji = struct {
    id: ?Snowflake = null,
    name: ?[]const u8 = null,
    animated: ?bool = null,
};

test "Emoji supports unicode-only payloads" {
    const emoji = Emoji{ .name = "\u{1F4DD}" };
    try @import("std").testing.expectEqualStrings(
        "\u{1F4DD}",
        emoji.name orelse unreachable,
    );
}
