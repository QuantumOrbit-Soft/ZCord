pub const Snowflake = []const u8;

test "Snowflake is represented as borrowed bytes" {
    const id: Snowflake = "123";
    try @import("std").testing.expectEqualStrings("123", id);
}
