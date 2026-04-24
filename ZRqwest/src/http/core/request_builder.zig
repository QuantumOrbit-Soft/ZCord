const std = @import("std");
const query_builder = @import("query_builder.zig");
const request_mod = @import("request.zig");
const scratch = @import("scratch.zig");
const multipart_mod = @import("multipart.zig");

const empty_headers: []const std.http.Header = &.{};

pub const RequestBuilder = struct {
    pub const max_headers: u8 = 32;

    client: *request_mod,
    method: std.http.Method,
    url: []const u8,
    owned_url: ?[]u8 = null,
    body_value: ?[]const u8 = null,
    owned_body: ?[]u8 = null,
    owned_content_type: ?[]u8 = null,
    headers: [max_headers]std.http.Header = undefined,
    headers_count: u8 = 0,
    keep_alive: bool,
    timeout_ms: ?u64,
    retries_count: u8,
    retry_backoff_ms: u64,
    retry_max_backoff_ms: u64,
    redirect_policy: request_mod.RedirectPolicy,
    max_redirects: u16,

    pub fn init(client: *request_mod, method: std.http.Method, url: []const u8) RequestBuilder {
        const defaults = client.default_request_options();
        return .{
            .client = client,
            .method = method,
            .url = url,
            .keep_alive = defaults.keep_alive,
            .timeout_ms = defaults.timeout_ms,
            .retries_count = defaults.retries,
            .retry_backoff_ms = defaults.retry_backoff_ms,
            .retry_max_backoff_ms = defaults.retry_max_backoff_ms,
            .redirect_policy = defaults.redirect_policy,
            .max_redirects = defaults.max_redirects,
        };
    }

    pub fn deinit(self: *RequestBuilder) void {
        self.free_owned_url();
        self.free_owned_body();
        self.free_owned_content_type();
        self.* = undefined;
    }

    pub fn set_keep_alive(self: *RequestBuilder, enabled: bool) void {
        self.keep_alive = enabled;
    }

    pub fn set_timeout_ms(self: *RequestBuilder, timeout_ms_or_null: ?u64) void {
        self.timeout_ms = timeout_ms_or_null;
    }

    pub fn retries(self: *RequestBuilder, retries_count: u8) void {
        self.retries_count = retries_count;
    }

    pub fn set_retry_backoff_ms(self: *RequestBuilder, backoff_ms: u64) void {
        self.retry_backoff_ms = backoff_ms;
    }

    pub fn set_retry_max_backoff_ms(self: *RequestBuilder, max_backoff_ms: u64) void {
        self.retry_max_backoff_ms = max_backoff_ms;
    }

    pub fn set_redirect_policy(self: *RequestBuilder, policy: request_mod.RedirectPolicy) void {
        self.redirect_policy = policy;
    }

    pub fn set_max_redirects(self: *RequestBuilder, redirect_count_max: u16) void {
        self.max_redirects = redirect_count_max;
    }

    pub fn header(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.headers_count <= max_headers);
        if (self.headers_count >= max_headers) return error.TooManyHeaders;

        const index: usize = self.headers_count;
        self.headers[index] = .{ .name = name, .value = value };
        self.headers_count += 1;
    }

    pub fn query(self: *RequestBuilder, query_values: anytype) !void {
        const built_url = try query_builder.build(self.client.allocator, self.url, query_values);
        self.free_owned_url();
        self.url = built_url;
        self.owned_url = built_url;
    }

    pub fn body(self: *RequestBuilder, body_value: []const u8) void {
        self.free_owned_body();
        self.body_value = body_value;
    }

    pub fn json(self: *RequestBuilder, payload: anytype) !void {
        try ensure_method_supports_body(self.method);

        const encoded = try scratch.json(self.client.allocator, payload);
        self.replace_owned_body(encoded);
        try self.set_content_type("application/json", null);
    }

    pub fn form(self: *RequestBuilder, payload: anytype) !void {
        try ensure_method_supports_body(self.method);

        const encoded = try scratch.post_form(self.client.allocator, payload);
        self.replace_owned_body(encoded);
        try self.set_content_type("application/x-www-form-urlencoded", null);
    }

    pub fn multipart(self: *RequestBuilder, parts: []const multipart_mod.Part) !void {
        try ensure_method_supports_body(self.method);

        var boundary_buf: [32]u8 = undefined;
        const boundary = multipart_mod.generate_boundary(&boundary_buf);

        const encoded = try multipart_mod.build(self.client.allocator, parts, boundary);
        errdefer self.client.allocator.free(encoded);

        const content_type = try std.fmt.allocPrint(
            self.client.allocator,
            "multipart/form-data; boundary={s}",
            .{boundary},
        );
        errdefer self.client.allocator.free(content_type);

        try self.set_content_type(content_type, content_type);
        self.replace_owned_body(encoded);
    }

    pub fn send(self: *RequestBuilder) !request_mod.Response {
        try ensure_method_supported(self.method);
        return self.client.send_now(
            self.method,
            .url(self.url),
            request_mod.HeadersArg.headers(self.header_slice()),
            self.make_options(),
        );
    }

    pub fn send_json(
        self: *RequestBuilder,
        comptime ResponseType: type,
    ) !std.json.Parsed(ResponseType) {
        try ensure_method_supported(self.method);
        return self.client.send_now(
            self.method,
            .url(self.url),
            request_mod.HeadersArg.headers(self.header_slice()),
            self.make_typed_options(ResponseType),
        );
    }

    fn make_options(self: *const RequestBuilder) Options {
        return .{
            .body = self.body_value,
            .keep_alive = self.keep_alive,
            .timeout_ms = self.timeout_ms,
            .retries = self.retries_count,
            .retry_backoff_ms = self.retry_backoff_ms,
            .retry_max_backoff_ms = self.retry_max_backoff_ms,
            .redirect_policy = self.redirect_policy,
            .max_redirects = self.max_redirects,
        };
    }

    fn make_typed_options(
        self: *const RequestBuilder,
        comptime ResponseType: type,
    ) typed_options(ResponseType) {
        return .{
            .body = self.body_value,
            .keep_alive = self.keep_alive,
            .timeout_ms = self.timeout_ms,
            .retries = self.retries_count,
            .retry_backoff_ms = self.retry_backoff_ms,
            .retry_max_backoff_ms = self.retry_max_backoff_ms,
            .redirect_policy = self.redirect_policy,
            .max_redirects = self.max_redirects,
            .resp = ResponseType,
        };
    }

    fn header_slice(self: *const RequestBuilder) []const std.http.Header {
        std.debug.assert(self.headers_count <= max_headers);
        if (self.headers_count == 0) return empty_headers;

        const count: usize = self.headers_count;
        return self.headers[0..count];
    }

    fn set_content_type(
        self: *RequestBuilder,
        content_type: []const u8,
        owned_content_type: ?[]u8,
    ) !void {
        std.debug.assert(content_type.len > 0);
        self.free_owned_content_type();
        errdefer if (owned_content_type) |owned| self.client.allocator.free(owned);

        if (self.find_content_type_index()) |index| {
            self.headers[index].value = content_type;
            self.owned_content_type = owned_content_type;
            return;
        }

        try self.header("content-type", content_type);
        self.owned_content_type = owned_content_type;
    }

    fn find_content_type_index(self: *const RequestBuilder) ?usize {
        std.debug.assert(self.headers_count <= max_headers);

        var index: usize = 0;
        while (index < self.headers_count) : (index += 1) {
            const name = self.headers[index].name;
            if (std.ascii.eqlIgnoreCase(name, "content-type")) return index;
        }

        return null;
    }

    fn replace_owned_body(self: *RequestBuilder, encoded: []u8) void {
        self.free_owned_body();
        self.owned_body = encoded;
        self.body_value = encoded;
    }

    fn free_owned_url(self: *RequestBuilder) void {
        if (self.owned_url) |owned| {
            self.client.allocator.free(owned);
            self.owned_url = null;
        }
    }

    fn free_owned_body(self: *RequestBuilder) void {
        if (self.owned_body) |owned| {
            self.client.allocator.free(owned);
            self.owned_body = null;
        }
    }

    fn free_owned_content_type(self: *RequestBuilder) void {
        if (self.owned_content_type) |owned| {
            self.client.allocator.free(owned);
            self.owned_content_type = null;
        }
    }
};

comptime {
    std.debug.assert(RequestBuilder.max_headers > 0);
    std.debug.assert(RequestBuilder.max_headers <= std.math.maxInt(u8));
}

fn ensure_method_supports_body(method: std.http.Method) !void {
    if (method.requestHasBody()) return;
    return error.MethodDoesNotSupportBody;
}

fn ensure_method_supported(method: std.http.Method) !void {
    switch (method) {
        .GET, .POST, .PUT, .PATCH, .DELETE => return,
        else => return error.UnsupportedMethod,
    }
}

const Options = struct {
    body: ?[]const u8 = null,
    keep_alive: bool = true,
    timeout_ms: ?u64 = null,
    retries: u8 = 0,
    retry_backoff_ms: u64 = request_mod.default_retry_backoff_ms,
    retry_max_backoff_ms: u64 = request_mod.default_retry_max_backoff_ms,
    redirect_policy: request_mod.RedirectPolicy = .follow,
    max_redirects: u16 = request_mod.default_max_redirects,
};

fn typed_options(comptime ResponseType: type) type {
    return struct {
        body: ?[]const u8 = null,
        keep_alive: bool = true,
        timeout_ms: ?u64 = null,
        retries: u8 = 0,
        retry_backoff_ms: u64 = request_mod.default_retry_backoff_ms,
        retry_max_backoff_ms: u64 = request_mod.default_retry_max_backoff_ms,
        redirect_policy: request_mod.RedirectPolicy = .follow,
        max_redirects: u16 = request_mod.default_max_redirects,
        resp: type = ResponseType,
    };
}

test "request builder starts from client defaults" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    client.set_default_request_options(.{
        .keep_alive = false,
        .timeout_ms = 5000,
        .retries = 4,
        .retry_backoff_ms = 300,
        .retry_max_backoff_ms = 3000,
        .redirect_policy = .manual,
        .max_redirects = 9,
    });

    var builder = RequestBuilder.init(&client, .GET, "https://example.com");
    defer builder.deinit();

    try std.testing.expect(!builder.keep_alive);
    try std.testing.expectEqual(@as(?u64, 5000), builder.timeout_ms);
    try std.testing.expectEqual(@as(u8, 4), builder.retries_count);
    try std.testing.expectEqual(@as(u64, 300), builder.retry_backoff_ms);
    try std.testing.expectEqual(@as(u64, 3000), builder.retry_max_backoff_ms);
    try std.testing.expectEqual(request_mod.RedirectPolicy.manual, builder.redirect_policy);
    try std.testing.expectEqual(@as(u16, 9), builder.max_redirects);
}

test "request builder query keeps fragment and encodes pairs" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .GET, "https://example.com/path#frag");
    defer builder.deinit();

    try builder.query(.{ .name = "zig lang", .page = 2 });
    try std.testing.expectEqualStrings(
        "https://example.com/path?name=zig%20lang&page=2#frag",
        builder.url,
    );
}

test "request builder json sets body and content type" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .POST, "https://example.com/path");
    defer builder.deinit();

    try builder.json(.{ .id = 7 });
    try std.testing.expect(builder.body_value != null);
    try std.testing.expectEqualStrings("{\"id\":7}", builder.body_value.?);

    const headers = builder.header_slice();
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("content-type", headers[0].name);
    try std.testing.expectEqualStrings("application/json", headers[0].value);
}

test "request builder send rejects unsupported method" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .CONNECT, "https://example.com/path");
    defer builder.deinit();

    try std.testing.expectError(error.UnsupportedMethod, builder.send());
}

test "request builder enforces bounded header capacity" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .GET, "https://example.com/path");
    defer builder.deinit();

    var index: u8 = 0;
    while (index < RequestBuilder.max_headers) : (index += 1) {
        try builder.header("x-test", "ok");
    }

    try std.testing.expectError(error.TooManyHeaders, builder.header("x-overflow", "no"));
}

test "request builder multipart sets body and boundary content type" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .POST, "https://example.com/upload");
    defer builder.deinit();

    const parts = [_]multipart_mod.Part{
        .{ .name = "file", .filename = "hello.txt", .content_type = "text/plain", .data = "hello" },
    };
    try builder.multipart(parts[0..]);

    try std.testing.expect(builder.body_value != null);
    try std.testing.expect(std.mem.indexOf(u8, builder.body_value.?, "name=\"file\"") != null);

    const headers = builder.header_slice();
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("content-type", headers[0].name);
    try std.testing.expect(
        std.mem.startsWith(u8, headers[0].value, "multipart/form-data; boundary="),
    );
}

test "request builder can replace multipart body with json body" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .POST, "https://example.com/upload");
    defer builder.deinit();

    const parts = [_]multipart_mod.Part{
        .{ .name = "file", .content_type = "text/plain", .data = "hello" },
    };
    try builder.multipart(parts[0..]);
    try builder.json(.{ .id = 10 });

    try std.testing.expect(builder.body_value != null);
    try std.testing.expectEqualStrings("{\"id\":10}", builder.body_value.?);

    const headers = builder.header_slice();
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("application/json", headers[0].value);
}

test "request builder rejects json for method without body" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .GET, "https://example.com/search");
    defer builder.deinit();

    try std.testing.expectError(
        error.MethodDoesNotSupportBody,
        builder.json(.{ .q = "zig" }),
    );
}

test "request builder rejects multipart for method without body" {
    const allocator = std.testing.allocator;

    var client: request_mod = undefined;
    try client.init(allocator);
    defer client.deinit();

    var builder = RequestBuilder.init(&client, .DELETE, "https://example.com/files");
    defer builder.deinit();

    const parts = [_]multipart_mod.Part{
        .{ .name = "file", .content_type = "text/plain", .data = "hello" },
    };
    try std.testing.expectError(
        error.MethodDoesNotSupportBody,
        builder.multipart(parts[0..]),
    );
}
