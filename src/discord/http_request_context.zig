const std = @import("std");
const HeaderSet = @import("http_headers.zig").HeaderSet;
const RequestUrl = @import("request_url.zig").RequestUrl;

url: []const u8,
headers: HeaderSet,

pub const url_bytes_max: usize = RequestUrl.bytes_max;
pub const Error = RequestUrl.Error;

pub const init_params = struct {
    base_url: []const u8,
    auth_header_value: []const u8,
    user_agent_header_value: []const u8,
    url_buffer: []u8,
    path: []const u8,
};

pub const HttpRequestContext = @This();

pub fn init(target: *HttpRequestContext, params: init_params) Error!void {
    var request_url: RequestUrl = undefined;
    request_url.init(.{
        .base_url = params.base_url,
        .buffer = params.url_buffer,
    });

    var headers: HeaderSet = undefined;
    headers.init(.{
        .auth_header_value = params.auth_header_value,
        .user_agent_header_value = params.user_agent_header_value,
    });

    target.* = .{
        .url = try request_url.resolve(params.path),
        .headers = headers,
    };
}

test "HttpRequestContext resolves url and authorized headers" {
    var url_buffer: [url_bytes_max]u8 = undefined;
    var context: HttpRequestContext = undefined;

    try context.init(.{
        .base_url = "https://discord.com/api/v10",
        .auth_header_value = "Bot token",
        .user_agent_header_value = "ZCord",
        .url_buffer = url_buffer[0..],
        .path = "/users/@me",
    });

    const headers = context.headers.authorized();

    try std.testing.expectEqualStrings(
        "https://discord.com/api/v10/users/@me",
        context.url,
    );
    try std.testing.expectEqualStrings("authorization", headers[0].name);
    try std.testing.expectEqualStrings("Bot token", headers[0].value);
    try std.testing.expectEqualStrings("user-agent", headers[1].name);
    try std.testing.expectEqualStrings("ZCord", headers[1].value);
}

test "HttpRequestContext rejects invalid route path" {
    var url_buffer: [url_bytes_max]u8 = undefined;
    var context: HttpRequestContext = undefined;

    try std.testing.expectError(
        error.InvalidRoutePath,
        context.init(.{
            .base_url = "https://discord.com/api/v10",
            .auth_header_value = "Bot token",
            .user_agent_header_value = "ZCord",
            .url_buffer = url_buffer[0..],
            .path = "users/@me",
        }),
    );
}
