const std = @import("std");
const builtin = @import("builtin");
const query_builder = @import("query_builder.zig");
const request_mod = @import("request.zig");
const scratch = @import("scratch.zig");

const Self = @This();
const empty_headers: []const std.http.Header = &.{};
const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const default_max_message_bytes: usize = 16 * 1024 * 1024;
pub const default_max_handshake_bytes: usize = 16 * 1024;

allocator: std.mem.Allocator = undefined,
http_client: std.http.Client = undefined,
connection: ?*std.http.Client.Connection = null,
max_message_bytes: usize = default_max_message_bytes,
auto_pong: bool = true,
selected_subprotocol: ?[]u8 = null,
close_sent: bool = false,
close_received: bool = false,

pub const QueryError = query_builder.Error;
pub const PayloadError = scratch.Error;
pub const ConnectArg = request_mod.RequestArg;
pub const HeadersArg = request_mod.HeadersArg;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const MessageKind = enum {
    text,
    binary,
    close,
};

pub const Message = struct {
    allocator: std.mem.Allocator,
    kind: MessageKind,
    data: []u8,
    close_code: ?u16 = null,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn json(
        self: Message,
        comptime T: type,
    ) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, self.data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

pub const ConnectSenders = struct {
    url: []const u8,
    headers: []const std.http.Header = empty_headers,
    subprotocol: ?[]const u8 = null,
    max_message_bytes: usize = default_max_message_bytes,
    auto_pong: bool = true,
    max_handshake_bytes: usize = default_max_handshake_bytes,
};

pub const CloseSender = struct {
    code: u16 = 1000,
    reason: []const u8 = "",
};

pub const Senders = struct {
    text: ?[]const u8 = null,
    binary: ?[]const u8 = null,
    ping: ?[]const u8 = null,
    pong: ?[]const u8 = null,
    close: ?CloseSender = null,
};

pub const SendArg = union(enum) {
    none_value: void,
    text_value: []const u8,
    binary_value: []const u8,
    ping_value: []const u8,
    pong_value: []const u8,
    close_value: CloseSender,

    pub fn none() SendArg {
        return .{ .none_value = {} };
    }

    pub fn text(value: []const u8) SendArg {
        return .{ .text_value = value };
    }

    pub fn binary(value: []const u8) SendArg {
        return .{ .binary_value = value };
    }

    pub fn ping(value: []const u8) SendArg {
        return .{ .ping_value = value };
    }

    pub fn pong(value: []const u8) SendArg {
        return .{ .pong_value = value };
    }

    pub fn close(value: anytype) SendArg {
        return .{ .close_value = extract_close_sender(value) };
    }
};

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .http_client = .{
            .allocator = allocator,
            .io = std.Options.debug_io,
        },
    };
}

pub fn deinit(self: *Self) void {
    self.disconnect();
    self.http_client.deinit();
    self.* = undefined;
}

pub fn is_connected(self: Self) bool {
    return self.connection != null;
}

pub fn subprotocol(self: Self) ?[]const u8 {
    return self.selected_subprotocol;
}

pub fn disconnect(self: *Self) void {
    if (self.connection) |connection| {
        connection.closing = true;
        self.http_client.connection_pool.release(connection, self.http_client.io);
        self.connection = null;
    }

    if (self.selected_subprotocol) |value| {
        self.allocator.free(value);
        self.selected_subprotocol = null;
    }

    self.close_sent = false;
    self.close_received = false;
}

const ConnectLimits = struct {
    max_message_bytes: usize,
    auto_pong: bool,
    max_handshake_bytes: usize,
};

const PreparedConnectUrl = struct {
    value: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *PreparedConnectUrl, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

const HandshakeSenderFields = struct {
    user_headers: []const std.http.Header,
    requested_subprotocol: ?[]const u8,
};

const HandshakeKeys = struct {
    websocket_key_buf: [24]u8 = undefined,
    expected_accept_buf: [28]u8 = undefined,
    websocket_key: []const u8 = &.{},
    expected_accept: []const u8 = &.{},

    fn init(self: *HandshakeKeys) void {
        var random_key: [16]u8 = undefined;
        std.Options.debug_io.random(&random_key);

        self.websocket_key = encode_base64_fixed(&self.websocket_key_buf, &random_key);
        self.expected_accept = websocket_accept_from_key(
            self.websocket_key,
            &self.expected_accept_buf,
        );
    }
};

const HandshakeResult = struct {
    connection: *std.http.Client.Connection,
    selected_subprotocol: ?[]u8,
};

pub fn connect(
    self: *Self,
    connect_arg: ConnectArg,
    headers_arg: HeadersArg,
    options: anytype,
) !void {
    comptime assert_connect_options_type(@TypeOf(options));

    if (self.connection != null) return error.AlreadyConnected;

    var prepared_url = try self.prepare_connect_url_from_args(connect_arg, options);
    defer prepared_url.deinit(self.allocator);

    const uri = try parse_and_validate_connect_uri(prepared_url.value);
    const connect_limits = try parse_connect_limits(options);

    const previous_read_buffer_size = self.widen_read_buffer_for_handshake(
        connect_limits.max_handshake_bytes,
    );
    defer self.http_client.read_buffer_size = previous_read_buffer_size;

    const sender_fields = try connect_handshake_fields(headers_arg, options);
    var handshake_keys: HandshakeKeys = .{};
    handshake_keys.init();

    var extra_headers = try self.build_extra_handshake_headers(
        sender_fields.user_headers,
        sender_fields.requested_subprotocol,
        handshake_keys.websocket_key,
    );
    defer extra_headers.deinit();

    const handshake_result = try self.request_handshake(
        uri,
        extra_headers.items,
        handshake_keys.expected_accept,
        sender_fields.requested_subprotocol,
    );

    self.activate_connected_state(
        handshake_result.connection,
        handshake_result.selected_subprotocol,
        connect_limits,
    );
}

fn assert_connect_options_type(comptime Options: type) void {
    if (@typeInfo(Options) != .@"struct") {
        @compileError("connect options precisa ser um struct anonimo, ex: .{ .subprotocol = \"chat\" }");
    }
}

fn prepare_connect_url_from_args(self: *Self, connect_arg: ConnectArg, options: anytype) !PreparedConnectUrl {
    const Options = @TypeOf(options);
    var prepared: PreparedConnectUrl = .{ .value = connect_arg.url_slice() };

    if (!@hasField(Options, "query")) return prepared;

    const query_or_optional = @field(options, "query");
    try self.apply_connect_query(&prepared, query_or_optional);
    return prepared;
}

fn connect_handshake_fields(headers_arg: HeadersArg, options: anytype) !HandshakeSenderFields {
    const user_headers = headers_arg.slice();
    try validate_caller_headers(user_headers);

    return .{
        .user_headers = user_headers,
        .requested_subprotocol = sender_subprotocol(options),
    };
}

fn prepare_connect_url(self: *Self, sender: anytype) !PreparedConnectUrl {
    const Sender = @TypeOf(sender);
    var prepared: PreparedConnectUrl = .{ .value = @field(sender, "url") };

    if (!@hasField(Sender, "query")) return prepared;

    const query_or_optional = @field(sender, "query");
    try self.apply_connect_query(&prepared, query_or_optional);
    return prepared;
}

fn apply_connect_query(
    self: *Self,
    prepared_url: *PreparedConnectUrl,
    query_or_optional: anytype,
) !void {
    switch (@typeInfo(@TypeOf(query_or_optional))) {
        .optional => {
            if (query_or_optional) |query| {
                try self.apply_connect_query(prepared_url, query);
            }
        },
        else => {
            const built_url = try query_builder.build(
                self.allocator,
                prepared_url.value,
                query_or_optional,
            );
            if (prepared_url.owned) |owned| self.allocator.free(owned);

            prepared_url.value = built_url;
            prepared_url.owned = built_url;
        },
    }
}

fn parse_and_validate_connect_uri(url: []const u8) !std.Uri {
    const uri = try std.Uri.parse(url);
    if (!is_supported_web_socket_scheme(uri.scheme)) return error.UnsupportedUriScheme;
    return uri;
}

fn is_supported_web_socket_scheme(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "ws") or std.ascii.eqlIgnoreCase(scheme, "wss");
}

fn parse_connect_limits(sender: anytype) !ConnectLimits {
    const max_message_bytes = sender_max_message_bytes(sender);
    if (max_message_bytes == 0) return error.InvalidMessageLimit;

    const max_handshake_bytes = sender_max_handshake_bytes(sender);
    if (max_handshake_bytes == 0) return error.InvalidHandshakeLimit;

    return .{
        .max_message_bytes = max_message_bytes,
        .auto_pong = sender_auto_pong(sender),
        .max_handshake_bytes = max_handshake_bytes,
    };
}

fn sender_handshake_fields(sender: anytype) !HandshakeSenderFields {
    const user_headers = sender_headers(sender);
    try validate_caller_headers(user_headers);

    return .{
        .user_headers = user_headers,
        .requested_subprotocol = sender_subprotocol(sender),
    };
}

fn widen_read_buffer_for_handshake(self: *Self, max_handshake_bytes: usize) usize {
    const previous_read_buffer_size = self.http_client.read_buffer_size;
    if (self.http_client.read_buffer_size < max_handshake_bytes) {
        self.http_client.read_buffer_size = max_handshake_bytes;
    }
    return previous_read_buffer_size;
}

fn build_extra_handshake_headers(
    self: *Self,
    user_headers: []const std.http.Header,
    requested_subprotocol: ?[]const u8,
    websocket_key: []const u8,
) !std.array_list.Managed(std.http.Header) {
    var headers = std.array_list.Managed(std.http.Header).init(self.allocator);
    errdefer headers.deinit();

    try headers.append(.{ .name = "upgrade", .value = "websocket" });
    try headers.append(.{ .name = "sec-websocket-version", .value = "13" });
    try headers.append(.{ .name = "sec-websocket-key", .value = websocket_key });

    if (requested_subprotocol) |value| {
        try headers.append(.{ .name = "sec-websocket-protocol", .value = value });
    }

    try headers.appendSlice(user_headers);
    return headers;
}

fn request_handshake(
    self: *Self,
    uri: std.Uri,
    extra_headers: []const std.http.Header,
    expected_accept: []const u8,
    requested_subprotocol: ?[]const u8,
) !HandshakeResult {
    var request = try self.http_client.request(.GET, uri, .{
        .keep_alive = true,
        .redirect_behavior = .unhandled,
        .headers = .{
            .connection = .{ .override = "upgrade" },
            .accept_encoding = .omit,
        },
        .extra_headers = extra_headers,
    });
    defer request.deinit();

    try request.sendBodiless();
    const response = try request.receiveHead(&.{});
    if (response.head.status != .switching_protocols) return error.HandshakeRejected;

    const selected_subprotocol_view = try validate_handshake_response(
        response.head,
        expected_accept,
        requested_subprotocol,
    );

    var selected_subprotocol: ?[]u8 = null;
    errdefer if (selected_subprotocol) |value| self.allocator.free(value);
    if (selected_subprotocol_view) |value| {
        selected_subprotocol = try self.allocator.dupe(u8, value);
    }

    const connection = request.connection orelse return error.HandshakeRejected;
    request.connection = null;

    return .{
        .connection = connection,
        .selected_subprotocol = selected_subprotocol,
    };
}

fn activate_connected_state(
    self: *Self,
    connection: *std.http.Client.Connection,
    selected_subprotocol: ?[]u8,
    connect_limits: ConnectLimits,
) void {
    connection.closing = false;

    if (self.selected_subprotocol) |value| {
        self.allocator.free(value);
        self.selected_subprotocol = null;
    }

    self.connection = connection;
    self.selected_subprotocol = selected_subprotocol;
    self.max_message_bytes = connect_limits.max_message_bytes;
    self.auto_pong = connect_limits.auto_pong;
    self.close_sent = false;
    self.close_received = false;
}

pub fn send(self: *Self, send_arg: SendArg) !void {
    if (self.connection == null) return error.NotConnected;

    var prepared = try self.prepare_send_arg(send_arg);
    defer prepared.deinit(self.allocator);

    if (prepared.opcode == .text and !std.unicode.utf8ValidateSlice(prepared.payload)) {
        return error.InvalidUtf8Payload;
    }

    try write_client_frame_random_mask(self.connection.?.writer(), prepared.opcode, prepared.payload);
    try self.connection.?.flush();

    if (prepared.opcode == .close) {
        self.close_sent = true;
    }
}

pub fn send_json(self: *Self, payload: anytype) !void {
    if (self.connection == null) return error.NotConnected;

    const encoded = try scratch.json(self.allocator, payload);
    defer self.allocator.free(encoded);

    if (!std.unicode.utf8ValidateSlice(encoded)) {
        return error.InvalidUtf8Payload;
    }

    try write_client_frame_random_mask(self.connection.?.writer(), .text, encoded);
    try self.connection.?.flush();
}

fn prepare_send_arg(self: *Self, send_arg: SendArg) !PreparedSend {
    return switch (send_arg) {
        .none_value => error.EmptySend,
        .text_value => |payload| .{ .opcode = .text, .payload = payload },
        .binary_value => |payload| .{ .opcode = .binary, .payload = payload },
        .ping_value => |payload| .{ .opcode = .ping, .payload = payload },
        .pong_value => |payload| .{ .opcode = .pong, .payload = payload },
        .close_value => |close_sender| blk: {
            const close_payload = try make_close_payload(self.allocator, close_sender);
            break :blk .{
                .opcode = .close,
                .payload = close_payload,
                .owned_payload = close_payload,
            };
        },
    };
}

pub fn read(self: *Self) !Message {
    if (self.connection == null) return error.NotConnected;

    var accumulator = std.array_list.Managed(u8).init(self.allocator);
    defer accumulator.deinit();

    var building_kind: ?MessageKind = null;

    while (true) {
        var frame = try read_server_frame(
            self.connection.?.reader(),
            self.allocator,
            self.max_message_bytes,
        );
        defer frame.deinit(self.allocator);

        switch (frame.opcode) {
            .ping => {
                try self.handle_ping_frame(frame.payload);
                continue;
            },
            .pong => continue,
            .close => return self.handle_close_frame(frame.payload),
            .text, .binary => {
                if (building_kind != null) return error.InvalidFrameSequence;

                const kind: MessageKind = if (frame.opcode == .text) .text else .binary;

                if (frame.fin) {
                    if (kind == .text and !std.unicode.utf8ValidateSlice(frame.payload)) {
                        return error.InvalidUtf8Payload;
                    }
                    return frame.into_message(self.allocator, kind, null);
                }

                building_kind = kind;
                try append_with_limit(&accumulator, frame.payload, self.max_message_bytes);
            },
            .continuation => {
                if (building_kind == null) return error.UnexpectedContinuationFrame;

                try append_with_limit(&accumulator, frame.payload, self.max_message_bytes);
                if (!frame.fin) continue;

                const kind = building_kind.?;
                building_kind = null;

                const payload = try self.allocator.dupe(u8, accumulator.items);
                errdefer self.allocator.free(payload);
                accumulator.clearRetainingCapacity();

                if (kind == .text and !std.unicode.utf8ValidateSlice(payload)) {
                    return error.InvalidUtf8Payload;
                }

                return .{
                    .allocator = self.allocator,
                    .kind = kind,
                    .data = payload,
                };
            },
        }
    }
}

fn handle_ping_frame(self: *Self, payload: []const u8) !void {
    if (!self.auto_pong) return;

    try write_client_frame_random_mask(self.connection.?.writer(), .pong, payload);
    try self.connection.?.flush();
}

fn handle_close_frame(self: *Self, payload: []const u8) !Message {
    self.close_received = true;
    const close_payload = try parse_close_payload(payload);

    if (!self.close_sent and self.connection != null) {
        try write_client_frame_random_mask(self.connection.?.writer(), .close, payload);
        try self.connection.?.flush();
        self.close_sent = true;
    }

    self.disconnect();

    const reason_copy = try self.allocator.dupe(u8, close_payload.reason);
    return .{
        .allocator = self.allocator,
        .kind = .close,
        .data = reason_copy,
        .close_code = close_payload.code,
    };
}

const PreparedSend = struct {
    opcode: Opcode,
    payload: []const u8,
    owned_payload: ?[]u8 = null,

    fn deinit(self: *PreparedSend, allocator: std.mem.Allocator) void {
        if (self.owned_payload) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

fn prepare_send(self: *Self, sender: anytype) !PreparedSend {
    const Sender = @TypeOf(sender);
    comptime assert_send_sender(Sender);

    var prepared: ?PreparedSend = null;
    var sources: u8 = 0;

    if (@hasField(Sender, "text")) {
        try self.prepare_slice_sender_field(sender, &prepared, &sources, "text", .text);
    }
    if (@hasField(Sender, "binary")) {
        try self.prepare_slice_sender_field(sender, &prepared, &sources, "binary", .binary);
    }
    if (@hasField(Sender, "ping")) {
        try self.prepare_slice_sender_field(sender, &prepared, &sources, "ping", .ping);
    }
    if (@hasField(Sender, "pong")) {
        try self.prepare_slice_sender_field(sender, &prepared, &sources, "pong", .pong);
    }
    if (@hasField(Sender, "json")) {
        try self.prepare_json_sender_field(sender, &prepared, &sources);
    }
    if (@hasField(Sender, "close")) {
        try self.prepare_close_sender_field(sender, &prepared, &sources);
    }

    return prepared orelse error.EmptySend;
}

fn prepare_slice_sender_field(
    self: *Self,
    sender: anytype,
    prepared: *?PreparedSend,
    sources: *u8,
    comptime field_name: []const u8,
    opcode: Opcode,
) !void {
    const field_value = @field(sender, field_name);
    switch (@typeInfo(@TypeOf(field_value))) {
        .optional => {
            if (field_value) |inner| {
                const payload: []const u8 = inner;
                try self.assign_prepared(prepared, sources, opcode, payload, null);
            }
        },
        else => {
            const payload: []const u8 = field_value;
            try self.assign_prepared(prepared, sources, opcode, payload, null);
        },
    }
}

fn prepare_json_sender_field(
    self: *Self,
    sender: anytype,
    prepared: *?PreparedSend,
    sources: *u8,
) !void {
    const field_value = @field(sender, "json");
    switch (@typeInfo(@TypeOf(field_value))) {
        .optional => {
            if (field_value) |inner| {
                try self.prepare_json_value(prepared, sources, inner);
            }
        },
        else => {
            try self.prepare_json_value(prepared, sources, field_value);
        },
    }
}

fn prepare_json_value(
    self: *Self,
    prepared: *?PreparedSend,
    sources: *u8,
    json_payload: anytype,
) !void {
    const encoded = try scratch.json(self.allocator, json_payload);
    try self.assign_prepared(prepared, sources, .text, encoded, encoded);
}

fn prepare_close_sender_field(
    self: *Self,
    sender: anytype,
    prepared: *?PreparedSend,
    sources: *u8,
) !void {
    const field_value = @field(sender, "close");
    switch (@typeInfo(@TypeOf(field_value))) {
        .optional => {
            if (field_value) |inner| {
                try self.prepare_close_value(prepared, sources, inner);
            }
        },
        else => {
            try self.prepare_close_value(prepared, sources, field_value);
        },
    }
}

fn prepare_close_value(
    self: *Self,
    prepared: *?PreparedSend,
    sources: *u8,
    close_value: anytype,
) !void {
    const close_sender = extract_close_sender(close_value);
    const close_payload = try make_close_payload(self.allocator, close_sender);
    try self.assign_prepared(prepared, sources, .close, close_payload, close_payload);
}

fn extract_close_sender(close_value: anytype) CloseSender {
    const T = @TypeOf(close_value);
    if (@typeInfo(T) != .@"struct") {
        @compileError("sender.close deve ser um struct (anonimo ou nomeado)");
    }

    var result: CloseSender = .{};

    if (@hasField(T, "code")) {
        const code_field = @field(close_value, "code");
        result.code = switch (@typeInfo(@TypeOf(code_field))) {
            .optional => if (code_field) |inner| inner else result.code,
            else => code_field,
        };
    }

    if (@hasField(T, "reason")) {
        const reason_field = @field(close_value, "reason");
        result.reason = switch (@typeInfo(@TypeOf(reason_field))) {
            .optional => if (reason_field) |inner| inner else result.reason,
            else => reason_field,
        };
    }

    return result;
}

fn assign_prepared(
    self: *Self,
    prepared: *?PreparedSend,
    sources: *u8,
    opcode: Opcode,
    payload: []const u8,
    owned_payload: ?[]u8,
) !void {
    sources.* += 1;
    if (sources.* > 1) {
        if (owned_payload) |owned| self.allocator.free(owned);
        return error.MultipleSendKinds;
    }

    if (is_control_opcode(opcode) and payload.len > 125) {
        if (owned_payload) |owned| self.allocator.free(owned);
        return error.ControlFrameTooLarge;
    }

    prepared.* = .{
        .opcode = opcode,
        .payload = payload,
        .owned_payload = owned_payload,
    };
}

const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }

    fn into_message(
        self: *Frame,
        allocator: std.mem.Allocator,
        kind: MessageKind,
        close_code: ?u16,
    ) Message {
        const payload = self.payload;
        self.payload = &.{};
        return .{
            .allocator = allocator,
            .kind = kind,
            .data = payload,
            .close_code = close_code,
        };
    }
};

fn write_client_frame_random_mask(writer: *std.Io.Writer, opcode: Opcode, payload: []const u8) !void {
    var mask: [4]u8 = undefined;
    std.Options.debug_io.random(&mask);
    try write_client_frame_with_mask(writer, opcode, payload, mask);
}

fn write_client_frame_with_mask(
    writer: *std.Io.Writer,
    opcode: Opcode,
    payload: []const u8,
    mask: [4]u8,
) !void {
    if (is_control_opcode(opcode) and payload.len > 125) return error.ControlFrameTooLarge;

    var head: [14]u8 = undefined;
    var head_len: usize = 0;

    head[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    head_len += 1;

    if (payload.len <= 125) {
        head[1] = 0x80 | @as(u8, @intCast(payload.len));
        head_len = 2;
    } else if (payload.len <= std.math.maxInt(u16)) {
        head[1] = 0x80 | 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        head_len = 4;
    } else {
        head[1] = 0x80 | 127;
        std.mem.writeInt(u64, head[2..10], @intCast(payload.len), .big);
        head_len = 10;
    }

    @memcpy(head[head_len .. head_len + 4], &mask);
    head_len += 4;

    try writer.writeAll(head[0..head_len]);

    var offset: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const take = @min(remaining, chunk.len);

        for (0..take) |index| {
            chunk[index] = payload[offset + index] ^ mask[(offset + index) & 3];
        }

        try writer.writeAll(chunk[0..take]);
        offset += take;
    }
}

fn write_server_frame_for_test(
    writer: *std.Io.Writer,
    opcode: Opcode,
    payload: []const u8,
    fin: bool,
) !void {
    if (is_control_opcode(opcode) and payload.len > 125) return error.ControlFrameTooLarge;

    var head: [10]u8 = undefined;
    var head_len: usize = 0;

    head[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    head_len += 1;

    if (payload.len <= 125) {
        head[1] = @intCast(payload.len);
        head_len = 2;
    } else if (payload.len <= std.math.maxInt(u16)) {
        head[1] = 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        head_len = 4;
    } else {
        head[1] = 127;
        std.mem.writeInt(u64, head[2..10], @intCast(payload.len), .big);
        head_len = 10;
    }

    try writer.writeAll(head[0..head_len]);
    try writer.writeAll(payload);
}

fn read_server_frame(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    max_payload_size: usize,
) !Frame {
    const first = try reader.takeByte();
    const second = try reader.takeByte();

    const fin = (first & 0x80) != 0;
    const has_reserved_bits = (first & 0x70) != 0;
    if (has_reserved_bits) return error.UnsupportedReservedBits;

    const opcode = try parse_opcode(@intCast(first & 0x0f));
    const is_masked = (second & 0x80) != 0;
    if (is_masked) return error.ServerFramesMustNotBeMasked;

    var payload_len_u64: u64 = second & 0x7f;
    switch (payload_len_u64) {
        126 => payload_len_u64 = try reader.takeInt(u16, .big),
        127 => payload_len_u64 = try reader.takeInt(u64, .big),
        else => {},
    }

    if (is_control_opcode(opcode)) {
        if (!fin) return error.FragmentedControlFrame;
        if (payload_len_u64 > 125) return error.ControlFrameTooLarge;
    }

    if (payload_len_u64 > max_payload_size) return error.MessageTooLarge;

    const payload_len: usize = @intCast(payload_len_u64);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);

    try reader.readSliceAll(payload);

    return .{
        .fin = fin,
        .opcode = opcode,
        .payload = payload,
    };
}

fn parse_opcode(raw: u4) !Opcode {
    return switch (raw) {
        0x0 => .continuation,
        0x1 => .text,
        0x2 => .binary,
        0x8 => .close,
        0x9 => .ping,
        0xA => .pong,
        else => error.UnsupportedOpcode,
    };
}

fn is_control_opcode(opcode: Opcode) bool {
    return switch (opcode) {
        .close, .ping, .pong => true,
        else => false,
    };
}

fn append_with_limit(list: *std.array_list.Managed(u8), data: []const u8, max_size: usize) !void {
    if (data.len > max_size) return error.MessageTooLarge;
    if (list.items.len > max_size - data.len) return error.MessageTooLarge;
    try list.appendSlice(data);
}

const ClosePayload = struct {
    code: ?u16,
    reason: []const u8,
};

fn make_close_payload(allocator: std.mem.Allocator, close: CloseSender) ![]u8 {
    if (!is_valid_close_code(close.code)) return error.InvalidCloseCode;
    if (!std.unicode.utf8ValidateSlice(close.reason)) return error.InvalidUtf8Payload;
    if (close.reason.len > 123) return error.CloseReasonTooLarge;

    const payload = try allocator.alloc(u8, 2 + close.reason.len);
    std.mem.writeInt(u16, payload[0..2], close.code, .big);
    @memcpy(payload[2..], close.reason);
    return payload;
}

fn parse_close_payload(payload: []const u8) !ClosePayload {
    if (payload.len == 0) {
        return .{ .code = null, .reason = "" };
    }

    if (payload.len == 1) return error.InvalidClosePayload;

    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!is_valid_close_code(code)) return error.InvalidCloseCode;

    const reason = payload[2..];
    if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8Payload;

    return .{
        .code = code,
        .reason = reason,
    };
}

fn is_valid_close_code(code: u16) bool {
    if (code < 1000) return false;
    if (code >= 5000) return false;

    return switch (code) {
        1004, 1005, 1006, 1015 => false,
        else => true,
    };
}

fn encode_base64_fixed(dest: []u8, source: []const u8) []const u8 {
    return std.base64.standard.Encoder.encode(dest, source);
}

fn websocket_accept_from_key(key: []const u8, out: []u8) []const u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update(websocket_guid);

    var digest: [20]u8 = undefined;
    hash.final(&digest);

    return std.base64.standard.Encoder.encode(out, &digest);
}

fn validate_handshake_response(
    head: std.http.Client.Response.Head,
    expected_accept: []const u8,
    requested_subprotocol: ?[]const u8,
) !?[]const u8 {
    var has_upgrade = false;
    var has_connection_upgrade = false;
    var has_valid_accept = false;
    var selected_subprotocol: ?[]const u8 = null;

    var it = head.iterateHeaders();
    while (it.next()) |header| {
        const value = trim_header_value(header.value);

        if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            has_upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            has_connection_upgrade = header_contains_token(value, "upgrade");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            has_valid_accept = std.mem.eql(u8, value, expected_accept);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) {
            selected_subprotocol = value;
            continue;
        }
    }

    if (!has_upgrade) return error.InvalidUpgradeHeader;
    if (!has_connection_upgrade) return error.InvalidConnectionHeader;
    if (!has_valid_accept) return error.InvalidAcceptHeader;

    if (requested_subprotocol) |requested| {
        const received = selected_subprotocol orelse return error.MissingSubprotocolResponse;
        if (!std.mem.eql(u8, requested, received)) return error.SubprotocolMismatch;
    }

    return selected_subprotocol;
}

fn trim_header_value(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn header_contains_token(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |piece| {
        if (std.ascii.eqlIgnoreCase(trim_header_value(piece), token)) return true;
    }
    return false;
}

fn validate_caller_headers(headers: []const std.http.Header) !void {
    for (headers) |header| {
        if (is_forbidden_client_header(header.name)) return error.ForbiddenHeaderOverride;
    }
}

fn is_forbidden_client_header(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "sec-websocket-key") or
        std.ascii.eqlIgnoreCase(name, "sec-websocket-version") or
        std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol");
}

fn sender_headers(sender: anytype) []const std.http.Header {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "headers")) return empty_headers;

    const value = @field(sender, "headers");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |headers| headers else empty_headers,
        else => value,
    };
}

fn sender_subprotocol(sender: anytype) ?[]const u8 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "subprotocol")) return null;

    const value = @field(sender, "subprotocol");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value,
        else => value,
    };
}

fn sender_max_message_bytes(sender: anytype) usize {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "max_message_bytes")) return default_max_message_bytes;

    const value = @field(sender, "max_message_bytes");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| inner else default_max_message_bytes,
        else => value,
    };
}

fn sender_auto_pong(sender: anytype) bool {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "auto_pong")) return true;

    const value = @field(sender, "auto_pong");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| inner else true,
        else => value,
    };
}

fn sender_max_handshake_bytes(sender: anytype) usize {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "max_handshake_bytes")) return default_max_handshake_bytes;

    const value = @field(sender, "max_handshake_bytes");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| inner else default_max_handshake_bytes,
        else => value,
    };
}

fn assert_connect_sender(comptime Sender: type) void {
    if (@typeInfo(Sender) != .@"struct") {
        @compileError("sender precisa ser um struct (anonimo ou nomeado)");
    }

    if (!@hasField(Sender, "url")) {
        @compileError("sender.url e obrigatorio");
    }

    const url_field_type = @FieldType(Sender, "url");
    const url_value: url_field_type = undefined;
    const url_slice: []const u8 = url_value;
    _ = url_slice;
}

fn assert_send_sender(comptime Sender: type) void {
    if (@typeInfo(Sender) != .@"struct") {
        @compileError("sender de send precisa ser um struct (anonimo ou nomeado)");
    }
}

fn should_run_real_ws_tests(allocator: std.mem.Allocator) bool {
    _ = allocator;
    return env_var_truthy("RUN_REAL_WS_TESTS");
}

fn env_var_truthy(comptime name_z: [:0]const u8) bool {
    if (!builtin.link_libc) return false;
    const value_z = std.c.getenv(name_z) orelse return false;
    const value = std.mem.sliceTo(value_z, 0);
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

test "websocket accept key example from RFC6455" {
    var out: [28]u8 = undefined;
    const accept = websocket_accept_from_key("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "header token parser handles comma-separated values" {
    try std.testing.expect(header_contains_token("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(!header_contains_token("keep-alive, close", "upgrade"));
}

test "validate handshake response success and subprotocol" {
    const raw = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Sec-WebSocket-Protocol: chat\r\n\r\n";

    const head = try std.http.Client.Response.Head.parse(raw);
    const selected = try validate_handshake_response(
        head,
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        "chat",
    );

    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("chat", selected.?);
}

test "validate handshake response rejects invalid accept header" {
    const raw = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: invalid\r\n\r\n";

    const head = try std.http.Client.Response.Head.parse(raw);
    try std.testing.expectError(
        error.InvalidAcceptHeader,
        validate_handshake_response(head, "expected", null),
    );
}

test "validate handshake response rejects missing upgrade header" {
    const raw = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: x\r\n\r\n";

    const head = try std.http.Client.Response.Head.parse(raw);
    try std.testing.expectError(
        error.InvalidUpgradeHeader,
        validate_handshake_response(head, "x", null),
    );
}

test "validate handshake response rejects missing connection upgrade token" {
    const raw = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Sec-WebSocket-Accept: x\r\n\r\n";

    const head = try std.http.Client.Response.Head.parse(raw);
    try std.testing.expectError(
        error.InvalidConnectionHeader,
        validate_handshake_response(head, "x", null),
    );
}

test "validate handshake response enforces requested subprotocol" {
    const raw_missing = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: x\r\n\r\n";

    const head_missing = try std.http.Client.Response.Head.parse(raw_missing);
    try std.testing.expectError(
        error.MissingSubprotocolResponse,
        validate_handshake_response(head_missing, "x", "chat"),
    );

    const raw_mismatch = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: x\r\n" ++
        "Sec-WebSocket-Protocol: other\r\n\r\n";
    const head_mismatch = try std.http.Client.Response.Head.parse(raw_mismatch);
    try std.testing.expectError(
        error.SubprotocolMismatch,
        validate_handshake_response(head_mismatch, "x", "chat"),
    );
}

test "write client frame applies masking key correctly" {
    const allocator = std.testing.allocator;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try write_client_frame_with_mask(&out.writer, .text, "Hi", .{ 0x01, 0x02, 0x03, 0x04 });

    const frame_bytes = try out.toOwnedSlice();
    defer allocator.free(frame_bytes);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x49, 0x6b },
        frame_bytes,
    );
}

test "write client frame uses 16-bit extended payload length" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 130);
    defer allocator.free(payload);
    @memset(payload, 0x2A);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try write_client_frame_with_mask(&out.writer, .binary, payload, .{ 0x11, 0x22, 0x33, 0x44 });
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 2 + 2 + 4 + payload.len), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x82), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xFE), bytes[1]);
    try std.testing.expectEqual(@as(u16, 130), std.mem.readInt(u16, bytes[2..4], .big));
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, bytes[4..8]);
    try std.testing.expectEqual(@as(u8, payload[0] ^ 0x11), bytes[8]);
    try std.testing.expectEqual(@as(u8, payload[129] ^ 0x22), bytes[8 + 129]);
}

test "write client frame uses 64-bit extended payload length" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 66000);
    defer allocator.free(payload);
    @memset(payload, 0x5A);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try write_client_frame_with_mask(&out.writer, .binary, payload, .{ 0x01, 0x02, 0x03, 0x04 });
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 2 + 8 + 4 + payload.len), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x82), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[1]);
    try std.testing.expectEqual(@as(u64, payload.len), std.mem.readInt(u64, bytes[2..10], .big));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, bytes[10..14]);
}

test "read server frame decodes text payload" {
    const allocator = std.testing.allocator;

    var reader = std.Io.Reader.fixed(&.{ 0x81, 0x02, 'o', 'k' });
    var frame = try read_server_frame(&reader, allocator, 128);
    defer frame.deinit(allocator);

    try std.testing.expect(frame.fin);
    try std.testing.expect(frame.opcode == .text);
    try std.testing.expectEqualStrings("ok", frame.payload);
}

test "read server frame rejects masked payloads" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(&.{ 0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x40, 0x40 });

    try std.testing.expectError(
        error.ServerFramesMustNotBeMasked,
        read_server_frame(&reader, allocator, 128),
    );
}

test "read server frame rejects unsupported opcode" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(&.{ 0x83, 0x00 });

    try std.testing.expectError(
        error.UnsupportedOpcode,
        read_server_frame(&reader, allocator, 128),
    );
}

test "read server frame rejects reserved bits" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(&.{ 0xC1, 0x00 });

    try std.testing.expectError(
        error.UnsupportedReservedBits,
        read_server_frame(&reader, allocator, 128),
    );
}

test "read server frame rejects fragmented control frame" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(&.{ 0x09, 0x00 });

    try std.testing.expectError(
        error.FragmentedControlFrame,
        read_server_frame(&reader, allocator, 128),
    );
}

test "read server frame rejects oversized control frame" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(&.{ 0x88, 126, 0x00, 126 });

    try std.testing.expectError(
        error.ControlFrameTooLarge,
        read_server_frame(&reader, allocator, 4096),
    );
}

test "read server frame enforces message size limit" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(&.{ 0x82, 0x04 });

    try std.testing.expectError(
        error.MessageTooLarge,
        read_server_frame(&reader, allocator, 3),
    );
}

test "close payload encode and parse" {
    const allocator = std.testing.allocator;

    const encoded = try make_close_payload(allocator, .{ .code = 1000, .reason = "bye" });
    defer allocator.free(encoded);

    const parsed = try parse_close_payload(encoded);
    try std.testing.expectEqual(@as(?u16, 1000), parsed.code);
    try std.testing.expectEqualStrings("bye", parsed.reason);
}

test "parse close payload validates structure and UTF-8" {
    try std.testing.expectError(error.InvalidClosePayload, parse_close_payload(&.{0x03}));

    try std.testing.expectError(
        error.InvalidCloseCode,
        parse_close_payload(&.{ 0x03, 0xED }),
    );

    try std.testing.expectError(
        error.InvalidUtf8Payload,
        parse_close_payload(&.{ 0x03, 0xE8, 0xFF }),
    );

    const empty = try parse_close_payload(&.{});
    try std.testing.expectEqual(@as(?u16, null), empty.code);
    try std.testing.expectEqualStrings("", empty.reason);
}

test "make close payload validates code reason and size" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidCloseCode,
        make_close_payload(allocator, .{ .code = 1005, .reason = "" }),
    );

    var long_reason: [124]u8 = undefined;
    @memset(&long_reason, 'a');
    try std.testing.expectError(
        error.CloseReasonTooLarge,
        make_close_payload(allocator, .{ .code = 1000, .reason = long_reason[0..] }),
    );

    try std.testing.expectError(
        error.InvalidUtf8Payload,
        make_close_payload(allocator, .{ .code = 1000, .reason = &.{0xFF} }),
    );
}

test "prepare send supports json payload" {
    const allocator = std.testing.allocator;

    var ws: Self = undefined;
    try ws.init(allocator);
    defer ws.deinit();

    var prepared = try ws.prepare_send(.{
        .json = .{ .event = "ping", .ok = true },
    });
    defer prepared.deinit(allocator);

    try std.testing.expect(prepared.opcode == .text);
    try std.testing.expectEqualStrings("{\"event\":\"ping\",\"ok\":true}", prepared.payload);
}

test "prepare send supports text binary and close defaults" {
    const allocator = std.testing.allocator;

    var ws: Self = undefined;
    try ws.init(allocator);
    defer ws.deinit();

    var text = try ws.prepare_send(.{ .text = "hello" });
    defer text.deinit(allocator);
    try std.testing.expect(text.opcode == .text);
    try std.testing.expectEqualStrings("hello", text.payload);

    var binary = try ws.prepare_send(.{ .binary = "bin" });
    defer binary.deinit(allocator);
    try std.testing.expect(binary.opcode == .binary);
    try std.testing.expectEqualStrings("bin", binary.payload);

    var close = try ws.prepare_send(.{ .close = .{} });
    defer close.deinit(allocator);
    try std.testing.expect(close.opcode == .close);
    try std.testing.expectEqual(@as(usize, 2), close.payload.len);
    try std.testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, close.payload[0..2], .big));
}

test "prepare send rejects multiple payload kinds" {
    const allocator = std.testing.allocator;

    var ws: Self = undefined;
    try ws.init(allocator);
    defer ws.deinit();

    try std.testing.expectError(
        error.MultipleSendKinds,
        ws.prepare_send(.{
            .text = "a",
            .binary = "b",
        }),
    );

    try std.testing.expectError(
        error.EmptySend,
        ws.prepare_send(.{}),
    );

    var oversized_ping: [126]u8 = undefined;
    @memset(&oversized_ping, 'x');
    try std.testing.expectError(
        error.ControlFrameTooLarge,
        ws.prepare_send(.{
            .ping = oversized_ping[0..],
        }),
    );
}

test "caller headers cannot override websocket handshake headers" {
    try std.testing.expectError(
        error.ForbiddenHeaderOverride,
        validate_caller_headers(&.{.{ .name = "connection", .value = "close" }}),
    );

    try validate_caller_headers(&.{.{ .name = "accept-language", .value = "pt-BR" }});
}

test "prepare connect url builds query and keeps fragment" {
    const allocator = std.testing.allocator;

    var ws: Self = undefined;
    try ws.init(allocator);
    defer ws.deinit();

    var prepared_url = try ws.prepare_connect_url(.{
        .url = "wss://example.com/socket#frag",
        .query = .{ .room = "alpha beta", .page = 2 },
    });
    defer prepared_url.deinit(allocator);

    try std.testing.expectEqualStrings(
        "wss://example.com/socket?room=alpha%20beta&page=2#frag",
        prepared_url.value,
    );
}

test "connect limits validate message and handshake bounds" {
    const limits = try parse_connect_limits(.{
        .url = "wss://example.com/socket",
        .max_message_bytes = 2048,
        .max_handshake_bytes = 4096,
        .auto_pong = false,
    });

    try std.testing.expectEqual(@as(usize, 2048), limits.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 4096), limits.max_handshake_bytes);
    try std.testing.expect(!limits.auto_pong);

    try std.testing.expectError(
        error.InvalidMessageLimit,
        parse_connect_limits(.{
            .url = "wss://example.com/socket",
            .max_message_bytes = 0,
        }),
    );

    try std.testing.expectError(
        error.InvalidHandshakeLimit,
        parse_connect_limits(.{
            .url = "wss://example.com/socket",
            .max_handshake_bytes = 0,
        }),
    );
}

test "message json helper" {
    const allocator = std.testing.allocator;

    var message: Message = .{
        .allocator = allocator,
        .kind = .text,
        .data = try allocator.dupe(u8, "{\"id\":7}"),
    };
    defer message.deinit();

    const Parsed = struct { id: u8 };
    var parsed = try message.json(Parsed);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u8, 7), parsed.value.id);
}

test "server frame writer helper supports continuation frames" {
    const allocator = std.testing.allocator;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try write_server_frame_for_test(&out.writer, .text, "hel", false);
    try write_server_frame_for_test(&out.writer, .continuation, "lo", true);

    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);

    var first = try read_server_frame(&reader, allocator, 128);
    defer first.deinit(allocator);
    try std.testing.expect(!first.fin);
    try std.testing.expect(first.opcode == .text);
    try std.testing.expectEqualStrings("hel", first.payload);

    var second = try read_server_frame(&reader, allocator, 128);
    defer second.deinit(allocator);
    try std.testing.expect(second.fin);
    try std.testing.expect(second.opcode == .continuation);
    try std.testing.expectEqualStrings("lo", second.payload);
}

test "server frame writer helper rejects oversized control frames" {
    const allocator = std.testing.allocator;

    var payload: [126]u8 = undefined;
    @memset(&payload, 0);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try std.testing.expectError(
        error.ControlFrameTooLarge,
        write_server_frame_for_test(&out.writer, .ping, payload[0..], true),
    );
}

test "append with limit enforces total size" {
    const allocator = std.testing.allocator;

    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();

    try append_with_limit(&list, "1234", 5);
    try std.testing.expectEqual(@as(usize, 4), list.items.len);

    try std.testing.expectError(
        error.MessageTooLarge,
        append_with_limit(&list, "67", 5),
    );
}

test "real websocket echo roundtrip (opt-in)" {
    const allocator = std.testing.allocator;
    if (!should_run_real_ws_tests(allocator)) return;

    var ws: Self = undefined;
    try ws.init(allocator);
    defer ws.deinit();

    ws.connect(
        .url("wss://echo.websocket.events"),
        .headers(.{}),
        .{ .max_message_bytes = 1024 * 1024 },
    ) catch |err| {
        if (err == error.UnknownHostName or
            err == error.TemporaryNameServerFailure or
            err == error.NameServerFailure or
            err == error.HostLacksNetworkAddresses or
            err == error.ConnectionTimedOut or
            err == error.UnexpectedConnectFailure or
            err == error.Unexpected)
        {
            return;
        }
        return err;
    };

    try ws.send(.text("hello-websocket"));
    var message = try ws.read();
    defer message.deinit();

    try std.testing.expect(message.kind == .text);
    try std.testing.expectEqualStrings("hello-websocket", message.data);

    try ws.send(.close(.{}));
}
