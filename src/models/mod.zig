//! Data models representing Discord entities.
//! Type-safe structures for all Discord objects.

pub const User = @import("user.zig").User;
pub const PartialUser = @import("user.zig").PartialUser;
pub const Snowflake = @import("user.zig").Snowflake;
pub const Guild = struct {
    id: Snowflake = 0,
    name: []const u8 = "",
};
pub const Channel = struct {
    id: Snowflake = 0,
    name: []const u8 = "",
};
pub const Message = struct {
    id: Snowflake = 0,
    content: []const u8 = "",
};
