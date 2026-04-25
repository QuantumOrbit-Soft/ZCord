const std = @import("std");

pub const GatewayProtocol = @This();

pub const default_gateway_url = "wss://gateway.discord.gg/?v=10&encoding=json";
pub const default_max_message_bytes: usize = 16 * 1024 * 1024;
pub const event_name_bytes_max: usize = 64;
pub const token_bytes_max: usize = 512;
pub const gateway_url_bytes_max: usize = 2048;

pub const init_error = error{
    EmptyGatewayToken,
    GatewayTokenTooLong,
};

pub const run_options_error = error{
    EmptyGatewayUrl,
    GatewayUrlTooLong,
    InvalidGatewayUrl,
    InvalidMaxMessageBytes,
};

pub const Intents = struct {
    pub const guilds: u32 = 1 << 0;
    pub const guild_voice_states: u32 = 1 << 7;
    pub const guild_messages: u32 = 1 << 9;
    pub const guild_message_reactions: u32 = 1 << 10;
    pub const direct_messages: u32 = 1 << 12;
    pub const direct_message_reactions: u32 = 1 << 13;
    pub const message_content: u32 = 1 << 15;

    pub const channel_events: u32 = guilds;
    pub const voice_events: u32 = guild_voice_states;

    pub const message_events: u32 =
        guilds |
        guild_messages |
        guild_message_reactions |
        direct_messages |
        direct_message_reactions |
        message_content;
};

pub const RunOptions = struct {
    url: []const u8 = default_gateway_url,
    intents: u32 = Intents.message_events,
    max_message_bytes: usize = default_max_message_bytes,
};

pub const Opcode = enum(u8) {
    dispatch = 0,
    heartbeat = 1,
    identify = 2,
    reconnect = 7,
    invalid_session = 9,
    hello = 10,
    heartbeat_ack = 11,
};

pub const Payload = struct {
    op: u8,
    d: ?std.json.Value = null,
    s: ?u64 = null,
    t: ?[]const u8 = null,
};

pub const HelloData = struct {
    heartbeat_interval: u64,
};

pub fn validate_token(token: []const u8) init_error!void {
    if (0 < token.len) {} else return error.EmptyGatewayToken;
    if (token.len <= token_bytes_max) {} else return error.GatewayTokenTooLong;
}

pub fn validate_run_options(options: RunOptions) run_options_error!void {
    if (0 < options.url.len) {} else return error.EmptyGatewayUrl;
    if (options.url.len <= gateway_url_bytes_max) {} else return error.GatewayUrlTooLong;
    if (0 < options.max_message_bytes) {} else return error.InvalidMaxMessageBytes;

    const has_ws_scheme = std.mem.startsWith(u8, options.url, "ws://");
    const has_wss_scheme = std.mem.startsWith(u8, options.url, "wss://");
    if (has_ws_scheme or has_wss_scheme) {} else return error.InvalidGatewayUrl;
}

pub fn validate_text(text: []const u8, options: RunOptions) !void {
    try validate_run_options(options);
    if (text.len <= options.max_message_bytes) {} else {
        return error.GatewayPayloadTooLarge;
    }
}

pub fn validate_event_name(name: []const u8) !void {
    if (0 < name.len) {} else return error.EmptyGatewayEventName;
    if (name.len <= event_name_bytes_max) {} else {
        return error.GatewayEventNameTooLong;
    }

    for (name) |byte| {
        const valid = std.ascii.isUpper(byte) or byte == '_';
        if (valid) {} else return error.InvalidGatewayEventName;
    }
}

test "GatewayProtocol validates hostile run options" {
    var long_url_storage: [gateway_url_bytes_max + 1]u8 = undefined;
    @memset(&long_url_storage, 'a');

    try std.testing.expectError(
        error.EmptyGatewayUrl,
        validate_run_options(.{ .url = "" }),
    );
    try std.testing.expectError(
        error.GatewayUrlTooLong,
        validate_run_options(.{ .url = long_url_storage[0..] }),
    );
    try std.testing.expectError(
        error.InvalidGatewayUrl,
        validate_run_options(.{ .url = "https://gateway.discord.gg" }),
    );
    try std.testing.expectError(
        error.InvalidMaxMessageBytes,
        validate_run_options(.{ .max_message_bytes = 0 }),
    );
}

test "GatewayProtocol rejects missing and oversized token" {
    var long_token_storage: [token_bytes_max + 1]u8 = undefined;
    @memset(&long_token_storage, 'a');

    try std.testing.expectError(error.EmptyGatewayToken, validate_token(""));
    try std.testing.expectError(
        error.GatewayTokenTooLong,
        validate_token(long_token_storage[0..]),
    );
}

test "GatewayProtocol rejects invalid event names" {
    try std.testing.expectError(error.EmptyGatewayEventName, validate_event_name(""));
    try std.testing.expectError(
        error.InvalidGatewayEventName,
        validate_event_name("message_create"),
    );
    try std.testing.expectError(
        error.InvalidGatewayEventName,
        validate_event_name("MESSAGE-CREATE"),
    );
}

test "GatewayProtocol validates payload size before parsing" {
    try validate_text("{}", .{ .max_message_bytes = 2 });
    try std.testing.expectError(
        error.GatewayPayloadTooLarge,
        validate_text("{}", .{ .max_message_bytes = 1 }),
    );
}
