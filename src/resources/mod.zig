pub const UsersResource = @import("users.zig").UsersResource;
pub const ChannelsResource = @import("channels.zig").ChannelsResource;
pub const MessagesResource = @import("messages.zig").MessagesResource;
pub const SlashCommandsResource = @import("slash_commands.zig").SlashCommandsResource;

test {
    _ = @import("users.zig");
    _ = @import("channels.zig");
    _ = @import("messages.zig");
    _ = @import("slash_commands.zig");
}
