const embed = @import("embed.zig");
const component = @import("component.zig");
const message_reaction = @import("message_reaction.zig");

id: []const u8,
channel_id: []const u8,
guild_id: ?[]const u8 = null,
content: []const u8 = "",
embeds: []const embed.Embed = &.{},
components: []const component.ActionRow = &.{},
reactions: []const message_reaction.MessageReaction = &.{},

pub const Message = @This();
