const std = @import("std");
const zrqwest = @import("zrqwest");
const DiscordHttpClient = @import("../discord/http_client.zig").DiscordHttpClient;
const DiscordResult = @import("../discord/result.zig").DiscordResult;
const models = @import("../models/mod.zig");
const routes = @import("../routes/mod.zig");
const PercentEncoder = routes.PercentEncoder;
const Routes = routes.Routes;

allocator: std.mem.Allocator,
client: *DiscordHttpClient,

pub const MessagesResource = @This();

pub const Message = models.Message;
pub const create_params = struct {
    channel_id: []const u8,
    content: []const u8,
    embeds: []const models.Embed = &.{},
    components: []const models.ActionRow = &.{},
    tts: bool = false,
    nonce: ?[]const u8 = null,
    reply_to_message_id: ?[]const u8 = null,
    mention_replied_user: bool = false,
};

pub const get_params = struct {
    channel_id: []const u8,
    message_id: []const u8,
};

pub const edit_params = struct {
    channel_id: []const u8,
    message_id: []const u8,
    content: ?[]const u8 = null,
};

pub const delete_params = struct {
    channel_id: []const u8,
    message_id: []const u8,
};

pub const reply_params = struct {
    channel_id: []const u8,
    message_id: []const u8,
    content: []const u8,
    embeds: []const models.Embed = &.{},
    components: []const models.ActionRow = &.{},
    tts: bool = false,
    nonce: ?[]const u8 = null,
    mention_replied_user: bool = false,
};

pub const reaction_params = struct {
    channel_id: []const u8,
    message_id: []const u8,
    emoji: []const u8,
};

pub const create_payload = struct {
    content: []const u8,
    embeds: []const models.Embed = &.{},
    components: []const models.ActionRow = &.{},
    tts: bool = false,
    nonce: ?[]const u8 = null,
    message_reference: ?message_reference_payload = null,
    allowed_mentions: ?allowed_mentions_payload = null,
};

pub const edit_payload = struct {
    content: ?[]const u8 = null,
};

const message_reference_payload = struct {
    message_id: []const u8,
    channel_id: []const u8,
};

const allowed_mentions_payload = struct {
    replied_user: bool = false,
};

pub const message_result = DiscordResult.Of(Message);
pub const delete_message_result = DiscordResult.Empty;
pub const reaction_result = DiscordResult.Empty;

pub const payload_validation_error = error{
    EmptyMessageContent,
    EmptyEditPayload,
};

const Self = @This();
const route_path_bytes_max: usize = 256;
const encoded_route_param_bytes_max: usize = 512;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    client: *DiscordHttpClient,
) void {
    self.* = .{ .allocator = allocator, .client = client };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn create(
    self: *Self,
    params: create_params,
) !message_result {
    try Self.validate_create_params(params);
    const response = try self.create_response(params);
    return self.message_result_from_response(response);
}

pub fn get(self: *Self, params: get_params) !message_result {
    const response = try self.get_response(params);
    return self.message_result_from_response(response);
}

pub fn edit(
    self: *Self,
    params: edit_params,
) !message_result {
    try Self.validate_edit_params(params);
    const response = try self.edit_response(params);
    return self.message_result_from_response(response);
}

pub fn delete(self: *Self, params: delete_params) !delete_message_result {
    const response = try self.delete_response(params);
    return self.delete_result_from_response(response);
}

pub fn reply(self: *Self, params: reply_params) !message_result {
    return self.create(.{
        .channel_id = params.channel_id,
        .content = params.content,
        .embeds = params.embeds,
        .components = params.components,
        .tts = params.tts,
        .nonce = params.nonce,
        .reply_to_message_id = params.message_id,
        .mention_replied_user = params.mention_replied_user,
    });
}

pub fn add_reaction(self: *Self, params: reaction_params) !reaction_result {
    const response = try self.add_reaction_response(params);
    return self.reaction_result_from_response(response);
}

pub fn remove_own_reaction(self: *Self, params: reaction_params) !reaction_result {
    const response = try self.remove_own_reaction_response(params);
    return self.reaction_result_from_response(response);
}

fn create_response(
    self: *Self,
    params: create_params,
) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Self.messages_index_path(path_buffer[0..], params.channel_id);
    return self.client.post(path, create_payload, .{
        .content = params.content,
        .embeds = params.embeds,
        .components = params.components,
        .tts = params.tts,
        .nonce = params.nonce,
        .message_reference = Self.message_reference_from_params(params),
        .allowed_mentions = Self.allowed_mentions_from_params(params),
    });
}

fn get_response(self: *Self, params: get_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Self.messages_item_path(
        path_buffer[0..],
        params.channel_id,
        params.message_id,
    );
    return self.client.get(path);
}

fn edit_response(
    self: *Self,
    params: edit_params,
) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Self.messages_item_path(
        path_buffer[0..],
        params.channel_id,
        params.message_id,
    );
    return self.client.patch(path, edit_payload, .{ .content = params.content });
}

fn delete_response(self: *Self, params: delete_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Self.messages_item_path(
        path_buffer[0..],
        params.channel_id,
        params.message_id,
    );
    return self.client.delete(path);
}

fn add_reaction_response(self: *Self, params: reaction_params) !zrqwest.Response {
    var encoded_buffer: [encoded_route_param_bytes_max]u8 = undefined;
    var encoder: PercentEncoder = undefined;
    encoder.init(encoded_buffer[0..]);
    const encoded = try encoder.encode(params.emoji);

    var path_buffer: [route_path_bytes_max * 2]u8 = undefined;
    const path = try Routes.messages.reaction_me(
        path_buffer[0..],
        params.channel_id,
        params.message_id,
        encoded,
    );
    return self.client.put_empty(path);
}

fn remove_own_reaction_response(self: *Self, params: reaction_params) !zrqwest.Response {
    var encoded_buffer: [encoded_route_param_bytes_max]u8 = undefined;
    var encoder: PercentEncoder = undefined;
    encoder.init(encoded_buffer[0..]);
    const encoded = try encoder.encode(params.emoji);

    var path_buffer: [route_path_bytes_max * 2]u8 = undefined;
    const path = try Routes.messages.reaction_me(
        path_buffer[0..],
        params.channel_id,
        params.message_id,
        encoded,
    );
    return self.client.delete(path);
}

fn messages_index_path(path_buffer: []u8, channel_id: []const u8) ![]const u8 {
    return Routes.messages.index(path_buffer, channel_id);
}

fn messages_item_path(
    path_buffer: []u8,
    channel_id: []const u8,
    message_id: []const u8,
) ![]const u8 {
    return Routes.messages.get(path_buffer, channel_id, message_id);
}

fn validate_create_params(params: create_params) payload_validation_error!void {
    if (0 < params.content.len) {} else return error.EmptyMessageContent;
}

fn validate_edit_params(params: edit_params) payload_validation_error!void {
    if (params.content) |_| {} else return error.EmptyEditPayload;
}

fn message_result_from_response(self: *Self, response: zrqwest.Response) !message_result {
    return message_result.from_zrqwest_response(self.allocator, response);
}

fn delete_result_from_response(
    self: *Self,
    response: zrqwest.Response,
) !delete_message_result {
    return delete_message_result.from_zrqwest_response(self.allocator, response);
}

fn reaction_result_from_response(self: *Self, response: zrqwest.Response) !reaction_result {
    return reaction_result.from_zrqwest_response(self.allocator, response);
}

fn message_reference_from_params(params: create_params) ?message_reference_payload {
    const message_id = params.reply_to_message_id orelse return null;
    return .{
        .message_id = message_id,
        .channel_id = params.channel_id,
    };
}

fn allowed_mentions_from_params(params: create_params) ?allowed_mentions_payload {
    if (params.reply_to_message_id) |_| {
        return .{ .replied_user = params.mention_replied_user };
    }

    return null;
}

test "MessagesResource exposes create/get/edit/delete APIs" {
    try std.testing.expect(@hasDecl(MessagesResource, "create"));
    try std.testing.expect(@hasDecl(MessagesResource, "get"));
    try std.testing.expect(@hasDecl(MessagesResource, "edit"));
    try std.testing.expect(@hasDecl(MessagesResource, "delete"));
    try std.testing.expect(@hasDecl(MessagesResource, "create_params"));
    try std.testing.expect(@hasDecl(MessagesResource, "get_params"));
    try std.testing.expect(@hasDecl(MessagesResource, "edit_params"));
    try std.testing.expect(@hasDecl(MessagesResource, "delete_params"));
    try std.testing.expect(!@hasDecl(MessagesResource, "create_message_params"));
    try std.testing.expect(!@hasDecl(MessagesResource, "get_message_params"));
    try std.testing.expect(!@hasDecl(MessagesResource, "edit_message_params"));
    try std.testing.expect(!@hasDecl(MessagesResource, "delete_message_params"));
    try std.testing.expect(!@hasDecl(MessagesResource, "create_message_payload"));
    try std.testing.expect(!@hasDecl(MessagesResource, "edit_message_payload"));
    try std.testing.expect(@hasDecl(MessagesResource, "delete_message_result"));
}

test "MessagesResource multi-input methods accept params structs" {
    comptime {
        const create_fn: *const fn (
            *MessagesResource,
            create_params,
        ) anyerror!message_result = MessagesResource.create;
        const get_fn: *const fn (
            *MessagesResource,
            get_params,
        ) anyerror!message_result = MessagesResource.get;
        const edit_fn: *const fn (
            *MessagesResource,
            edit_params,
        ) anyerror!message_result = MessagesResource.edit;
        const delete_fn: *const fn (
            *MessagesResource,
            delete_params,
        ) anyerror!delete_message_result = MessagesResource.delete;
        _ = create_fn;
        _ = get_fn;
        _ = edit_fn;
        _ = delete_fn;
    }

    try std.testing.expect(true);
}

test "MessagesResource keeps route assembly and request dispatch in private helpers" {
    try std.testing.expect(@hasDecl(MessagesResource, "messages_index_path"));
    try std.testing.expect(@hasDecl(MessagesResource, "messages_item_path"));
    try std.testing.expect(@hasDecl(MessagesResource, "create_response"));
    try std.testing.expect(@hasDecl(MessagesResource, "get_response"));
    try std.testing.expect(@hasDecl(MessagesResource, "edit_response"));
    try std.testing.expect(@hasDecl(MessagesResource, "delete_response"));
}

test "MessagesResource.create params validation rejects empty content" {
    try std.testing.expectError(
        error.EmptyMessageContent,
        MessagesResource.validate_create_params(.{ .channel_id = "123", .content = "" }),
    );
}

test "MessagesResource.edit params validation rejects no fields" {
    try std.testing.expectError(
        error.EmptyEditPayload,
        MessagesResource.validate_edit_params(.{ .channel_id = "123", .message_id = "999" }),
    );
}

test "MessagesResource params validation accepts valid create and edit payloads" {
    try MessagesResource.validate_create_params(.{ .channel_id = "123", .content = "hello" });
    try MessagesResource.validate_edit_params(.{
        .channel_id = "123",
        .message_id = "999",
        .content = "updated",
    });
}

test "MessagesResource.create fails locally for empty content" {
    const allocator = std.testing.allocator;
    var fake_client: DiscordHttpClient = undefined;
    var messages: MessagesResource = undefined;
    messages.init(allocator, &fake_client);

    try std.testing.expectError(
        error.EmptyMessageContent,
        messages.create(.{ .channel_id = "123", .content = "" }),
    );
}

test "MessagesResource.edit fails locally when no fields are provided" {
    const allocator = std.testing.allocator;
    var fake_client: DiscordHttpClient = undefined;
    var messages: MessagesResource = undefined;
    messages.init(allocator, &fake_client);

    try std.testing.expectError(
        error.EmptyEditPayload,
        messages.edit(.{ .channel_id = "123", .message_id = "999" }),
    );
}

test "MessagesResource routes come from centralized Routes module" {
    var path_buffer: [128]u8 = undefined;

    const index_path = try Routes.messages.index(path_buffer[0..], "123");
    try std.testing.expectEqualStrings("/channels/123/messages", index_path);

    const item_path = try Routes.messages.get(path_buffer[0..], "123", "999");
    try std.testing.expectEqualStrings("/channels/123/messages/999", item_path);
}

test "MessagesResource parses create/get/edit payload with single response owner" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(
        u8,
        "{\"id\":\"999\",\"channel_id\":\"123\",\"content\":\"hello\"}",
    );

    var fake_client: DiscordHttpClient = undefined;
    var messages: MessagesResource = undefined;
    messages.init(allocator, &fake_client);

    var result = try messages.message_result_from_response(.{
        .allocator = allocator,
        .status = .ok,
        .body = body,
    });
    defer result.deinit();

    const message = result.data() orelse unreachable;
    try std.testing.expectEqualStrings("999", message.id);
    try std.testing.expectEqualStrings("123", message.channel_id);
    try std.testing.expectEqualStrings("hello", message.content);
}

test "MessagesResource delete result handles no-content success" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "");

    var fake_client: DiscordHttpClient = undefined;
    var messages: MessagesResource = undefined;
    messages.init(allocator, &fake_client);

    var result = try messages.delete_result_from_response(.{
        .allocator = allocator,
        .status = .no_content,
        .body = body,
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u16, 204), result.status_code);
    try std.testing.expect(result.error_body_or_null == null);
}

test "MessagesResource delete result keeps error body on failures" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "{\"message\":\"Missing Access\"}");

    var fake_client: DiscordHttpClient = undefined;
    var messages: MessagesResource = undefined;
    messages.init(allocator, &fake_client);

    var result = try messages.delete_result_from_response(.{
        .allocator = allocator,
        .status = .forbidden,
        .body = body,
    });
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u16, 403), result.status_code);
    try std.testing.expectEqualStrings(
        "{\"message\":\"Missing Access\"}",
        result.error_body_or_null orelse unreachable,
    );
}
