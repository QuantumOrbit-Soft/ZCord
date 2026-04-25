const types = @import("types.zig");

id: []const u8,
channel_id: []const u8,
guild_id: ?[]const u8 = null,
content: []const u8 = "",
embeds: []const types.Embed = &.{},
components: []const types.ActionRow = &.{},
reactions: []const types.MessageReaction = &.{},

pub const Message = @This();
