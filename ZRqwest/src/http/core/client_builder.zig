const std = @import("std");
const request_mod = @import("request.zig");

pub const ClientBuilder = struct {
    allocator: std.mem.Allocator,
    default_request_options: request_mod.DefaultRequestOptions = .{},
    cookies_enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) ClientBuilder {
        return .{ .allocator = allocator };
    }

    pub fn set_keep_alive(self: *ClientBuilder, enabled: bool) void {
        self.default_request_options.keep_alive = enabled;
    }

    pub fn set_timeout_ms(self: *ClientBuilder, timeout_ms_or_null: ?u64) void {
        self.default_request_options.timeout_ms = timeout_ms_or_null;
    }

    pub fn retries(self: *ClientBuilder, retries_count: u8) void {
        self.default_request_options.retries = retries_count;
    }

    pub fn set_retry_backoff_ms(self: *ClientBuilder, backoff_ms: u64) void {
        self.default_request_options.retry_backoff_ms = backoff_ms;
    }

    pub fn set_retry_max_backoff_ms(self: *ClientBuilder, max_backoff_ms: u64) void {
        self.default_request_options.retry_max_backoff_ms = max_backoff_ms;
    }

    pub fn set_redirect_policy(self: *ClientBuilder, policy: request_mod.RedirectPolicy) void {
        self.default_request_options.redirect_policy = policy;
    }

    pub fn set_max_redirects(self: *ClientBuilder, redirect_count_max: u16) void {
        self.default_request_options.max_redirects = redirect_count_max;
    }

    pub fn enable_cookies(self: *ClientBuilder) void {
        self.cookies_enabled = true;
    }

    pub fn disable_cookies(self: *ClientBuilder) void {
        self.cookies_enabled = false;
    }

    pub fn build(self: ClientBuilder) !request_mod {
        var client: request_mod = undefined;
        try client.init(self.allocator);
        client.set_default_request_options(self.default_request_options);
        if (self.cookies_enabled) try client.enable_cookies();
        return client;
    }
};

test "client builder applies request defaults" {
    const allocator = std.testing.allocator;

    var builder = ClientBuilder.init(allocator);
    builder.set_keep_alive(false);
    builder.set_timeout_ms(2200);
    builder.retries(3);
    builder.set_retry_backoff_ms(200);
    builder.set_retry_max_backoff_ms(2000);
    builder.set_redirect_policy(.manual);
    builder.set_max_redirects(7);

    var client = try builder.build();
    defer client.deinit();

    const options = client.default_request_options();
    try std.testing.expect(!options.keep_alive);
    try std.testing.expectEqual(@as(?u64, 2200), options.timeout_ms);
    try std.testing.expectEqual(@as(u8, 3), options.retries);
    try std.testing.expectEqual(@as(u64, 200), options.retry_backoff_ms);
    try std.testing.expectEqual(@as(u64, 2000), options.retry_max_backoff_ms);
    try std.testing.expectEqual(request_mod.RedirectPolicy.manual, options.redirect_policy);
    try std.testing.expectEqual(@as(u16, 7), options.max_redirects);
}

test "client builder enables cookie jar" {
    const allocator = std.testing.allocator;

    var builder = ClientBuilder.init(allocator);
    builder.enable_cookies();

    var client = try builder.build();
    defer client.deinit();

    try std.testing.expect(client.cookie_jar != null);
}
