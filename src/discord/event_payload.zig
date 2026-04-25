const std = @import("std");
const GatewayClient = @import("gateway_client.zig").GatewayClient;
const models = @import("../models/mod.zig");

pub const Event = enum {
    OnReady,
    OnEvent,
    OnMessage,
    OnReaction,
    OnChannel,
    OnVoice,
    OnSlashCommand,
    OnComponent,
    OnModalSubmit,
};

pub const EventPayload = union(Event) {
    OnReady: GatewayClient.ReadyEvent,
    OnEvent: GatewayClient.GatewayEvent,
    OnMessage: GatewayClient.MessageCreateEvent,
    OnReaction: GatewayClient.MessageReactionEvent,
    OnChannel: GatewayClient.ChannelEvent,
    OnVoice: GatewayClient.VoiceEvent,
    OnSlashCommand: GatewayClient.SlashCommandEvent,
    OnComponent: GatewayClient.ComponentEvent,
    OnModalSubmit: GatewayClient.ModalSubmitEvent,
};

const CloneError = std.mem.Allocator.Error;

pub fn clone(
    allocator: std.mem.Allocator,
    payload: EventPayload,
) !EventPayload {
    return switch (payload) {
        .OnReady => |event| .{ .OnReady = try clone_ready_event(allocator, event) },
        .OnEvent => |event| .{ .OnEvent = try clone_gateway_event(allocator, event) },
        .OnMessage => |event| .{ .OnMessage = try clone_message_event(allocator, event) },
        .OnReaction => |event| .{ .OnReaction = try clone_reaction_event(allocator, event) },
        .OnChannel => |event| .{ .OnChannel = try clone_channel_event(allocator, event) },
        .OnVoice => |event| .{ .OnVoice = try clone_voice_event(allocator, event) },
        .OnSlashCommand => |event| .{
            .OnSlashCommand = try clone_slash_command_event(allocator, event),
        },
        .OnComponent => |event| .{ .OnComponent = try clone_component_event(allocator, event) },
        .OnModalSubmit => |event| .{
            .OnModalSubmit = try clone_modal_submit_event(allocator, event),
        },
    };
}

fn clone_ready_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.ReadyEvent,
) !GatewayClient.ReadyEvent {
    const guilds = try allocator.alloc(GatewayClient.UnavailableGuild, event.guilds.len);
    for (event.guilds, 0..) |guild, index| {
        guilds[index] = .{
            .id = try clone_bytes(allocator, guild.id),
            .unavailable = guild.unavailable,
        };
    }

    return .{
        .v = event.v,
        .user = try clone_user(allocator, event.user),
        .guilds = guilds,
        .session_id = try clone_bytes(allocator, event.session_id),
        .resume_gateway_url = try clone_bytes(allocator, event.resume_gateway_url),
    };
}

fn clone_gateway_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.GatewayEvent,
) !GatewayClient.GatewayEvent {
    return .{
        .name = try clone_bytes(allocator, event.name),
        .sequence = event.sequence,
        .data = try clone_json_value(allocator, event.data),
    };
}

fn clone_message_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.MessageCreateEvent,
) !GatewayClient.MessageCreateEvent {
    return .{
        .id = try clone_bytes(allocator, event.id),
        .channel_id = try clone_bytes(allocator, event.channel_id),
        .guild_id = try clone_optional_bytes(allocator, event.guild_id),
        .content = try clone_bytes(allocator, event.content),
        .author = if (event.author) |user| try clone_user(allocator, user) else null,
    };
}

fn clone_reaction_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.MessageReactionEvent,
) !GatewayClient.MessageReactionEvent {
    return .{
        .action = event.action,
        .user_id = try clone_bytes(allocator, event.user_id),
        .channel_id = try clone_bytes(allocator, event.channel_id),
        .message_id = try clone_bytes(allocator, event.message_id),
        .guild_id = try clone_optional_bytes(allocator, event.guild_id),
        .emoji = try clone_partial_emoji(allocator, event.emoji),
        .burst = event.burst,
        .type = event.type,
    };
}

fn clone_channel_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.ChannelEvent,
) !GatewayClient.ChannelEvent {
    return .{
        .action = event.action,
        .channel = if (event.channel) |channel| try clone_channel(allocator, channel) else null,
        .pins_update = if (event.pins_update) |pins| try clone_channel_pins_update(
            allocator,
            pins,
        ) else null,
    };
}

fn clone_voice_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.VoiceEvent,
) !GatewayClient.VoiceEvent {
    return .{
        .action = event.action,
        .state = if (event.state) |state| try clone_voice_state(allocator, state) else null,
        .server = if (event.server) |server| try clone_voice_server(allocator, server) else null,
    };
}

fn clone_slash_command_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.SlashCommandEvent,
) !GatewayClient.SlashCommandEvent {
    return .{
        .id = try clone_bytes(allocator, event.id),
        .application_id = try clone_optional_bytes(allocator, event.application_id),
        .channel_id = try clone_optional_bytes(allocator, event.channel_id),
        .guild_id = try clone_optional_bytes(allocator, event.guild_id),
        .token = try clone_bytes(allocator, event.token),
        .command_id = try clone_optional_bytes(allocator, event.command_id),
        .name = try clone_bytes(allocator, event.name),
        .data = if (event.data) |data| try clone_json_value(allocator, data) else null,
    };
}

fn clone_component_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.ComponentEvent,
) !GatewayClient.ComponentEvent {
    return .{
        .id = try clone_bytes(allocator, event.id),
        .application_id = try clone_optional_bytes(allocator, event.application_id),
        .channel_id = try clone_optional_bytes(allocator, event.channel_id),
        .guild_id = try clone_optional_bytes(allocator, event.guild_id),
        .token = try clone_bytes(allocator, event.token),
        .custom_id = try clone_bytes(allocator, event.custom_id),
        .data = if (event.data) |data| try clone_json_value(allocator, data) else null,
    };
}

fn clone_modal_submit_event(
    allocator: std.mem.Allocator,
    event: GatewayClient.ModalSubmitEvent,
) !GatewayClient.ModalSubmitEvent {
    return .{
        .id = try clone_bytes(allocator, event.id),
        .application_id = try clone_optional_bytes(allocator, event.application_id),
        .channel_id = try clone_optional_bytes(allocator, event.channel_id),
        .guild_id = try clone_optional_bytes(allocator, event.guild_id),
        .token = try clone_bytes(allocator, event.token),
        .custom_id = try clone_bytes(allocator, event.custom_id),
        .data = if (event.data) |data| try clone_json_value(allocator, data) else null,
    };
}

fn clone_user(allocator: std.mem.Allocator, user: models.User) !models.User {
    return .{
        .id = try clone_bytes(allocator, user.id),
        .username = try clone_bytes(allocator, user.username),
        .global_name = try clone_optional_bytes(allocator, user.global_name),
        .discriminator = try clone_bytes(allocator, user.discriminator),
        .avatar = try clone_optional_bytes(allocator, user.avatar),
        .bot = user.bot,
        .system = user.system,
        .mfa_enabled = user.mfa_enabled,
        .banner = try clone_optional_bytes(allocator, user.banner),
        .accent_color = user.accent_color,
        .locale = try clone_optional_bytes(allocator, user.locale),
        .verified = user.verified,
        .email = try clone_optional_bytes(allocator, user.email),
        .flags = user.flags,
        .premium_type = user.premium_type,
        .public_flags = user.public_flags,
    };
}

fn clone_channel(allocator: std.mem.Allocator, channel: models.Channel) !models.Channel {
    return .{
        .id = try clone_bytes(allocator, channel.id),
        .type = channel.type,
        .guild_id = try clone_optional_bytes(allocator, channel.guild_id),
        .name = try clone_optional_bytes(allocator, channel.name),
        .topic = try clone_optional_bytes(allocator, channel.topic),
    };
}

fn clone_channel_pins_update(
    allocator: std.mem.Allocator,
    pins: GatewayClient.ChannelPinsUpdateEvent,
) !GatewayClient.ChannelPinsUpdateEvent {
    return .{
        .guild_id = try clone_optional_bytes(allocator, pins.guild_id),
        .channel_id = try clone_bytes(allocator, pins.channel_id),
        .last_pin_timestamp = try clone_optional_bytes(
            allocator,
            pins.last_pin_timestamp,
        ),
    };
}

fn clone_voice_state(
    allocator: std.mem.Allocator,
    state: GatewayClient.VoiceStateEvent,
) !GatewayClient.VoiceStateEvent {
    return .{
        .guild_id = try clone_optional_bytes(allocator, state.guild_id),
        .channel_id = try clone_optional_bytes(allocator, state.channel_id),
        .user_id = try clone_bytes(allocator, state.user_id),
        .session_id = try clone_bytes(allocator, state.session_id),
        .deaf = state.deaf,
        .mute = state.mute,
        .self_deaf = state.self_deaf,
        .self_mute = state.self_mute,
        .self_stream = state.self_stream,
        .self_video = state.self_video,
        .suppress = state.suppress,
        .request_to_speak_timestamp = try clone_optional_bytes(
            allocator,
            state.request_to_speak_timestamp,
        ),
    };
}

fn clone_voice_server(
    allocator: std.mem.Allocator,
    server: GatewayClient.VoiceServerUpdateEvent,
) !GatewayClient.VoiceServerUpdateEvent {
    return .{
        .token = try clone_bytes(allocator, server.token),
        .guild_id = try clone_bytes(allocator, server.guild_id),
        .endpoint = try clone_optional_bytes(allocator, server.endpoint),
    };
}

fn clone_partial_emoji(
    allocator: std.mem.Allocator,
    emoji: GatewayClient.PartialEmoji,
) !GatewayClient.PartialEmoji {
    return .{
        .id = try clone_optional_bytes(allocator, emoji.id),
        .name = try clone_optional_bytes(allocator, emoji.name),
        .animated = emoji.animated,
    };
}

fn clone_json_value(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) CloneError!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try clone_bytes(allocator, inner) },
        .string => |inner| .{ .string = try clone_bytes(allocator, inner) },
        .array => |inner| try clone_json_array(allocator, inner),
        .object => |inner| try clone_json_object(allocator, inner),
    };
}

fn clone_json_array(
    allocator: std.mem.Allocator,
    source: std.json.Array,
) CloneError!std.json.Value {
    var target = std.json.Array.init(allocator);
    try target.ensureTotalCapacity(source.items.len);

    for (source.items) |item| {
        target.appendAssumeCapacity(try clone_json_value(allocator, item));
    }

    return .{ .array = target };
}

fn clone_json_object(
    allocator: std.mem.Allocator,
    source: std.json.ObjectMap,
) CloneError!std.json.Value {
    var target: std.json.ObjectMap = .{};
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const key = try clone_bytes(allocator, entry.key_ptr.*);
        const value = try clone_json_value(allocator, entry.value_ptr.*);
        try target.put(allocator, key, value);
    }

    return .{ .object = target };
}

fn clone_optional_bytes(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const source = value orelse return null;
    return try clone_bytes(allocator, source);
}

fn clone_bytes(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try allocator.dupe(u8, value);
}

test "EventPayload.clone owns slash command JSON after source parser deinit" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": "command-1",
        \\  "name": "zcord",
        \\  "options": [
        \\    { "type": 3, "name": "text", "value": "owned payload" }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const cloned = try clone(arena.allocator(), .{
        .OnSlashCommand = .{
            .id = "interaction-1",
            .token = "interaction-token",
            .name = "zcord",
            .data = parsed.value,
        },
    });
    parsed.deinit();

    const event = switch (cloned) {
        .OnSlashCommand => |value| value,
        else => unreachable,
    };
    const data = event.data orelse return error.MissingClonedData;
    const object = switch (data) {
        .object => |value| value,
        else => return error.InvalidClonedData,
    };

    try std.testing.expect(object.get("options") != null);
}
