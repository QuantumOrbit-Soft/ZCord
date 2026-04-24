//! User model.

const std = @import("std");

pub const User = struct {
    id: Snowflake,
    username: []const u8,
    discriminator: []const u8,
    global_name: ?[]const u8,
    avatar: ?[]const u8,
    bot: bool = false,
    system: bool = false,
    mfa_enabled: bool = false,
    banner: ?[]const u8 = null,
    accent_color: ?u32 = null,
    locale: ?[]const u8 = null,
    verified: bool = false,
    email: ?[]const u8 = null,
    flags: u32 = 0,
    premium_type: u8 = 0,
    public_flags: u32 = 0,

    pub fn deinit(self: *User) void {
        _ = self;
    }
};

pub const Snowflake = u64;

pub const PartialUser = struct {
    id: Snowflake,
    username: []const u8,
    discriminator: []const u8,
    avatar: ?[]const u8 = null,
};
