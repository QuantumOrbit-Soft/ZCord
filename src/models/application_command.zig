const Snowflake = @import("snowflake.zig").Snowflake;

pub const ApplicationCommand = struct {
    id: Snowflake,
    application_id: Snowflake,
    name: []const u8,
    description: []const u8 = "",
    type: u8 = 1,
};

test "ApplicationCommand defaults to chat input command type" {
    const command = ApplicationCommand{
        .id = "command-1",
        .application_id = "app-1",
        .name = "zcord",
    };

    try @import("std").testing.expectEqual(@as(u8, 1), command.type);
}
