const std = @import("std");
const builtin = @import("builtin");
const zrqwest = @import("zrqwest");
const GatewayProtocol = @import("gateway_protocol.zig").GatewayProtocol;
const models = @import("../models/mod.zig");
const assert = std.debug.assert;

pub const default_gateway_url = GatewayProtocol.default_gateway_url;
pub const default_max_message_bytes = GatewayProtocol.default_max_message_bytes;
pub const event_name_bytes_max = GatewayProtocol.event_name_bytes_max;
pub const token_bytes_max = GatewayProtocol.token_bytes_max;
pub const gateway_url_bytes_max = GatewayProtocol.gateway_url_bytes_max;
const empty_headers: []const std.http.Header = &.{};

allocator: std.mem.Allocator,
token: []u8,
parse_storage: []u8 = &.{},
websocket: zrqwest.WebSocketClient = undefined,
websocket_initialized: bool = false,
sequence: ?u64 = null,
heartbeat_interval_ms: u64 = 0,
heartbeat_thread: ?std.Thread = null,
stop_heartbeat: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

pub const GatewayClient = @This();
const Self = @This();
const Opcode = GatewayProtocol.Opcode;
const GatewayPayload = GatewayProtocol.Payload;
const HelloData = GatewayProtocol.HelloData;

pub const init_error = std.mem.Allocator.Error || GatewayProtocol.init_error;

pub const run_options_error = GatewayProtocol.run_options_error;

pub const Intents = GatewayProtocol.Intents;
pub const RunOptions = GatewayProtocol.RunOptions;

pub const UnavailableGuild = struct {
    id: []const u8,
    unavailable: bool = false,
};

pub const ReadyEvent = struct {
    v: u8,
    user: models.User,
    guilds: []UnavailableGuild = &.{},
    session_id: []const u8,
    resume_gateway_url: []const u8,
};

pub const MessageCreateEvent = struct {
    id: []const u8,
    channel_id: []const u8,
    guild_id: ?[]const u8 = null,
    content: []const u8 = "",
    author: ?models.User = null,
};

pub const PartialEmoji = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    animated: ?bool = null,
};

pub const ReactionAction = enum {
    add,
    remove,
};

pub const MessageReactionEvent = struct {
    action: ReactionAction = .add,
    user_id: []const u8,
    channel_id: []const u8,
    message_id: []const u8,
    guild_id: ?[]const u8 = null,
    emoji: PartialEmoji,
    burst: bool = false,
    type: u8 = 0,
};

pub const MessageReactionAddEvent = MessageReactionEvent;

pub const ChannelAction = enum {
    create,
    update,
    delete,
    pins_update,
};

pub const ChannelPinsUpdateEvent = struct {
    guild_id: ?[]const u8 = null,
    channel_id: []const u8,
    last_pin_timestamp: ?[]const u8 = null,
};

pub const ChannelEvent = struct {
    action: ChannelAction,
    channel: ?models.Channel = null,
    pins_update: ?ChannelPinsUpdateEvent = null,

    pub fn channel_id(self: ChannelEvent) ?[]const u8 {
        if (self.channel) |value| return value.id;
        if (self.pins_update) |value| return value.channel_id;
        return null;
    }

    pub fn guild_id(self: ChannelEvent) ?[]const u8 {
        if (self.channel) |value| return value.guild_id;
        if (self.pins_update) |value| return value.guild_id;
        return null;
    }
};

pub const VoiceAction = enum {
    state_update,
    server_update,
};

pub const VoiceStateEvent = struct {
    guild_id: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    user_id: []const u8,
    session_id: []const u8,
    deaf: bool = false,
    mute: bool = false,
    self_deaf: bool = false,
    self_mute: bool = false,
    self_stream: ?bool = null,
    self_video: bool = false,
    suppress: bool = false,
    request_to_speak_timestamp: ?[]const u8 = null,
};

pub const VoiceServerUpdateEvent = struct {
    token: []const u8,
    guild_id: []const u8,
    endpoint: ?[]const u8 = null,
};

pub const VoiceEvent = struct {
    action: VoiceAction,
    state: ?VoiceStateEvent = null,
    server: ?VoiceServerUpdateEvent = null,

    pub fn guild_id(self: VoiceEvent) ?[]const u8 {
        if (self.state) |value| return value.guild_id;
        if (self.server) |value| return value.guild_id;
        return null;
    }
};

pub const SlashCommandEvent = struct {
    id: []const u8,
    application_id: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    guild_id: ?[]const u8 = null,
    token: []const u8,
    command_id: ?[]const u8 = null,
    name: []const u8,
    data: ?std.json.Value = null,
};

pub const ComponentEvent = struct {
    id: []const u8,
    application_id: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    guild_id: ?[]const u8 = null,
    token: []const u8,
    custom_id: []const u8,
    data: ?std.json.Value = null,
};

pub const ModalSubmitEvent = struct {
    id: []const u8,
    application_id: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    guild_id: ?[]const u8 = null,
    token: []const u8,
    custom_id: []const u8,
    data: ?std.json.Value = null,
};

pub const GatewayEvent = struct {
    name: []const u8,
    sequence: ?u64,
    data: std.json.Value,
};

const slash_command_interaction_type: u8 = 2;
const component_interaction_type: u8 = 3;
const modal_submit_interaction_type: u8 = 5;

const InteractionCreateEvent = struct {
    id: []const u8,
    type: u8,
    application_id: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    guild_id: ?[]const u8 = null,
    token: []const u8,
    data: ?std.json.Value = null,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    token: []const u8,
) init_error!void {
    try GatewayProtocol.validate_token(token);
    assert(token.len > 0);

    const owned_token = try allocator.dupe(u8, token);
    errdefer allocator.free(owned_token);

    const parse_storage = try allocator.alloc(u8, default_max_message_bytes);
    assert(parse_storage.len == default_max_message_bytes);

    self.* = .{
        .allocator = allocator,
        .token = owned_token,
        .parse_storage = parse_storage,
    };
}

pub fn deinit(self: *Self) void {
    assert(self.token.len > 0);
    assert(self.parse_storage.len > 0);
    self.disconnect();
    self.allocator.free(self.token);
    self.allocator.free(self.parse_storage);
    self.* = undefined;
}

pub fn run(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    options: RunOptions,
) !void {
    try GatewayProtocol.validate_run_options(options);

    if (self.websocket_initialized) return error.GatewayAlreadyRunning;

    try self.websocket.init(self.allocator);
    self.websocket_initialized = true;
    errdefer self.disconnect();

    try self.websocket.connect(
        .url(options.url),
        .headers(empty_headers),
        .{
            .max_message_bytes = options.max_message_bytes,
            .auto_pong = true,
        },
    );
    defer self.disconnect();

    while (self.websocket.is_connected()) {
        var message = try self.websocket.read();
        defer message.deinit();

        switch (message.kind) {
            .text => try self.dispatch_text(Handler, handler, message.data, options),
            .binary => {},
            .close => break,
        }
    }
}

pub fn disconnect(self: *Self) void {
    self.stop_heartbeat_thread();

    if (self.websocket_initialized) {
        self.websocket.disconnect();
        self.websocket.deinit();
        self.websocket_initialized = false;
    }

    self.sequence = null;
    self.heartbeat_interval_ms = 0;
}

fn dispatch_text(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    text: []const u8,
    options: RunOptions,
) !void {
    try GatewayProtocol.validate_text(text, options);
    assert(text.len <= options.max_message_bytes);
    assert(self.parse_storage.len > 0);
    if (options.max_message_bytes <= self.parse_storage.len) {} else {
        return error.GatewayParseBufferTooSmall;
    }

    var parse_allocator_state = std.heap.FixedBufferAllocator.init(self.parse_storage);
    const parse_allocator = parse_allocator_state.allocator();
    defer {
        assert(parse_allocator_state.end_index <= self.parse_storage.len);
        @memset(self.parse_storage[0..parse_allocator_state.end_index], 0);
    }

    const payload = try std.json.parseFromSliceLeaky(GatewayPayload, parse_allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    });

    try self.dispatch_payload(Handler, handler, parse_allocator, payload, options);
}

fn dispatch_payload(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    payload: GatewayPayload,
    options: RunOptions,
) !void {
    if (payload.s) |sequence| {
        self.sequence = sequence;
    }

    switch (payload.op) {
        @intFromEnum(Opcode.hello) => {
            const data = payload.d orelse return error.MissingGatewayPayload;
            try self.handle_hello(data, options, parse_allocator);
        },
        @intFromEnum(Opcode.heartbeat) => try self.send_heartbeat(),
        @intFromEnum(Opcode.dispatch) => try self.dispatch_event(
            Handler,
            handler,
            parse_allocator,
            payload,
        ),
        @intFromEnum(Opcode.heartbeat_ack) => {},
        @intFromEnum(Opcode.reconnect) => return error.GatewayReconnectRequested,
        @intFromEnum(Opcode.invalid_session) => return error.GatewayInvalidSession,
        @intFromEnum(Opcode.identify) => return error.UnexpectedGatewayOpcode,
        else => return error.UnknownGatewayOpcode,
    }
}

fn handle_hello(
    self: *Self,
    data: std.json.Value,
    options: RunOptions,
    parse_allocator: std.mem.Allocator,
) !void {
    const hello = try std.json.parseFromValueLeaky(HelloData, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    self.heartbeat_interval_ms = hello.heartbeat_interval;
    try self.send_heartbeat();
    try self.send_identify(options.intents);
    try self.start_heartbeat_thread();
}

fn dispatch_event(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    payload: GatewayPayload,
) !void {
    const name = payload.t orelse return;
    try GatewayProtocol.validate_event_name(name);
    const data: std.json.Value = payload.d orelse .null;

    if (comptime @hasDecl(Handler, "on_event")) {
        try Handler.on_event(handler, .{
            .name = name,
            .sequence = payload.s,
            .data = data,
        });
    }

    if (std.mem.eql(u8, name, "READY")) {
        try self.dispatch_ready(Handler, handler, parse_allocator, data);
        return;
    }

    if (std.mem.eql(u8, name, "MESSAGE_CREATE")) {
        try self.dispatch_message(Handler, handler, parse_allocator, data);
        return;
    }

    if (std.mem.eql(u8, name, "MESSAGE_REACTION_ADD")) {
        try self.dispatch_reaction(Handler, handler, parse_allocator, data, .add);
        return;
    }

    if (std.mem.eql(u8, name, "MESSAGE_REACTION_REMOVE")) {
        try self.dispatch_reaction(Handler, handler, parse_allocator, data, .remove);
        return;
    }

    if (try self.dispatch_channel_event(Handler, handler, parse_allocator, name, data)) return;
    if (try self.dispatch_voice_event(Handler, handler, parse_allocator, name, data)) return;

    if (std.mem.eql(u8, name, "INTERACTION_CREATE")) {
        try self.dispatch_interaction(Handler, handler, parse_allocator, data);
        return;
    }
}

fn dispatch_ready(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_ready")) {} else return;

    const event = try std.json.parseFromValueLeaky(ReadyEvent, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    try Handler.on_ready(handler, event);
}

fn dispatch_message(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_message")) {} else return;

    const event = try std.json.parseFromValueLeaky(MessageCreateEvent, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    try Handler.on_message(handler, event);
}

fn dispatch_reaction(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
    action: ReactionAction,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_reaction")) {} else return;

    var event = try std.json.parseFromValueLeaky(MessageReactionEvent, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    event.action = action;
    try Handler.on_reaction(handler, event);
}

fn dispatch_channel_event(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    name: []const u8,
    data: std.json.Value,
) !bool {
    if (std.mem.eql(u8, name, "CHANNEL_CREATE")) {
        try self.dispatch_channel(Handler, handler, parse_allocator, data, .create);
        return true;
    }

    if (std.mem.eql(u8, name, "CHANNEL_UPDATE")) {
        try self.dispatch_channel(Handler, handler, parse_allocator, data, .update);
        return true;
    }

    if (std.mem.eql(u8, name, "CHANNEL_DELETE")) {
        try self.dispatch_channel(Handler, handler, parse_allocator, data, .delete);
        return true;
    }

    if (std.mem.eql(u8, name, "CHANNEL_PINS_UPDATE")) {
        try self.dispatch_channel_pins_update(Handler, handler, parse_allocator, data);
        return true;
    }

    return false;
}

fn dispatch_channel(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
    action: ChannelAction,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_channel")) {} else return;

    const channel = try std.json.parseFromValueLeaky(models.Channel, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    try Handler.on_channel(handler, .{
        .action = action,
        .channel = channel,
    });
}

fn dispatch_channel_pins_update(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_channel")) {} else return;

    const pins = try std.json.parseFromValueLeaky(
        ChannelPinsUpdateEvent,
        parse_allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );

    try Handler.on_channel(handler, .{
        .action = .pins_update,
        .pins_update = pins,
    });
}

fn dispatch_voice_event(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    name: []const u8,
    data: std.json.Value,
) !bool {
    if (std.mem.eql(u8, name, "VOICE_STATE_UPDATE")) {
        try self.dispatch_voice_state(Handler, handler, parse_allocator, data);
        return true;
    }

    if (std.mem.eql(u8, name, "VOICE_SERVER_UPDATE")) {
        try self.dispatch_voice_server(Handler, handler, parse_allocator, data);
        return true;
    }

    return false;
}

fn dispatch_voice_state(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_voice")) {} else return;

    const state = try std.json.parseFromValueLeaky(VoiceStateEvent, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    try Handler.on_voice(handler, .{
        .action = .state_update,
        .state = state,
    });
}

fn dispatch_voice_server(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
) !void {
    _ = self;
    if (comptime @hasDecl(Handler, "on_voice")) {} else return;

    const server = try std.json.parseFromValueLeaky(
        VoiceServerUpdateEvent,
        parse_allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );

    try Handler.on_voice(handler, .{
        .action = .server_update,
        .server = server,
    });
}

fn dispatch_interaction(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    parse_allocator: std.mem.Allocator,
    data: std.json.Value,
) !void {
    _ = self;
    const handles_slash = comptime @hasDecl(Handler, "on_slash_command");
    const handles_component = comptime @hasDecl(Handler, "on_component");
    const handles_modal = comptime @hasDecl(Handler, "on_modal_submit");
    if (comptime handles_slash or handles_component or handles_modal) {} else return;

    const interaction = try std.json.parseFromValueLeaky(InteractionCreateEvent, parse_allocator, data, .{
        .ignore_unknown_fields = true,
    });

    const command_data = interaction.data orelse return;

    if (interaction.type == slash_command_interaction_type) {
        if (comptime handles_slash) {
            try dispatch_slash_command(Handler, handler, interaction, command_data);
        }
        return;
    }

    if (interaction.type == component_interaction_type) {
        if (comptime handles_component) {
            try dispatch_component(Handler, handler, interaction, command_data);
        }
        return;
    }

    if (interaction.type == modal_submit_interaction_type) {
        if (comptime handles_modal) {
            try dispatch_modal_submit(Handler, handler, interaction, command_data);
        }
        return;
    }
}

fn dispatch_slash_command(
    comptime Handler: type,
    handler: *Handler,
    interaction: InteractionCreateEvent,
    command_data: std.json.Value,
) !void {
    const command_name = interaction_data_string(command_data, "name") orelse return;
    if (0 < command_name.len) {} else return error.EmptySlashCommandName;

    try Handler.on_slash_command(handler, .{
        .id = interaction.id,
        .application_id = interaction.application_id,
        .channel_id = interaction.channel_id,
        .guild_id = interaction.guild_id,
        .token = interaction.token,
        .command_id = interaction_data_string(command_data, "id"),
        .name = command_name,
        .data = command_data,
    });
}

fn dispatch_component(
    comptime Handler: type,
    handler: *Handler,
    interaction: InteractionCreateEvent,
    component_data: std.json.Value,
) !void {
    const custom_id = interaction_data_string(component_data, "custom_id") orelse return;
    if (0 < custom_id.len) {} else return error.EmptyComponentCustomId;

    try Handler.on_component(handler, .{
        .id = interaction.id,
        .application_id = interaction.application_id,
        .channel_id = interaction.channel_id,
        .guild_id = interaction.guild_id,
        .token = interaction.token,
        .custom_id = custom_id,
        .data = component_data,
    });
}

fn dispatch_modal_submit(
    comptime Handler: type,
    handler: *Handler,
    interaction: InteractionCreateEvent,
    modal_data: std.json.Value,
) !void {
    const custom_id = interaction_data_string(modal_data, "custom_id") orelse return;
    if (0 < custom_id.len) {} else return error.EmptyModalCustomId;

    try Handler.on_modal_submit(handler, .{
        .id = interaction.id,
        .application_id = interaction.application_id,
        .channel_id = interaction.channel_id,
        .guild_id = interaction.guild_id,
        .token = interaction.token,
        .custom_id = custom_id,
        .data = modal_data,
    });
}

fn interaction_data_string(data: std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (data) {
        .object => |value| value,
        else => return null,
    };
    const node = object.get(key) orelse return null;
    return switch (node) {
        .string => |value| value,
        else => null,
    };
}

fn send_identify(self: *Self, intents: u32) !void {
    assert(self.token.len > 0);

    try self.websocket.send_json(.{
        .op = @intFromEnum(Opcode.identify),
        .d = .{
            .token = self.token,
            .intents = intents,
            .properties = .{
                .os = @tagName(builtin.os.tag),
                .browser = "ZCord",
                .device = "ZCord",
            },
        },
    });
}

fn send_heartbeat(self: *Self) !void {
    if (self.websocket_initialized) {} else return;
    if (self.websocket.is_connected()) {} else return;

    try self.websocket.send_json(.{
        .op = @intFromEnum(Opcode.heartbeat),
        .d = self.sequence,
    });
}

fn start_heartbeat_thread(self: *Self) !void {
    if (self.heartbeat_thread) |_| return;
    if (0 < self.heartbeat_interval_ms) {} else return error.InvalidHeartbeatInterval;

    self.stop_heartbeat.store(false, .release);
    self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeat_loop, .{self});
}

fn stop_heartbeat_thread(self: *Self) void {
    self.stop_heartbeat.store(true, .release);
    if (self.heartbeat_thread) |thread| {
        thread.join();
        self.heartbeat_thread = null;
    }
}

fn heartbeat_loop(self: *Self) void {
    while (!self.stop_heartbeat.load(.acquire)) {
        self.sleep_until_next_heartbeat();
        if (self.stop_heartbeat.load(.acquire)) return;

        self.send_heartbeat() catch |err| {
            std.debug.print("Gateway heartbeat failed: {s}\n", .{@errorName(err)});
            return;
        };
    }
}

fn sleep_until_next_heartbeat(self: *Self) void {
    var remaining_ms = self.heartbeat_interval_ms;
    while (remaining_ms > 0 and !self.stop_heartbeat.load(.acquire)) {
        const sleep_ms = @min(remaining_ms, 250);
        std.Io.sleep(
            std.Options.debug_io,
            std.Io.Duration.fromMilliseconds(@intCast(sleep_ms)),
            .awake,
        ) catch {};
        remaining_ms -= sleep_ms;
    }
}

test "GatewayClient dispatches typed callbacks" {
    const allocator = std.testing.allocator;

    const Context = struct {
        ready_count: u8 = 0,
        event_count: u8 = 0,
        message_count: u8 = 0,
        reaction_count: u8 = 0,
        reaction_remove_count: u8 = 0,

        fn on_ready(self: *@This(), event: ReadyEvent) !void {
            self.ready_count += 1;
            try std.testing.expectEqualStrings("42", event.user.id);
            try std.testing.expectEqualStrings("session", event.session_id);
        }

        fn on_event(self: *@This(), event: GatewayEvent) !void {
            self.event_count += 1;
            try std.testing.expect(event.sequence != null);
        }

        fn on_message(self: *@This(), event: MessageCreateEvent) !void {
            self.message_count += 1;
            try std.testing.expectEqualStrings("hello", event.content);
        }

        fn on_reaction(self: *@This(), event: MessageReactionEvent) !void {
            self.reaction_count += 1;
            try std.testing.expectEqualStrings("999", event.message_id);
            try std.testing.expectEqualStrings("👍", event.emoji.name orelse unreachable);
            if (event.action == .remove) {
                self.reaction_remove_count += 1;
            }
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var context = Context{};

    const ready_json =
        \\{"op":0,"s":1,"t":"READY","d":{"v":10,
        \\"user":{"id":"42","username":"zig"},"guilds":[],
        \\"session_id":"session","resume_gateway_url":"wss://resume"}}
    ;
    const message_json =
        \\{"op":0,"s":2,"t":"MESSAGE_CREATE","d":{"id":"999",
        \\"channel_id":"123","content":"hello",
        \\"author":{"id":"42","username":"zig"}}}
    ;
    const reaction_add_json =
        \\{"op":0,"s":3,"t":"MESSAGE_REACTION_ADD","d":{"user_id":"42",
        \\"channel_id":"123","message_id":"999","emoji":{"name":"👍"},
        \\"burst":false,"type":0}}
    ;
    const reaction_remove_json =
        \\{"op":0,"s":4,"t":"MESSAGE_REACTION_REMOVE","d":{"user_id":"42",
        \\"channel_id":"123","message_id":"999","emoji":{"name":"👍"},
        \\"burst":false,"type":0}}
    ;

    try gateway.dispatch_text(Context, &context, ready_json, .{});
    try gateway.dispatch_text(Context, &context, message_json, .{});
    try gateway.dispatch_text(Context, &context, reaction_add_json, .{});
    try gateway.dispatch_text(Context, &context, reaction_remove_json, .{});

    try std.testing.expectEqual(@as(u8, 1), context.ready_count);
    try std.testing.expectEqual(@as(u8, 4), context.event_count);
    try std.testing.expectEqual(@as(u8, 1), context.message_count);
    try std.testing.expectEqual(@as(u8, 2), context.reaction_count);
    try std.testing.expectEqual(@as(u8, 1), context.reaction_remove_count);
}

test "GatewayClient dispatches only callbacks implemented by typed handler" {
    // ARRANGE
    const allocator = std.testing.allocator;

    const Handler = struct {
        event_calls: u8 = 0,
        message_calls: u8 = 0,

        fn on_event(self: *@This(), event: GatewayEvent) !void {
            try std.testing.expectEqualStrings("MESSAGE_CREATE", event.name);
            self.event_calls += 1;
        }

        fn on_message(self: *@This(), event: MessageCreateEvent) !void {
            try std.testing.expectEqualStrings("hello", event.content);
            self.message_calls += 1;
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var handler = Handler{};

    // ACT
    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":1,"t":"MESSAGE_CREATE","d":{"id":"999","channel_id":"123","content":"hello"}}
    , .{});

    // ASSERT
    try std.testing.expectEqual(@as(u8, 1), handler.event_calls);
    try std.testing.expectEqual(@as(u8, 1), handler.message_calls);
}

test "GatewayClient dispatches slash command interactions" {
    // ARRANGE
    const allocator = std.testing.allocator;

    const Handler = struct {
        slash_calls: u8 = 0,

        fn on_slash_command(self: *@This(), event: SlashCommandEvent) !void {
            self.slash_calls += 1;
            try std.testing.expectEqualStrings("interaction-1", event.id);
            try std.testing.expectEqualStrings("ping", event.name);
            try std.testing.expectEqualStrings("command-1", event.command_id orelse unreachable);
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var handler = Handler{};

    // ACT
    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":1,"t":"INTERACTION_CREATE","d":{"id":"interaction-1",
        \\"type":2,"token":"interaction-token","channel_id":"123",
        \\"data":{"id":"command-1","name":"ping"}}}
    , .{});

    // ASSERT
    try std.testing.expectEqual(@as(u8, 1), handler.slash_calls);
}

test "GatewayClient dispatches component interactions" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        component_calls: u8 = 0,

        fn on_component(self: *@This(), event: ComponentEvent) !void {
            self.component_calls += 1;
            try std.testing.expectEqualStrings("interaction-2", event.id);
            try std.testing.expectEqualStrings("panel:ping", event.custom_id);
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var handler = Handler{};

    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":1,"t":"INTERACTION_CREATE","d":{"id":"interaction-2",
        \\"type":3,"token":"interaction-token","channel_id":"123",
        \\"data":{"custom_id":"panel:ping"}}}
    , .{});

    try std.testing.expectEqual(@as(u8, 1), handler.component_calls);
}

test "GatewayClient dispatches modal submit interactions" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        modal_calls: u8 = 0,

        fn on_modal_submit(self: *@This(), event: ModalSubmitEvent) !void {
            self.modal_calls += 1;
            try std.testing.expectEqualStrings("interaction-3", event.id);
            try std.testing.expectEqualStrings("feedback:modal", event.custom_id);
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var handler = Handler{};

    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":1,"t":"INTERACTION_CREATE","d":{"id":"interaction-3",
        \\"type":5,"token":"interaction-token","channel_id":"123",
        \\"data":{"custom_id":"feedback:modal"}}}
    , .{});

    try std.testing.expectEqual(@as(u8, 1), handler.modal_calls);
}

test "GatewayClient dispatches channel lifecycle events" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        channel_calls: u8 = 0,
        pins_calls: u8 = 0,

        fn on_channel(self: *@This(), event: ChannelEvent) !void {
            self.channel_calls += 1;
            switch (event.action) {
                .create, .update, .delete => {
                    const channel = event.channel orelse return error.MissingChannelPayload;
                    try std.testing.expectEqualStrings("123", channel.id);
                },
                .pins_update => {
                    self.pins_calls += 1;
                    const pins = event.pins_update orelse return error.MissingPinsPayload;
                    try std.testing.expectEqualStrings("123", pins.channel_id);
                },
            }
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var handler = Handler{};

    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":1,"t":"CHANNEL_CREATE","d":{"id":"123","type":0,
        \\"guild_id":"42","name":"general"}}
    , .{});
    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":2,"t":"CHANNEL_UPDATE","d":{"id":"123","type":0,
        \\"guild_id":"42","name":"chat"}}
    , .{});
    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":3,"t":"CHANNEL_DELETE","d":{"id":"123","type":0,
        \\"guild_id":"42","name":"chat"}}
    , .{});
    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":4,"t":"CHANNEL_PINS_UPDATE","d":{"guild_id":"42",
        \\"channel_id":"123","last_pin_timestamp":"2026-04-25T10:00:00.000000+00:00"}}
    , .{});

    try std.testing.expectEqual(@as(u8, 4), handler.channel_calls);
    try std.testing.expectEqual(@as(u8, 1), handler.pins_calls);
}

test "GatewayClient dispatches voice state and server events" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        voice_calls: u8 = 0,
        state_calls: u8 = 0,
        server_calls: u8 = 0,

        fn on_voice(self: *@This(), event: VoiceEvent) !void {
            self.voice_calls += 1;
            switch (event.action) {
                .state_update => {
                    self.state_calls += 1;
                    const state = event.state orelse return error.MissingVoiceStatePayload;
                    try std.testing.expectEqualStrings("99", state.user_id);
                    try std.testing.expectEqualStrings(
                        "voice-session",
                        state.session_id,
                    );
                },
                .server_update => {
                    self.server_calls += 1;
                    const server = event.server orelse return error.MissingVoiceServerPayload;
                    try std.testing.expectEqualStrings("42", server.guild_id);
                    try std.testing.expectEqualStrings(
                        "voice.example.com",
                        server.endpoint orelse unreachable,
                    );
                },
            }
        }
    };

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();

    var handler = Handler{};

    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":1,"t":"VOICE_STATE_UPDATE","d":{"guild_id":"42",
        \\"channel_id":"55","user_id":"99","session_id":"voice-session",
        \\"deaf":false,"mute":false,"self_deaf":false,"self_mute":false,
        \\"self_video":false,"suppress":false}}
    , .{});
    try gateway.dispatch_text(Handler, &handler,
        \\{"op":0,"s":2,"t":"VOICE_SERVER_UPDATE","d":{"token":"voice-token",
        \\"guild_id":"42","endpoint":"voice.example.com"}}
    , .{});

    try std.testing.expectEqual(@as(u8, 2), handler.voice_calls);
    try std.testing.expectEqual(@as(u8, 1), handler.state_calls);
    try std.testing.expectEqual(@as(u8, 1), handler.server_calls);
}

test "GatewayClient rejects payload larger than run options before parsing" {
    // ARRANGE
    const allocator = std.testing.allocator;

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();
    var handler = struct {}{};

    // ACT / ASSERT
    try std.testing.expectError(
        error.GatewayPayloadTooLarge,
        gateway.dispatch_text(@TypeOf(handler), &handler,
            \\{"op":0,"s":1,"t":"READY","d":{}}
        , .{ .max_message_bytes = 8 }),
    );
}

test "GatewayClient rejects missing and oversized token" {
    // ARRANGE
    const allocator = std.testing.allocator;
    var long_token_storage: [token_bytes_max + 1]u8 = undefined;
    @memset(&long_token_storage, 'a');

    // ACT / ASSERT
    var empty_token_gateway: GatewayClient = undefined;
    try std.testing.expectError(
        error.EmptyGatewayToken,
        empty_token_gateway.init(allocator, ""),
    );

    var long_token_gateway: GatewayClient = undefined;
    try std.testing.expectError(
        error.GatewayTokenTooLong,
        long_token_gateway.init(allocator, long_token_storage[0..]),
    );
}

test "GatewayClient rejects invalid dispatch event names" {
    // ARRANGE
    const allocator = std.testing.allocator;

    var gateway: GatewayClient = undefined;
    try gateway.init(allocator, "token");
    defer gateway.deinit();
    var handler = struct {}{};

    // ACT / ASSERT
    try std.testing.expectError(
        error.InvalidGatewayEventName,
        gateway.dispatch_text(@TypeOf(handler), &handler,
            \\{"op":0,"s":1,"t":"message_create","d":{}}
        , .{}),
    );
}
