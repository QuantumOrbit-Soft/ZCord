const std = @import("std");

pub const bytes_max: usize = 2048;

base_url: []const u8,
buffer: []u8,

pub const Error = error{
    EmptyBaseUrl,
    InvalidRoutePath,
    UrlTooLong,
};

pub const init_params = struct {
    base_url: []const u8,
    buffer: []u8,
};

pub const RequestUrl = @This();

pub fn init(target: *RequestUrl, params: init_params) void {
    target.* = .{
        .base_url = params.base_url,
        .buffer = params.buffer,
    };
}

pub fn resolve(self: *RequestUrl, path: []const u8) Error![]const u8 {
    if (0 < self.base_url.len) {} else return error.EmptyBaseUrl;
    if (0 < path.len) {} else return error.InvalidRoutePath;
    if (path[0] == '/') {} else return error.InvalidRoutePath;

    const path_part = self.path_without_duplicate_slash(path);
    const total_len = self.base_url.len + path_part.len;

    if (total_len <= self.buffer.len) {} else return error.UrlTooLong;

    std.mem.copyForwards(u8, self.buffer[0..self.base_url.len], self.base_url);
    std.mem.copyForwards(u8, self.buffer[self.base_url.len..total_len], path_part);
    return self.buffer[0..total_len];
}

fn path_without_duplicate_slash(self: *const RequestUrl, path: []const u8) []const u8 {
    std.debug.assert(0 < self.base_url.len);
    std.debug.assert(0 < path.len);

    const base_has_trailing_slash = self.base_url[self.base_url.len - 1] == '/';
    const skip_path_slash: usize = if (base_has_trailing_slash) 1 else 0;
    return path[skip_path_slash..];
}

test "RequestUrl resolves base URL and route path with bounded buffer" {
    var url_buffer: [bytes_max]u8 = undefined;
    var request_url: RequestUrl = undefined;
    request_url.init(.{
        .base_url = "https://discord.com/api/v10",
        .buffer = url_buffer[0..],
    });

    const url = try request_url.resolve("/users/@me");

    try std.testing.expectEqualStrings(
        "https://discord.com/api/v10/users/@me",
        url,
    );
}

test "RequestUrl rejects route without leading slash" {
    var url_buffer: [bytes_max]u8 = undefined;
    var request_url: RequestUrl = undefined;
    request_url.init(.{
        .base_url = "https://discord.com/api/v10",
        .buffer = url_buffer[0..],
    });

    try std.testing.expectError(error.InvalidRoutePath, request_url.resolve("users/@me"));
}

test "RequestUrl handles base URL with trailing slash" {
    var url_buffer: [bytes_max]u8 = undefined;
    var request_url: RequestUrl = undefined;
    request_url.init(.{
        .base_url = "https://discord.com/api/v10/",
        .buffer = url_buffer[0..],
    });

    const url = try request_url.resolve("/users/@me");

    try std.testing.expectEqualStrings(
        "https://discord.com/api/v10/users/@me",
        url,
    );
}

test "RequestUrl rejects overlong URL" {
    var url_buffer: [bytes_max]u8 = undefined;
    var long_path_storage: [bytes_max]u8 = undefined;
    long_path_storage[0] = '/';
    @memset(long_path_storage[1..], 'a');

    var request_url: RequestUrl = undefined;
    request_url.init(.{
        .base_url = "https://discord.com/api/v10",
        .buffer = url_buffer[0..],
    });

    try std.testing.expectError(
        error.UrlTooLong,
        request_url.resolve(long_path_storage[0..]),
    );
}
