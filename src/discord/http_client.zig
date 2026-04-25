const std = @import("std");
const zrqwest = @import("zrqwest");
const AuthorizationHeader = @import("authorization_header.zig").AuthorizationHeader;
const BaseUrl = @import("base_url.zig").BaseUrl;
const DiscordConfig = @import("config.zig").DiscordConfig;
const HttpRequestContext = @import("http_request_context.zig").HttpRequestContext;
const JsonBody = @import("json_body.zig").JsonBody;
const ResponseBodyGuard = @import("response_body_guard.zig").ResponseBodyGuard;
const UserAgentHeader = @import("user_agent_header.zig").UserAgentHeader;

allocator: std.mem.Allocator,
inner: *zrqwest.RequestClient,
base_url: BaseUrl,
response_body_bytes_max: u32,
authorization_header: AuthorizationHeader,
user_agent_header: UserAgentHeader,

pub const DiscordHttpClient = @This();
const Self = @This();

pub const init_params = struct {
    allocator: std.mem.Allocator,
    client: *zrqwest.RequestClient,
    config: DiscordConfig,
};

pub fn init(
    self: *Self,
    params: init_params,
) !void {
    const allocator = params.allocator;
    const config = params.config;
    const config_normalized = config.normalized();
    try config_normalized.validate();

    var base_url: BaseUrl = undefined;
    try base_url.init(allocator, config_normalized.base_url);
    errdefer base_url.deinit();

    var authorization_header: AuthorizationHeader = undefined;
    try authorization_header.init(
        allocator,
        config_normalized.token_prefix,
        config_normalized.token,
    );
    errdefer authorization_header.deinit();

    var user_agent_header: UserAgentHeader = undefined;
    try user_agent_header.init(allocator, config_normalized.user_agent);
    errdefer user_agent_header.deinit();

    self.* = .{
        .allocator = allocator,
        .inner = params.client,
        .base_url = base_url,
        .response_body_bytes_max = config_normalized.response_body_bytes_max,
        .authorization_header = authorization_header,
        .user_agent_header = user_agent_header,
    };
}

pub fn deinit(self: *Self) void {
    self.base_url.deinit();
    self.authorization_header.deinit();
    self.user_agent_header.deinit();
    self.* = undefined;
}

pub fn get(
    self: *Self,
    path: []const u8,
) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    const response = try self.inner.get(
        .url(request.url),
        .headers(request.headers.authorized()),
        .{},
    ).await();

    return self.enforce_response_body(response);
}

pub fn post(
    self: *Self,
    path: []const u8,
    comptime Payload: type,
    payload: Payload,
) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    var body: JsonBody = undefined;
    try body.init(self.allocator, Payload, payload);
    defer body.deinit();

    const response = try self.inner.post(
        .url(request.url),
        .headers(request.headers.authorized_json()),
        .{ .body = body.slice() },
    ).await();

    return self.enforce_response_body(response);
}

pub fn post_no_auth(
    self: *Self,
    path: []const u8,
    comptime Payload: type,
    payload: Payload,
) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    var body: JsonBody = undefined;
    try body.init(self.allocator, Payload, payload);
    defer body.deinit();

    const response = try self.inner.post(
        .url(request.url),
        .headers(request.headers.public_json()),
        .{ .body = body.slice(), .keep_alive = false },
    ).await();

    return self.enforce_response_body(response);
}

pub fn put(
    self: *Self,
    path: []const u8,
    comptime Payload: type,
    payload: Payload,
) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    var body: JsonBody = undefined;
    try body.init(self.allocator, Payload, payload);
    defer body.deinit();

    const response = try self.inner.put(
        .url(request.url),
        .headers(request.headers.authorized_json()),
        .{ .body = body.slice() },
    ).await();

    return self.enforce_response_body(response);
}

pub fn put_empty(self: *Self, path: []const u8) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    const response = try self.inner.put(
        .url(request.url),
        .headers(request.headers.authorized()),
        .{ .body = "", .keep_alive = false },
    ).await();

    return self.enforce_response_body(response);
}

pub fn patch(
    self: *Self,
    path: []const u8,
    comptime Payload: type,
    payload: Payload,
) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    var body: JsonBody = undefined;
    try body.init(self.allocator, Payload, payload);
    defer body.deinit();

    const response = try self.inner.patch(
        .url(request.url),
        .headers(request.headers.authorized_json()),
        .{ .body = body.slice() },
    ).await();

    return self.enforce_response_body(response);
}

pub fn delete(
    self: *Self,
    path: []const u8,
) !zrqwest.Response {
    var url_buffer: [HttpRequestContext.url_bytes_max]u8 = undefined;
    var request: HttpRequestContext = undefined;
    try self.init_request_context(&request, url_buffer[0..], path);

    const response = try self.inner.delete(
        .url(request.url),
        .headers(request.headers.authorized()),
        .{ .keep_alive = false },
    ).await();

    return self.enforce_response_body(response);
}

fn enforce_response_body(
    self: *const Self,
    response: zrqwest.Response,
) ResponseBodyGuard.Error!zrqwest.Response {
    var guard: ResponseBodyGuard = undefined;
    guard.init(self.response_body_bytes_max);
    return guard.enforce(response);
}

fn init_request_context(
    self: *const Self,
    target: *HttpRequestContext,
    url_buffer: []u8,
    path: []const u8,
) HttpRequestContext.Error!void {
    try target.init(.{
        .base_url = self.base_url.slice(),
        .auth_header_value = self.authorization_header.slice(),
        .user_agent_header_value = self.user_agent_header.slice(),
        .url_buffer = url_buffer,
        .path = path,
    });
}

test "DiscordHttpClient exposes path-based verb methods" {
    try std.testing.expect(@hasDecl(DiscordHttpClient, "get"));
    try std.testing.expect(@hasDecl(DiscordHttpClient, "post"));
    try std.testing.expect(@hasDecl(DiscordHttpClient, "put"));
    try std.testing.expect(@hasDecl(DiscordHttpClient, "patch"));
    try std.testing.expect(@hasDecl(DiscordHttpClient, "delete"));
}

test "DiscordHttpClient.init owns normalized base URL" {
    // ARRANGE
    const allocator = std.testing.allocator;
    const base_url = try allocator.dupe(u8, " https://discord.com/api/v10 ");
    var transport: zrqwest.RequestClient = undefined;
    try transport.init(allocator);
    defer transport.deinit();

    var client: DiscordHttpClient = undefined;
    try client.init(.{
        .allocator = allocator,
        .client = &transport,
        .config = .{
            .base_url = base_url,
            .token = "abc",
        },
    });
    defer client.deinit();

    allocator.free(base_url);

    // ASSERT
    try std.testing.expectEqualStrings(
        "https://discord.com/api/v10",
        client.base_url.slice(),
    );
}
