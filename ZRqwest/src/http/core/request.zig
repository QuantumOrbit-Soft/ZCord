const std = @import("std");
const builtin = @import("builtin");
const content_type_headers = @import("content_type_headers.zig");
const json_printer = @import("json_printer.zig");
const query_builder = @import("query_builder.zig");
const scratch = @import("scratch.zig");
const multipart_mod = @import("multipart.zig");
const cookie_jar_mod = @import("cookie_jar.zig");

const Self = @This();
const empty_headers: []const std.http.Header = &.{};
const empty_body = "";
pub const default_retry_backoff_ms: u64 = 150;
pub const default_retry_max_backoff_ms: u64 = 2_000;
pub const default_max_redirects: u16 = 3;
const async_worker_count: u8 = 4;
const async_queue_capacity: u16 = 256;
const sync_io = std.Options.debug_io;

allocator: std.mem.Allocator = undefined,
http_client: std.http.Client = undefined,
cookie_jar: ?cookie_jar_mod.CookieJar = null,
cached_cookie_header_value: ?[]u8 = null,
cached_cookie_header_version: u64 = 0,
default_request_keep_alive: bool = true,
default_request_timeout_ms: ?u64 = null,
default_request_retries: u8 = 0,
default_request_retry_backoff_ms: u64 = default_retry_backoff_ms,
default_request_retry_max_backoff_ms: u64 = default_retry_max_backoff_ms,
default_request_redirect_policy: RedirectPolicy = .follow,
default_request_max_redirects: u16 = default_max_redirects,
request_execution_mutex: std.Io.Mutex = .init,

pub const RedirectPolicy = enum {
    follow,
    manual,
    fail,
};

const RequestOptions = struct {
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = empty_headers,
    keep_alive: bool = true,
    timeout_ms: ?u64 = null,
    redirect_behavior: std.http.Client.Request.RedirectBehavior =
        std.http.Client.Request.RedirectBehavior.init(default_max_redirects),
};

pub const Senders = struct {
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = empty_headers,
    keep_alive: bool = true,
    payload_kind: scratch.Format = .json,
    timeout_ms: ?u64 = null,
    retries: u8 = 0,
    retry_backoff_ms: u64 = default_retry_backoff_ms,
    retry_max_backoff_ms: u64 = default_retry_max_backoff_ms,
    redirect_policy: RedirectPolicy = .follow,
    max_redirects: u16 = default_max_redirects,
};

pub const DefaultRequestOptions = struct {
    keep_alive: bool = true,
    timeout_ms: ?u64 = null,
    retries: u8 = 0,
    retry_backoff_ms: u64 = default_retry_backoff_ms,
    retry_max_backoff_ms: u64 = default_retry_max_backoff_ms,
    redirect_policy: RedirectPolicy = .follow,
    max_redirects: u16 = default_max_redirects,
};

pub const PayloadKind = scratch.Format;

pub const RequestArg = union(enum) {
    url_value: []const u8,

    pub fn url(input_url: []const u8) RequestArg {
        return .{ .url_value = input_url };
    }

    pub fn url_slice(self: RequestArg) []const u8 {
        return switch (self) {
            .url_value => |request_url| request_url,
        };
    }
};

pub const HeadersArg = struct {
    pub const max_headers: u8 = 32;

    values: [max_headers]std.http.Header = undefined,
    count: u8 = 0,

    pub fn headers(input_headers: anytype) HeadersArg {
        var result: HeadersArg = .{};
        result.append(input_headers);
        return result;
    }

    pub fn slice(self: *const HeadersArg) []const std.http.Header {
        const count: usize = self.count;
        return self.values[0..count];
    }

    fn append(self: *HeadersArg, input: anytype) void {
        switch (@typeInfo(@TypeOf(input))) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    if (pointer.child != std.http.Header) {
                        @compileError("headers precisa receber []const std.http.Header ou um struct anonimo");
                    }
                    self.append_slice(input);
                },
                .one => {
                    const child_info = @typeInfo(pointer.child);
                    if (child_info != .array or child_info.array.child != std.http.Header) {
                        @compileError("headers precisa receber []const std.http.Header ou um struct anonimo");
                    }
                    self.append_slice(input[0..]);
                },
                else => @compileError("headers invalido"),
            },
            .array => |array| {
                if (array.child != std.http.Header) {
                    @compileError("headers precisa receber []const std.http.Header ou um struct anonimo");
                }
                self.append_slice(input[0..]);
            },
            .@"struct" => |info| {
                inline for (info.fields) |field| {
                    const field_value: []const u8 = @field(input, field.name);
                    self.append_header(.{
                        .name = field.name,
                        .value = field_value,
                    });
                }
            },
            else => @compileError("headers precisa receber []const std.http.Header ou um struct anonimo"),
        }
    }

    fn append_slice(self: *HeadersArg, header_slice: []const std.http.Header) void {
        std.debug.assert(header_slice.len <= max_headers);
        if (header_slice.len > max_headers) @panic("headers excede HeadersArg.max_headers");

        for (header_slice) |header| {
            self.append_header(header);
        }
    }

    fn append_header(self: *HeadersArg, header: std.http.Header) void {
        std.debug.assert(self.count < max_headers);
        if (self.count >= max_headers) @panic("headers excede HeadersArg.max_headers");

        const index: usize = self.count;
        self.values[index] = header;
        self.count += 1;
    }
};

pub fn async_task(comptime ResultType: type) type {
    return struct {
        const TaskSelf = @This();

        pub const Shared = struct {
            mutex: std.Io.Mutex = .init,
            done: std.Io.Condition = .init,
            completed: bool = false,
            result: anyerror!ResultType = undefined,

            fn finish(self: *Shared, value: anyerror!ResultType) void {
                self.mutex.lockUncancelable(sync_io);
                defer self.mutex.unlock(sync_io);

                self.result = value;
                self.completed = true;
                self.done.signal(sync_io);
            }
        };

        const Inner = union(enum) {
            running: struct {
                shared: *Shared,
            },
            failed: anyerror,
        };

        inner: Inner,

        pub fn await(self: TaskSelf) anyerror!ResultType {
            switch (self.inner) {
                .running => |r| {
                    r.shared.mutex.lockUncancelable(sync_io);
                    while (!r.shared.completed) {
                        r.shared.done.waitUncancelable(sync_io, &r.shared.mutex);
                    }
                    const result = r.shared.result;
                    r.shared.mutex.unlock(sync_io);

                    std.heap.page_allocator.destroy(r.shared);
                    return result;
                },
                .failed => |err| return err,
            }
        }
    };
}

pub fn return_of(comptime T: type) return_of_marker(T) {
    return .{};
}

fn return_of_marker(comptime T: type) type {
    return struct {
        pub const return_type = T;
    };
}

pub const Response = struct {
    pub const JsonParseError = std.json.ParseError(std.json.Scanner);

    allocator: std.mem.Allocator,
    status: std.http.Status,
    body: []u8,

    pub fn status_code(self: Response) u16 {
        return @intCast(@intFromEnum(self.status));
    }

    pub fn is_success(self: Response) bool {
        const code = self.status_code();
        return code >= 200 and code < 300;
    }

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn json(
        self: Response,
        comptime T: type,
    ) JsonParseError!std.json.Parsed(T) {
        return self.json_with_options(T, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn json_with_options(
        self: Response,
        comptime T: type,
        options: std.json.ParseOptions,
    ) JsonParseError!std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, self.body, options);
    }

    pub fn json_formatted(
        self: Response,
        options: json_printer.Options,
    ) ![]u8 {
        return json_printer.to_owned_slice(self.allocator, self.body, options);
    }

    pub fn json_write_to(
        self: Response,
        writer: anytype,
        options: json_printer.Options,
    ) !void {
        try json_printer.write_to_alloc(writer, self.allocator, self.body, options);
    }
};

pub const ScratchError = scratch.Error;
pub const QueryError = query_builder.Error;
pub const QueryBuilder = query_builder.QueryBuilder;

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .http_client = .{
            .allocator = allocator,
            .io = std.Options.debug_io,
        },
    };
}

pub fn new() !Self {
    var client: Self = undefined;
    try client.init(std.heap.page_allocator);
    return client;
}

pub fn init_default(self: *Self) !void {
    self.* = try Self.new();
}

pub fn deinit(self: *Self) void {
    self.http_client.deinit();
    if (self.cookie_jar) |*jar| jar.deinit();
    self.clear_cookie_header_cache();
    self.* = undefined;
}

pub fn scratch_json(self: *Self, payload: anytype) ScratchError![]u8 {
    return scratch.json(self.allocator, payload);
}

pub fn scratch_post_form(self: *Self, payload: anytype) ScratchError![]u8 {
    return scratch.post_form(self.allocator, payload);
}

pub fn build_query(self: *Self, base_url: []const u8, query: anytype) QueryError![]u8 {
    return query_builder.build(self.allocator, base_url, query);
}

pub fn enable_cookies(self: *Self) !void {
    if (self.cookie_jar != null) return;
    self.cookie_jar = cookie_jar_mod.CookieJar.init(self.allocator);
    self.clear_cookie_header_cache();
}

pub fn disable_cookies(self: *Self) void {
    if (self.cookie_jar) |*jar| jar.deinit();
    self.cookie_jar = null;
    self.clear_cookie_header_cache();
}

fn clear_cookie_header_cache(self: *Self) void {
    if (self.cached_cookie_header_value) |value| {
        self.allocator.free(value);
        self.cached_cookie_header_value = null;
    }
    self.cached_cookie_header_version = 0;
}

fn ensure_cached_cookie_header(self: *Self, jar: *cookie_jar_mod.CookieJar) !?[]const u8 {
    const header_update = try jar.build_header_if_version_changed(
        self.allocator,
        self.cached_cookie_header_version,
    );

    if (header_update.changed) {
        if (self.cached_cookie_header_value) |value| {
            self.allocator.free(value);
            self.cached_cookie_header_value = null;
        }

        self.cached_cookie_header_version = header_update.version;
        self.cached_cookie_header_value = header_update.header_value;
    }

    return self.cached_cookie_header_value;
}

pub fn set_default_request_options(self: *Self, options: DefaultRequestOptions) void {
    self.default_request_keep_alive = options.keep_alive;
    self.default_request_timeout_ms = options.timeout_ms;
    self.default_request_retries = options.retries;
    self.default_request_retry_backoff_ms = options.retry_backoff_ms;
    self.default_request_retry_max_backoff_ms = options.retry_max_backoff_ms;
    self.default_request_redirect_policy = options.redirect_policy;
    self.default_request_max_redirects = options.max_redirects;
}

pub fn default_request_options(self: Self) DefaultRequestOptions {
    return .{
        .keep_alive = self.default_request_keep_alive,
        .timeout_ms = self.default_request_timeout_ms,
        .retries = self.default_request_retries,
        .retry_backoff_ms = self.default_request_retry_backoff_ms,
        .retry_max_backoff_ms = self.default_request_retry_max_backoff_ms,
        .redirect_policy = self.default_request_redirect_policy,
        .max_redirects = self.default_request_max_redirects,
    };
}

fn send(self: *Self, method: std.http.Method, options: RequestOptions) !Response {
    if (options.body != null and !method.requestHasBody()) {
        return error.MethodDoesNotSupportBody;
    }

    const started_ns = now_monotonic_ns();
    var response_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer response_writer.deinit();

    const result = try self.http_client.fetch(.{
        .location = .{ .url = options.url },
        .method = method,
        .payload = payload_for_fetch(method, options.body),
        .keep_alive = options.keep_alive,
        .redirect_behavior = options.redirect_behavior,
        .extra_headers = options.headers,
        .response_writer = &response_writer.writer,
    });

    var response: Response = .{
        .allocator = self.allocator,
        .status = result.status,
        .body = try response_writer.toOwnedSlice(),
    };
    errdefer response.deinit();

    try ensure_within_timeout(options.timeout_ms, started_ns);
    return response;
}

fn send_stream(
    self: *Self,
    method: std.http.Method,
    options: RequestOptions,
    writer: *std.Io.Writer,
) !std.http.Status {
    if (options.body != null and !method.requestHasBody()) {
        return error.MethodDoesNotSupportBody;
    }

    const started_ns = now_monotonic_ns();
    const result = try self.http_client.fetch(.{
        .location = .{ .url = options.url },
        .method = method,
        .payload = payload_for_fetch(method, options.body),
        .keep_alive = options.keep_alive,
        .redirect_behavior = options.redirect_behavior,
        .extra_headers = options.headers,
        .response_writer = writer,
    });

    try ensure_within_timeout(options.timeout_ms, started_ns);
    return result.status;
}

fn payload_for_fetch(method: std.http.Method, body_or_null: ?[]const u8) ?[]const u8 {
    if (method.requestHasBody()) {
        std.debug.assert(empty_body.len == 0);
        return body_or_null orelse empty_body;
    }

    std.debug.assert(body_or_null == null);
    return null;
}

fn request(self: *Self, method: std.http.Method, sender: anytype) !Response {
    self.request_execution_mutex.lockUncancelable(sync_io);
    defer self.request_execution_mutex.unlock(sync_io);

    const Sender = @TypeOf(sender);
    comptime assert_sender(Sender);

    var prepared_body = try self.prepare_body(sender);
    defer prepared_body.deinit(self.allocator);

    var prepared_url = try self.prepare_request_url(sender);
    defer prepared_url.deinit(self.allocator);

    var effective_headers = try self.prepare_request_headers(sender, prepared_body.default_headers);
    defer effective_headers.deinit(self.allocator);

    const timeout_ms = self.request_timeout_ms(sender);
    const retry_options = self.build_retry_options(sender, timeout_ms);

    return self.send_with_retry(method, .{
        .url = prepared_url.value,
        .body = prepared_body.body,
        .headers = effective_headers.value,
        .keep_alive = self.request_keep_alive(sender),
        .timeout_ms = timeout_ms,
        .redirect_behavior = self.request_redirect_behavior(sender),
    }, retry_options);
}

pub fn send_now(
    self: *Self,
    method: std.http.Method,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) !sender_result(@TypeOf(options)) {
    return self.run_with_args(method, request_arg, headers_arg, options);
}

fn send_now_sender(self: *Self, method: std.http.Method, sender: anytype) !sender_result(@TypeOf(sender)) {
    return self.run(method, sender);
}

fn request_stream_to(
    self: *Self,
    method: std.http.Method,
    sender: anytype,
    writer: *std.Io.Writer,
) !std.http.Status {
    self.request_execution_mutex.lockUncancelable(sync_io);
    defer self.request_execution_mutex.unlock(sync_io);

    const Sender = @TypeOf(sender);
    comptime assert_sender(Sender);

    if (self.request_retries(sender) > 0) {
        return error.StreamRetriesNotSupported;
    }

    var prepared_body = try self.prepare_body(sender);
    defer prepared_body.deinit(self.allocator);

    var prepared_url = try self.prepare_request_url(sender);
    defer prepared_url.deinit(self.allocator);

    var effective_headers = try self.prepare_request_headers(sender, prepared_body.default_headers);
    defer effective_headers.deinit(self.allocator);

    return self.send_stream(method, .{
        .url = prepared_url.value,
        .body = prepared_body.body,
        .headers = effective_headers.value,
        .keep_alive = self.request_keep_alive(sender),
        .timeout_ms = self.request_timeout_ms(sender),
        .redirect_behavior = self.request_redirect_behavior(sender),
    }, writer);
}

fn prepare_request_url(self: *Self, sender: anytype) !PreparedUrl {
    const Sender = @TypeOf(sender);

    var prepared: PreparedUrl = .{
        .value = @field(sender, "url"),
    };

    if (!@hasField(Sender, "query")) return prepared;

    const maybe_query = @field(sender, "query");
    try self.apply_query_to_prepared_url(&prepared, maybe_query);
    return prepared;
}

fn apply_query_to_prepared_url(
    self: *Self,
    prepared: *PreparedUrl,
    query_or_optional: anytype,
) !void {
    switch (@typeInfo(@TypeOf(query_or_optional))) {
        .optional => {
            if (query_or_optional) |query| {
                try self.apply_query_to_prepared_url(prepared, query);
            }
        },
        else => {
            const built_url = try self.build_query(prepared.value, query_or_optional);
            if (prepared.owned) |owned| self.allocator.free(owned);

            prepared.value = built_url;
            prepared.owned = built_url;
        },
    }
}

fn prepare_request_headers(
    self: *Self,
    sender: anytype,
    default_headers: []const std.http.Header,
) !EffectiveHeaders {
    const merged = try self.merge_headers(sender_headers(sender), default_headers);

    var effective: EffectiveHeaders = .{
        .value = merged.value,
        .owned_merged_headers = merged.owned,
    };
    errdefer effective.deinit(self.allocator);

    try self.try_append_cookie_header(&effective);
    return effective;
}

fn try_append_cookie_header(self: *Self, effective: *EffectiveHeaders) !void {
    const jar = if (self.cookie_jar) |*value| value else return;

    const cookie_header_value = (try self.ensure_cached_cookie_header(jar)) orelse return;

    const headers_with_cookie = try self.allocator.alloc(std.http.Header, effective.value.len + 1);
    errdefer self.allocator.free(headers_with_cookie);

    @memcpy(headers_with_cookie[0..effective.value.len], effective.value);
    headers_with_cookie[effective.value.len] = .{
        .name = "cookie",
        .value = cookie_header_value,
    };

    effective.value = headers_with_cookie;
    effective.owned_headers_with_cookie = headers_with_cookie;
}

fn build_retry_options(self: *const Self, sender: anytype, timeout_ms: ?u64) RetryOptions {
    const retries = self.request_retries(sender);
    var base_backoff_ms = self.request_retry_backoff_ms(sender);
    var max_backoff_ms = self.request_retry_max_backoff_ms(sender);

    if (retries > 0 and base_backoff_ms == 0) {
        base_backoff_ms = default_retry_backoff_ms;
    }

    if (retries > 0 and (max_backoff_ms == 0 or max_backoff_ms < base_backoff_ms)) {
        max_backoff_ms = base_backoff_ms;
    }

    return .{
        .retries = retries,
        .base_backoff_ms = base_backoff_ms,
        .max_backoff_ms = max_backoff_ms,
        .timeout_ms = timeout_ms,
    };
}

pub fn get(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) async_task(sender_result(@TypeOf(options))) {
    return spawn_async_with_args(self, .GET, request_arg, headers_arg, options);
}

pub fn post(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) async_task(sender_result(@TypeOf(options))) {
    return spawn_async_with_args(self, .POST, request_arg, headers_arg, options);
}

pub fn put(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) async_task(sender_result(@TypeOf(options))) {
    return spawn_async_with_args(self, .PUT, request_arg, headers_arg, options);
}

pub fn patch(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) async_task(sender_result(@TypeOf(options))) {
    return spawn_async_with_args(self, .PATCH, request_arg, headers_arg, options);
}

pub fn delete(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) async_task(sender_result(@TypeOf(options))) {
    return spawn_async_with_args(self, .DELETE, request_arg, headers_arg, options);
}

fn request_with_args(
    self: *Self,
    method: std.http.Method,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) !Response {
    self.request_execution_mutex.lockUncancelable(sync_io);
    defer self.request_execution_mutex.unlock(sync_io);

    comptime assert_options_type(@TypeOf(options));

    var prepared_body = try self.prepare_body(options);
    defer prepared_body.deinit(self.allocator);

    var prepared_url = try self.prepare_request_url_from_args(request_arg, options);
    defer prepared_url.deinit(self.allocator);

    var effective_headers = try self.prepare_request_headers_from_slice(
        headers_arg.slice(),
        prepared_body.default_headers,
    );
    defer effective_headers.deinit(self.allocator);

    const timeout_ms = self.request_timeout_ms(options);
    const retry_options = self.build_retry_options(options, timeout_ms);

    return self.send_with_retry(method, .{
        .url = prepared_url.value,
        .body = prepared_body.body,
        .headers = effective_headers.value,
        .keep_alive = self.request_keep_alive(options),
        .timeout_ms = timeout_ms,
        .redirect_behavior = self.request_redirect_behavior(options),
    }, retry_options);
}

fn run_with_args(
    self: *Self,
    method: std.http.Method,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) !sender_result(@TypeOf(options)) {
    const Options = @TypeOf(options);
    const response = try self.request_with_args(method, request_arg, headers_arg, options);

    if (comptime @hasField(Options, "return_of") or @hasField(Options, "resp")) {
        const ReturnType = if (@hasField(Options, "return_of"))
            sender_return_type(Options)
        else
            sender_resp_type(Options);
        return parse_json_response_of(response, ReturnType);
    }

    return response;
}

fn prepare_request_url_from_args(
    self: *Self,
    request_arg: RequestArg,
    options: anytype,
) !PreparedUrl {
    const Options = @TypeOf(options);

    var prepared: PreparedUrl = .{
        .value = request_arg.url_slice(),
    };

    if (!@hasField(Options, "query")) return prepared;

    const maybe_query = @field(options, "query");
    try self.apply_query_to_prepared_url(&prepared, maybe_query);
    return prepared;
}

fn prepare_request_headers_from_slice(
    self: *Self,
    caller_headers: []const std.http.Header,
    default_headers: []const std.http.Header,
) !EffectiveHeaders {
    const merged = try self.merge_headers(caller_headers, default_headers);

    var effective: EffectiveHeaders = .{
        .value = merged.value,
        .owned_merged_headers = merged.owned,
    };
    errdefer effective.deinit(self.allocator);

    try self.try_append_cookie_header(&effective);
    return effective;
}

fn assert_options_type(comptime Options: type) void {
    if (@typeInfo(Options) != .@"struct") {
        @compileError("options precisa ser um struct anonimo, ex: .{ .resp = MeuTipo }");
    }
}

fn prepare_body(self: *Self, sender: anytype) !PreparedBody {
    var prepared: PreparedBody = .{};
    errdefer prepared.deinit(self.allocator);

    var body_sources: u8 = 0;

    try self.prepare_body_from_raw(&prepared, &body_sources, sender);
    try self.prepare_body_from_serialized(&prepared, &body_sources, sender);
    try self.prepare_body_from_multipart(&prepared, &body_sources, sender);

    return prepared;
}

fn prepare_body_from_raw(
    self: *Self,
    prepared: *PreparedBody,
    body_sources: *u8,
    sender: anytype,
) !void {
    _ = self;
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "body")) return;

    try set_raw_body(prepared, body_sources, @field(sender, "body"));
}

fn set_raw_body(
    prepared: *PreparedBody,
    body_sources: *u8,
    body_or_optional: anytype,
) !void {
    switch (@typeInfo(@TypeOf(body_or_optional))) {
        .optional => {
            if (body_or_optional) |body| {
                try set_raw_body(prepared, body_sources, body);
            }
        },
        else => {
            const body: []const u8 = body_or_optional;
            try register_body_source(body_sources);
            prepared.body = body;
        },
    }
}

fn prepare_body_from_serialized(
    self: *Self,
    prepared: *PreparedBody,
    body_sources: *u8,
    sender: anytype,
) !void {
    const Sender = @TypeOf(sender);

    if (@hasField(Sender, "payload")) {
        try self.set_serialized_payload(
            prepared,
            body_sources,
            @field(sender, "payload"),
            sender_payload_kind(sender),
        );
    }

    if (@hasField(Sender, "json")) {
        try self.set_serialized_payload(
            prepared,
            body_sources,
            @field(sender, "json"),
            .json,
        );
    }

    if (@hasField(Sender, "form")) {
        try self.set_serialized_payload(
            prepared,
            body_sources,
            @field(sender, "form"),
            .form,
        );
    }
}

fn prepare_body_from_multipart(
    self: *Self,
    prepared: *PreparedBody,
    body_sources: *u8,
    sender: anytype,
) !void {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "multipart")) return;

    const parts_or_optional = @field(sender, "multipart");
    const parts: []const multipart_mod.Part = switch (@typeInfo(@TypeOf(parts_or_optional))) {
        .optional => parts_or_optional orelse return,
        else => parts_or_optional,
    };

    try register_body_source(body_sources);
    try self.set_multipart_body(prepared, parts);
}

fn set_multipart_body(
    self: *Self,
    prepared: *PreparedBody,
    parts: []const multipart_mod.Part,
) !void {
    var boundary_buf: [32]u8 = undefined;
    const boundary = multipart_mod.generate_boundary(&boundary_buf);

    const body = try multipart_mod.build(self.allocator, parts, boundary);
    errdefer self.allocator.free(body);

    const ct_value = try std.fmt.allocPrint(
        self.allocator,
        "multipart/form-data; boundary={s}",
        .{boundary},
    );
    errdefer self.allocator.free(ct_value);

    const header_slice = try self.allocator.alloc(std.http.Header, 1);
    errdefer self.allocator.free(header_slice);

    header_slice[0] = .{ .name = "content-type", .value = ct_value };

    prepared.body = body;
    prepared.owned_body = body;
    prepared.owned_ct_value = ct_value;
    prepared.default_headers = header_slice;
    prepared.owned_headers = header_slice;
}

fn register_body_source(body_sources: *u8) !void {
    body_sources.* += 1;
    if (body_sources.* > 1) return error.MultipleBodySources;
}

fn set_serialized_payload(
    self: *Self,
    prepared: *PreparedBody,
    body_sources: *u8,
    payload_or_optional: anytype,
    format: scratch.Format,
) !void {
    switch (@typeInfo(@TypeOf(payload_or_optional))) {
        .optional => {
            if (payload_or_optional) |payload| {
                try self.set_serialized_payload(prepared, body_sources, payload, format);
            }
        },
        else => {
            try register_body_source(body_sources);

            const encoded = try scratch.encode(self.allocator, payload_or_optional, format);
            prepared.body = encoded;
            prepared.owned_body = encoded;
            prepared.default_headers = switch (format) {
                .json => content_type_headers.json[0..],
                .form => content_type_headers.form[0..],
            };
        },
    }
}

const RetryOptions = struct {
    retries: u8 = 0,
    base_backoff_ms: u64 = default_retry_backoff_ms,
    max_backoff_ms: u64 = default_retry_max_backoff_ms,
    timeout_ms: ?u64 = null,
};

fn send_with_retry(
    self: *Self,
    method: std.http.Method,
    options: RequestOptions,
    retry: RetryOptions,
) !Response {
    const started_ns = now_monotonic_ns();
    var attempt: u16 = 1;
    while (true) : (attempt += 1) {
        try ensure_within_timeout(retry.timeout_ms, started_ns);

        const response = self.send(method, options) catch |err| {
            if (attempt > retry.retries or !should_retry_request(method, err)) return err;
            try sleep_before_retry(attempt, retry, started_ns);
            continue;
        };

        return response;
    }
}

fn sleep_before_retry(attempt: u16, retry: RetryOptions, started_ns: i128) !void {
    var delay_ms = compute_backoff_with_jitter_ms(attempt, retry.base_backoff_ms, retry.max_backoff_ms);
    if (retry.timeout_ms) |timeout_ms| {
        const elapsed_ms = elapsed_ms_since(started_ns);
        if (elapsed_ms >= timeout_ms) return error.RequestTimedOut;

        const remaining_ms = timeout_ms - elapsed_ms;
        if (delay_ms > remaining_ms) {
            delay_ms = remaining_ms;
        }
    }

    if (delay_ms == 0) return;
    const delay_ns = ms_to_ns(delay_ms);
    try std.Io.Clock.Duration.sleep(
        .{ .clock = .boot, .raw = .fromNanoseconds(delay_ns) },
        sync_io,
    );
}

fn compute_backoff_with_jitter_ms(attempt: u16, base_ms: u64, max_ms: u64) u64 {
    if (base_ms == 0) return 0;

    const capped_max = if (max_ms == 0) base_ms else @max(base_ms, max_ms);
    var backoff_ms = base_ms;
    var n: u16 = 1;
    while (n < attempt and backoff_ms < capped_max) : (n += 1) {
        backoff_ms = @min(capped_max, backoff_ms *| 2);
    }

    const jitter_cap = backoff_ms / 4;
    if (jitter_cap == 0) return backoff_ms;

    var rand_bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&rand_bytes);
    const random = std.mem.readInt(u64, &rand_bytes, .little);
    const jitter = random % (jitter_cap + 1);

    return @min(capped_max, backoff_ms +| jitter);
}

fn should_retry_request(method: std.http.Method, err: anyerror) bool {
    if (!is_retryable_method(method)) return false;
    if (err == error.RequestTimedOut) return true;
    return is_transient_network_error(err);
}

fn is_retryable_method(method: std.http.Method) bool {
    return switch (method) {
        .GET, .PUT, .DELETE => true,
        else => false,
    };
}

fn is_transient_network_error(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "ConnectionTimedOut") or
        std.mem.eql(u8, name, "UnexpectedConnectFailure") or
        std.mem.eql(u8, name, "ConnectionRefused") or
        std.mem.eql(u8, name, "ConnectionResetByPeer") or
        std.mem.eql(u8, name, "ConnectionAborted") or
        std.mem.eql(u8, name, "BrokenPipe") or
        std.mem.eql(u8, name, "NetworkUnreachable") or
        std.mem.eql(u8, name, "HostUnreachable") or
        std.mem.eql(u8, name, "UnknownHostName") or
        std.mem.eql(u8, name, "TemporaryNameServerFailure") or
        std.mem.eql(u8, name, "NameServerFailure") or
        std.mem.eql(u8, name, "HostLacksNetworkAddresses") or
        std.mem.eql(u8, name, "Unexpected");
}

fn ensure_within_timeout(timeout_ms: ?u64, started_ns: i128) !void {
    const limit_ms = timeout_ms orelse return;
    if (elapsed_ms_since(started_ns) > limit_ms) return error.RequestTimedOut;
}

fn elapsed_ms_since(started_ns: i128) u64 {
    const now_ns = now_monotonic_ns();
    const diff_ns: i128 = if (now_ns > started_ns) now_ns - started_ns else 0;
    const max_u64_as_i128: i128 = @intCast(std.math.maxInt(u64));
    const clamped_ns: i128 = if (diff_ns > max_u64_as_i128) max_u64_as_i128 else diff_ns;
    const elapsed_ns: u64 = @intCast(clamped_ns);
    return elapsed_ns / std.time.ns_per_ms;
}

fn now_monotonic_ns() i128 {
    if (!builtin.link_libc) return 0;

    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) return 0;

    const sec_ns = @as(i128, @intCast(ts.sec)) * std.time.ns_per_s;
    const nsec = @as(i128, @intCast(ts.nsec));
    return sec_ns + nsec;
}

fn ms_to_ns(ms: u64) u64 {
    return std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
}

fn run(self: *Self, method: std.http.Method, sender: anytype) !sender_result(@TypeOf(sender)) {
    const Sender = @TypeOf(sender);
    const response = try self.request(method, sender);

    if (comptime @hasField(Sender, "return_of") or @hasField(Sender, "resp")) {
        const ReturnType = if (@hasField(Sender, "return_of"))
            sender_return_type(Sender)
        else
            sender_resp_type(Sender);
        return parse_json_response_of(response, ReturnType);
    }

    return response;
}

fn get_result(comptime Input: type) type {
    if (is_sender_input(Input)) return sender_result(Input);
    return Response;
}

fn is_sender_input(comptime Input: type) bool {
    return @typeInfo(Input) == .@"struct" and @hasField(Input, "url");
}

fn sender_result(comptime Sender: type) type {
    if (@typeInfo(Sender) != .@"struct") {
        return Response;
    }

    if (@hasField(Sender, "return_of") and @hasField(Sender, "resp")) {
        @compileError("sender nao pode ter return_of e resp ao mesmo tempo");
    }

    if (@hasField(Sender, "return_of")) {
        return std.json.Parsed(sender_return_type(Sender));
    }

    if (@hasField(Sender, "resp")) {
        return std.json.Parsed(sender_resp_type(Sender));
    }

    return Response;
}

fn sender_return_type(comptime Sender: type) type {
    if (!@hasField(Sender, "return_of")) {
        @compileError("sender.return_of nao encontrado");
    }

    const marker = @FieldType(Sender, "return_of");
    if (@hasDecl(marker, "return_type")) {
        return marker.return_type;
    }

    if (marker == type) {
        @compileError(
            "sender.return_of deve ser http.return_of(T), ex: .{ .return_of = http.return_of(MyType) }",
        );
    }

    @compileError("sender.return_of invalido. Use http.return_of(T)");
}

fn sender_resp_type(comptime Sender: type) type {
    if (@typeInfo(Sender) != .@"struct") {
        @compileError("sender.resp so pode ser usado em sender struct");
    }

    if (!@hasField(Sender, "resp")) {
        @compileError(
            "sender.resp e obrigatorio. Ex: .{ .url = ..., .json = ..., .resp = MeuTipo }",
        );
    }

    const marker = @as(Sender, undefined).resp;
    if (@TypeOf(marker) == type) {
        return marker;
    }

    const MarkerType = @TypeOf(marker);
    if (@hasDecl(MarkerType, "return_type")) {
        return MarkerType.return_type;
    }

    @compileError("sender.resp invalido. Use .resp = MeuTipo ou .resp = http.return_of(MeuTipo)");
}

fn parse_json_response_of(response: Response, comptime ReturnType: type) !std.json.Parsed(ReturnType) {
    var owned_response = response;
    defer owned_response.deinit();
    return owned_response.json(ReturnType);
}

fn request_keep_alive(self: *const Self, sender: anytype) bool {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "keep_alive")) return self.default_request_keep_alive;

    return sender_keep_alive(sender);
}

fn request_timeout_ms(self: *const Self, sender: anytype) ?u64 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "timeout_ms")) return self.default_request_timeout_ms;

    return sender_timeout_ms(sender);
}

fn request_retries(self: *const Self, sender: anytype) u8 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "retries")) return self.default_request_retries;

    return sender_retries(sender);
}

fn request_retry_backoff_ms(self: *const Self, sender: anytype) u64 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "retry_backoff_ms")) {
        return self.default_request_retry_backoff_ms;
    }

    return sender_retry_backoff_ms(sender);
}

fn request_retry_max_backoff_ms(self: *const Self, sender: anytype) u64 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "retry_max_backoff_ms")) {
        return self.default_request_retry_max_backoff_ms;
    }

    return sender_retry_max_backoff_ms(sender);
}

fn request_redirect_policy(self: *const Self, sender: anytype) RedirectPolicy {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "redirect_policy")) return self.default_request_redirect_policy;

    return sender_redirect_policy(sender);
}

fn request_max_redirects(self: *const Self, sender: anytype) u16 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "max_redirects")) return self.default_request_max_redirects;

    return sender_max_redirects(sender);
}

fn request_redirect_behavior(
    self: *const Self,
    sender: anytype,
) std.http.Client.Request.RedirectBehavior {
    const policy = self.request_redirect_policy(sender);
    return switch (policy) {
        .manual => .unhandled,
        .fail => .not_allowed,
        .follow => std.http.Client.Request.RedirectBehavior.init(self.request_max_redirects(sender)),
    };
}

fn sender_payload_kind(sender: anytype) scratch.Format {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "payload_kind")) return .json;

    const kind: scratch.Format = @field(sender, "payload_kind");
    return kind;
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

fn sender_keep_alive(sender: anytype) bool {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "keep_alive")) return true;

    const keep_alive: bool = @field(sender, "keep_alive");
    return keep_alive;
}

fn sender_timeout_ms(sender: anytype) ?u64 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "timeout_ms")) return null;

    const value = @field(sender, "timeout_ms");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value,
        else => @as(u64, @intCast(value)),
    };
}

fn sender_retries(sender: anytype) u8 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "retries")) return 0;

    const value = @field(sender, "retries");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| @intCast(inner) else 0,
        else => @intCast(value),
    };
}

fn sender_retry_backoff_ms(sender: anytype) u64 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "retry_backoff_ms")) return default_retry_backoff_ms;

    const value = @field(sender, "retry_backoff_ms");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| @intCast(inner) else default_retry_backoff_ms,
        else => @intCast(value),
    };
}

fn sender_retry_max_backoff_ms(sender: anytype) u64 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "retry_max_backoff_ms")) return default_retry_max_backoff_ms;

    const value = @field(sender, "retry_max_backoff_ms");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| @intCast(inner) else default_retry_max_backoff_ms,
        else => @intCast(value),
    };
}

fn sender_redirect_behavior(sender: anytype) std.http.Client.Request.RedirectBehavior {
    const policy = sender_redirect_policy(sender);
    return switch (policy) {
        .manual => .unhandled,
        .fail => .not_allowed,
        .follow => std.http.Client.Request.RedirectBehavior.init(sender_max_redirects(sender)),
    };
}

fn sender_redirect_policy(sender: anytype) RedirectPolicy {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "redirect_policy")) return .follow;

    const value = @field(sender, "redirect_policy");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| inner else .follow,
        else => value,
    };
}

fn sender_max_redirects(sender: anytype) u16 {
    const Sender = @TypeOf(sender);
    if (!@hasField(Sender, "max_redirects")) return default_max_redirects;

    const value = @field(sender, "max_redirects");
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| @intCast(inner) else default_max_redirects,
        else => @intCast(value),
    };
}

fn merge_headers(
    self: *Self,
    caller_headers: []const std.http.Header,
    default_headers: []const std.http.Header,
) !MergedHeaders {
    if (default_headers.len == 0) {
        return .{ .value = caller_headers };
    }

    if (caller_headers.len == 0 or has_content_type_header(caller_headers)) {
        return .{
            .value = if (caller_headers.len == 0) default_headers else caller_headers,
        };
    }

    const merged = try self.allocator.alloc(
        std.http.Header,
        caller_headers.len + default_headers.len,
    );
    @memcpy(merged[0..default_headers.len], default_headers);
    @memcpy(merged[default_headers.len..], caller_headers);

    return .{
        .value = merged,
        .owned = merged,
    };
}

fn has_content_type_header(headers: []const std.http.Header) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) return true;
    }

    return false;
}

fn has_header_named(headers: []const std.http.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }

    return false;
}

fn assert_sender(comptime Sender: type) void {
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

const WorkItem = struct {
    run: *const fn (*anyopaque) void,
    context: *anyopaque,
};

const BoundedWorkQueue = struct {
    items: [async_queue_capacity]WorkItem = undefined,
    head: u16 = 0,
    tail: u16 = 0,
    count: u16 = 0,

    fn push(self: *BoundedWorkQueue, item: WorkItem) !void {
        std.debug.assert(self.count <= async_queue_capacity);
        if (self.count >= async_queue_capacity) return error.AsyncExecutorQueueFull;

        const tail_index: usize = self.tail;
        self.items[tail_index] = item;

        self.tail = increment_queue_index(self.tail);
        self.count += 1;
    }

    fn pop(self: *BoundedWorkQueue) ?WorkItem {
        std.debug.assert(self.count <= async_queue_capacity);
        if (self.count == 0) return null;

        const head_index: usize = self.head;
        const item = self.items[head_index];

        self.head = increment_queue_index(self.head);
        self.count -= 1;
        return item;
    }

    fn is_empty(self: BoundedWorkQueue) bool {
        return self.count == 0;
    }
};

const AsyncExecutor = struct {
    mutex: std.Io.Mutex = .init,
    has_work: std.Io.Condition = .init,
    started: bool = false,
    workers: [async_worker_count]std.Thread = undefined,
    queue: BoundedWorkQueue = .{},

    fn submit(self: *AsyncExecutor, item: WorkItem) !void {
        try self.start_once();

        self.mutex.lockUncancelable(sync_io);
        defer self.mutex.unlock(sync_io);

        try self.queue.push(item);
        self.has_work.signal(sync_io);
    }

    fn start_once(self: *AsyncExecutor) !void {
        self.mutex.lockUncancelable(sync_io);
        defer self.mutex.unlock(sync_io);

        if (self.started) return;

        var worker_index: u8 = 0;
        while (worker_index < async_worker_count) : (worker_index += 1) {
            const index: usize = worker_index;
            self.workers[index] = std.Thread.spawn(
                .{},
                AsyncExecutor.worker_main,
                .{self},
            ) catch |err| {
                if (worker_index == 0) return err;

                self.started = true;
                return;
            };
        }

        self.started = true;
    }

    fn worker_main(self: *AsyncExecutor) void {
        while (true) {
            self.mutex.lockUncancelable(sync_io);
            while (self.queue.is_empty()) {
                self.has_work.waitUncancelable(sync_io, &self.mutex);
            }
            const item = self.queue.pop().?;
            self.mutex.unlock(sync_io);

            item.run(item.context);
        }
    }
};

var global_async_executor: AsyncExecutor = .{};

fn increment_queue_index(index: u16) u16 {
    if (index + 1 == async_queue_capacity) return 0;
    return index + 1;
}

fn spawn_async(
    self: *Self,
    method: std.http.Method,
    sender: anytype,
) async_task(sender_result(@TypeOf(sender))) {
    const Sender = @TypeOf(sender);
    const ResultType = sender_result(Sender);
    const TaskType = async_task(ResultType);
    const alloc = std.heap.page_allocator;

    const Ctx = struct {
        client: *Self,
        method: std.http.Method,
        sender: Sender,
        shared: *TaskType.Shared,

        fn run(context: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(context));
            defer std.heap.page_allocator.destroy(ctx);

            ctx.shared.finish(ctx.client.run(ctx.method, ctx.sender));
        }
    };

    const shared = alloc.create(TaskType.Shared) catch |err| {
        return .{ .inner = .{ .failed = err } };
    };
    shared.* = .{};

    const ctx = alloc.create(Ctx) catch |err| {
        alloc.destroy(shared);
        return .{ .inner = .{ .failed = err } };
    };
    ctx.* = .{ .client = self, .method = method, .sender = sender, .shared = shared };

    global_async_executor.submit(.{
        .run = Ctx.run,
        .context = @ptrCast(ctx),
    }) catch |err| {
        alloc.destroy(ctx);
        alloc.destroy(shared);
        return .{ .inner = .{ .failed = err } };
    };

    return .{ .inner = .{ .running = .{ .shared = shared } } };
}

fn spawn_async_with_args(
    self: *Self,
    method: std.http.Method,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) async_task(sender_result(@TypeOf(options))) {
    const Options = @TypeOf(options);
    const ResultType = sender_result(Options);
    const TaskType = async_task(ResultType);
    const alloc = std.heap.page_allocator;

    const Ctx = struct {
        client: *Self,
        method: std.http.Method,
        request_arg: RequestArg,
        headers_arg: HeadersArg,
        options: Options,
        shared: *TaskType.Shared,

        fn run(context: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(context));
            defer std.heap.page_allocator.destroy(ctx);

            ctx.shared.finish(
                ctx.client.run_with_args(
                    ctx.method,
                    ctx.request_arg,
                    ctx.headers_arg,
                    ctx.options,
                ),
            );
        }
    };

    const shared = alloc.create(TaskType.Shared) catch |err| {
        return .{ .inner = .{ .failed = err } };
    };
    shared.* = .{};

    const ctx = alloc.create(Ctx) catch |err| {
        alloc.destroy(shared);
        return .{ .inner = .{ .failed = err } };
    };
    ctx.* = .{
        .client = self,
        .method = method,
        .request_arg = request_arg,
        .headers_arg = headers_arg,
        .options = options,
        .shared = shared,
    };

    global_async_executor.submit(.{
        .run = Ctx.run,
        .context = @ptrCast(ctx),
    }) catch |err| {
        alloc.destroy(ctx);
        alloc.destroy(shared);
        return .{ .inner = .{ .failed = err } };
    };

    return .{ .inner = .{ .running = .{ .shared = shared } } };
}

pub const StreamReader = struct {
    body: []u8,
    index: usize = 0,
    allocator: std.mem.Allocator,
    status: std.http.Status,

    pub fn read(self: *StreamReader, buf: []u8) usize {
        const remaining = self.body[self.index..];
        if (remaining.len == 0) return 0;
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.index += n;
        return n;
    }

    pub fn status_code(self: StreamReader) u16 {
        return @intCast(@intFromEnum(self.status));
    }

    pub fn is_success(self: StreamReader) bool {
        const code = self.status_code();
        return code >= 200 and code < 300;
    }

    pub fn deinit(self: *StreamReader) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn stream_to(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
    writer: *std.Io.Writer,
) !std.http.Status {
    return self.request_stream_to_with_args(.GET, request_arg, headers_arg, options, writer);
}

pub fn stream(
    self: *Self,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
) !StreamReader {
    const resp = try self.request_with_args(.GET, request_arg, headers_arg, options);
    return StreamReader{
        .body = resp.body,
        .allocator = resp.allocator,
        .status = resp.status,
    };
}

fn request_stream_to_with_args(
    self: *Self,
    method: std.http.Method,
    request_arg: RequestArg,
    headers_arg: HeadersArg,
    options: anytype,
    writer: *std.Io.Writer,
) !std.http.Status {
    self.request_execution_mutex.lockUncancelable(sync_io);
    defer self.request_execution_mutex.unlock(sync_io);

    comptime assert_options_type(@TypeOf(options));

    if (self.request_retries(options) > 0) {
        return error.StreamRetriesNotSupported;
    }

    var prepared_body = try self.prepare_body(options);
    defer prepared_body.deinit(self.allocator);

    var prepared_url = try self.prepare_request_url_from_args(request_arg, options);
    defer prepared_url.deinit(self.allocator);

    var effective_headers = try self.prepare_request_headers_from_slice(
        headers_arg.slice(),
        prepared_body.default_headers,
    );
    defer effective_headers.deinit(self.allocator);

    return self.send_stream(method, .{
        .url = prepared_url.value,
        .body = prepared_body.body,
        .headers = effective_headers.value,
        .keep_alive = self.request_keep_alive(options),
        .timeout_ms = self.request_timeout_ms(options),
        .redirect_behavior = self.request_redirect_behavior(options),
    }, writer);
}

const PreparedBody = struct {
    body: ?[]const u8 = null,
    owned_body: ?[]u8 = null,
    default_headers: []const std.http.Header = empty_headers,
    owned_headers: ?[]std.http.Header = null,
    owned_ct_value: ?[]u8 = null,

    fn deinit(self: *PreparedBody, allocator: std.mem.Allocator) void {
        if (self.owned_body) |owned| allocator.free(owned);
        if (self.owned_headers) |h| allocator.free(h);
        if (self.owned_ct_value) |v| allocator.free(v);
        self.* = undefined;
    }
};

const MergedHeaders = struct {
    value: []const std.http.Header,
    owned: ?[]std.http.Header = null,
};

const PreparedUrl = struct {
    value: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *PreparedUrl, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

const EffectiveHeaders = struct {
    value: []const std.http.Header,
    owned_merged_headers: ?[]std.http.Header = null,
    owned_headers_with_cookie: ?[]std.http.Header = null,

    fn deinit(self: *EffectiveHeaders, allocator: std.mem.Allocator) void {
        if (self.owned_headers_with_cookie) |headers| allocator.free(headers);
        if (self.owned_merged_headers) |headers| allocator.free(headers);
        self.* = undefined;
    }
};

fn should_run_real_http_tests(allocator: std.mem.Allocator) bool {
    _ = allocator;
    return env_var_truthy("RUN_REAL_HTTP_TESTS");
}

fn env_var_truthy(comptime name_z: [:0]const u8) bool {
    if (!builtin.link_libc) return false;
    const value_z = std.c.getenv(name_z) orelse return false;
    const value = std.mem.sliceTo(value_z, 0);
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn should_skip_real_http_error(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "UnknownHostName") or
        std.mem.eql(u8, name, "TemporaryNameServerFailure") or
        std.mem.eql(u8, name, "NameServerFailure") or
        std.mem.eql(u8, name, "HostLacksNetworkAddresses") or
        std.mem.eql(u8, name, "ConnectionTimedOut") or
        std.mem.eql(u8, name, "UnexpectedConnectFailure") or
        std.mem.eql(u8, name, "Unexpected");
}

test "bounded async queue enforces capacity and fifo order" {
    var queue: BoundedWorkQueue = .{};

    var index: u16 = 0;
    while (index < async_queue_capacity) : (index += 1) {
        const context: *anyopaque = @ptrFromInt(@as(usize, index) + 1);
        try queue.push(.{ .run = bounded_queue_noop_run, .context = context });
    }

    try std.testing.expectError(
        error.AsyncExecutorQueueFull,
        queue.push(.{ .run = bounded_queue_noop_run, .context = @ptrFromInt(9999) }),
    );

    var expected_index: u16 = 0;
    while (expected_index < async_queue_capacity) : (expected_index += 1) {
        const item = queue.pop().?;
        const expected_context: *anyopaque = @ptrFromInt(@as(usize, expected_index) + 1);
        try std.testing.expect(item.context == expected_context);
    }

    try std.testing.expect(queue.pop() == null);
}

fn bounded_queue_noop_run(_: *anyopaque) void {}

test "client init/deinit in tiger style" {
    var client: Self = undefined;
    try client.init(std.testing.allocator);
    client.deinit();
}

test "client new uses hidden allocator" {
    var client = try Self.new();
    client.deinit();
}

test "client init_default stays compatible" {
    var client: Self = undefined;
    try client.init_default();
    client.deinit();
}

test "client wrappers build query and scratch safely" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const query_url = try client.build_query("https://test.com/api", .{
        .page = 1,
        .filter = "all users",
    });
    defer allocator.free(query_url);
    try std.testing.expectEqualStrings("https://test.com/api?page=1&filter=all%20users", query_url);

    const json_body = try client.scratch_json(.{ .name = "john", .age = 10 });
    defer allocator.free(json_body);
    try std.testing.expectEqualStrings("{\"name\":\"john\",\"age\":10}", json_body);

    const form_body = try client.scratch_post_form(.{ .name = "john doe", .enabled = true });
    defer allocator.free(form_body);
    try std.testing.expectEqualStrings("name=john+doe&enabled=true", form_body);
}

test "prepare_body serializes payload as json by default" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    var prepared = try client.prepare_body(.{
        .url = "https://example.com",
        .payload = .{ .id = 7 },
    });
    defer prepared.deinit(allocator);

    try std.testing.expect(prepared.body != null);
    try std.testing.expectEqualStrings("{\"id\":7}", prepared.body.?);
    try std.testing.expectEqual(@as(usize, 1), prepared.default_headers.len);
    try std.testing.expectEqualStrings("application/json", prepared.default_headers[0].value);
}

test "prepare_body supports form payload" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    var prepared = try client.prepare_body(.{
        .url = "https://example.com",
        .payload = .{ .name = "john doe" },
        .payload_kind = .form,
    });
    defer prepared.deinit(allocator);

    try std.testing.expect(prepared.body != null);
    try std.testing.expectEqualStrings("name=john+doe", prepared.body.?);
    try std.testing.expectEqual(@as(usize, 1), prepared.default_headers.len);
    try std.testing.expectEqualStrings(
        "application/x-www-form-urlencoded",
        prepared.default_headers[0].value,
    );
}

test "prepare_body rejects multiple body sources" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    try std.testing.expectError(
        error.MultipleBodySources,
        client.prepare_body(.{
            .url = "https://example.com",
            .body = "{}",
            .payload = .{ .id = 1 },
        }),
    );
}

test "payload_for_fetch uses empty payload for patch without body" {
    const payload = payload_for_fetch(.PATCH, null);

    try std.testing.expect(payload != null);
    try std.testing.expectEqual(@as(usize, 0), payload.?.len);
}

test "payload_for_fetch keeps provided payload for post" {
    const payload = payload_for_fetch(.POST, "grant_type=client_credentials");

    try std.testing.expect(payload != null);
    try std.testing.expectEqualStrings("grant_type=client_credentials", payload.?);
}

test "payload_for_fetch omits payload for get" {
    const payload = payload_for_fetch(.GET, null);

    try std.testing.expect(payload == null);
}

test "prepare_body builds multipart body with content-type" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const parts: []const multipart_mod.Part = &.{
        .{ .name = "greeting", .content_type = "text/plain", .data = "hello" },
    };
    var prepared = try client.prepare_body(.{
        .url = "https://example.com",
        .multipart = parts,
    });
    defer prepared.deinit(allocator);

    try std.testing.expect(prepared.body != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.body.?, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.body.?, "name=\"greeting\"") != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.default_headers.len);
    try std.testing.expect(
        std.mem.startsWith(u8, prepared.default_headers[0].value, "multipart/form-data; boundary="),
    );
}

test "prepare_body rejects multipart + body" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const parts: []const multipart_mod.Part = &.{
        .{ .name = "f", .content_type = "text/plain", .data = "x" },
    };
    try std.testing.expectError(
        error.MultipleBodySources,
        client.prepare_body(.{
            .url = "https://example.com",
            .body = "raw",
            .multipart = parts,
        }),
    );
}

test "StreamReader read() and deinit()" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "Hello, World!");
    var sr = StreamReader{
        .body = body,
        .allocator = allocator,
        .status = .ok,
    };
    defer sr.deinit();

    var buf: [5]u8 = undefined;
    const n1 = sr.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n1);
    try std.testing.expectEqualStrings("Hello", buf[0..n1]);

    const n2 = sr.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n2);
    try std.testing.expectEqualStrings(", Wor", buf[0..n2]);

    const n3 = sr.read(&buf);
    try std.testing.expectEqual(@as(usize, 3), n3);
    try std.testing.expectEqualStrings("ld!", buf[0..n3]);

    const n4 = sr.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n4);
}

test "StreamReader status_code and is_success" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "");
    var sr = StreamReader{ .body = body, .allocator = allocator, .status = .ok };
    defer sr.deinit();
    try std.testing.expectEqual(@as(u16, 200), sr.status_code());
    try std.testing.expect(sr.is_success());
}

test "stream_to API returns status" {
    comptime {
        const writer: *std.Io.Writer = undefined;
        const UrlCall = @typeInfo(@TypeOf(
            @as(*Self, undefined).stream_to(.url("https://example.com"), .headers(.{}), .{}, writer),
        )).error_union.payload;
        if (UrlCall != std.http.Status) {
            @compileError("stream_to(.url(...), .headers(...), .{}, writer) deve retornar std.http.Status");
        }

        const SenderCall = @typeInfo(@TypeOf(
            @as(*Self, undefined).stream_to(
                .url("https://example.com"),
                .headers(.{}),
                .{ .query = .{ .page = 1 } },
                writer,
            ),
        )).error_union.payload;
        if (SenderCall != std.http.Status) {
            @compileError("stream_to com options deve retornar std.http.Status");
        }
    }

    try std.testing.expect(true);
}

test "send_stream rejects body for method without body" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try std.testing.expectError(
        error.MethodDoesNotSupportBody,
        client.send_stream(.GET, .{
            .url = "https://example.com",
            .body = "invalid",
        }, &writer.writer),
    );
}

test "enable_cookies/disable_cookies lifecycle" {
    const allocator = std.testing.allocator;
    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    try std.testing.expect(client.cookie_jar == null);
    try client.enable_cookies();
    try std.testing.expect(client.cookie_jar != null);
    try client.enable_cookies();
    try std.testing.expect(client.cookie_jar != null);
    client.disable_cookies();
    try std.testing.expect(client.cookie_jar == null);
}

test "cookie header cache refreshes only when jar version changes" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    try client.enable_cookies();
    const jar = &client.cookie_jar.?;

    try jar.set("session", "a1");

    const first = (try client.ensure_cached_cookie_header(jar)) orelse unreachable;
    const first_pointer = @intFromPtr(first.ptr);

    const second = (try client.ensure_cached_cookie_header(jar)) orelse unreachable;
    const second_pointer = @intFromPtr(second.ptr);
    try std.testing.expectEqual(first_pointer, second_pointer);

    try jar.set("session", "b2");
    const third = (try client.ensure_cached_cookie_header(jar)) orelse unreachable;
    try std.testing.expectEqualStrings("session=b2", third);
}

test "run infers typed return when sender has return_of" {
    comptime {
        const Result = sender_result(@TypeOf(.{
            .url = "https://example.com",
            .return_of = return_of(struct { id: u32 }),
        }));
        _ = Result;
    }

    try std.testing.expect(true);
}

test "sender result defaults to raw response without return_of" {
    comptime {
        const Result = sender_result(@TypeOf(.{ .url = "https://example.com" }));
        if (Result != Response) @compileError("sender sem return_of deve retornar Response");
    }

    try std.testing.expect(true);
}

test "get with url arg keeps raw response type" {
    var url: []const u8 = "https://example.com";
    url = "https://example.com";

    const Result = @TypeOf(@as(*Self, undefined).get(.url(url), .headers(.{}), .{}));
    if (Result != async_task(Response)) {
        @compileError("get(.url(...), .headers(...), .{}) deve retornar async_task(Response)");
    }

    try std.testing.expect(true);
}

test "get keeps return_of inference in options" {
    comptime {
        const ReturnType = struct { id: u32 };
        const Result = @TypeOf(@as(*Self, undefined).get(
            .url("https://example.com"),
            .headers(.{}),
            .{ .return_of = return_of(ReturnType) },
        ));
        if (Result != async_task(std.json.Parsed(ReturnType))) {
            @compileError("get com options.return_of deve retornar Parsed(T)");
        }
    }

    try std.testing.expect(true);
}

test "post with resp accepts runtime payload field type-check" {
    var runtime_name: []const u8 = "ana";
    runtime_name = "ana";

    const PostResp = struct { ok: bool };
    const Result = @TypeOf(
        @as(*Self, undefined).post(
            .url("https://example.com"),
            .headers(.{}),
            .{ .json = .{ .name = runtime_name }, .resp = PostResp },
        ),
    );
    if (Result != async_task(std.json.Parsed(PostResp))) {
        @compileError("post com resp deve retornar async_task(Parsed(T))");
    }

    try std.testing.expect(true);
}

test "get infers parsed type when options has resp marker" {
    comptime {
        const GetResp = struct { origin: []const u8 = "" };
        const Result = @TypeOf(
            @as(*Self, undefined).get(
                .url("https://example.com"),
                .headers(.{}),
                .{ .resp = GetResp },
            ),
        );
        if (Result != async_task(std.json.Parsed(GetResp))) {
            @compileError("get(options com .resp = T) deve retornar async_task(Parsed(T))");
        }
    }

    try std.testing.expect(true);
}

test "post infers parsed type when options has resp marker" {
    comptime {
        const PostResp = struct { ok: bool };
        const Result = @TypeOf(
            @as(*Self, undefined).post(
                .url("https://example.com"),
                .headers(.{}),
                .{ .json = .{ .name = "ana" }, .resp = PostResp },
            ),
        );
        if (Result != async_task(std.json.Parsed(PostResp))) {
            @compileError("post(options com .resp = T) deve retornar async_task(Parsed(T))");
        }
    }

    try std.testing.expect(true);
}

test "post defaults to raw response when options has no typed marker" {
    comptime {
        const Result = @TypeOf(
            @as(*Self, undefined).post(
                .url("https://example.com"),
                .headers(.{}),
                .{ .json = .{ .name = "ana" } },
            ),
        );
        if (Result != async_task(Response)) {
            @compileError("post sem return_of/resp deve retornar async_task(Response)");
        }
    }

    try std.testing.expect(true);
}

test "put infers parsed type when options has resp marker" {
    comptime {
        const PutResp = struct { ok: bool };
        const Result = @TypeOf(
            @as(*Self, undefined).put(
                .url("https://example.com"),
                .headers(.{}),
                .{ .json = .{ .name = "ana" }, .resp = PutResp },
            ),
        );
        if (Result != async_task(std.json.Parsed(PutResp))) {
            @compileError("put(options com .resp = T) deve retornar async_task(Parsed(T))");
        }
    }

    try std.testing.expect(true);
}

test "patch infers parsed type when options has resp marker" {
    comptime {
        const PatchResp = struct { ok: bool };
        const Result = @TypeOf(
            @as(*Self, undefined).patch(
                .url("https://example.com"),
                .headers(.{}),
                .{ .json = .{ .name = "ana" }, .resp = PatchResp },
            ),
        );
        if (Result != async_task(std.json.Parsed(PatchResp))) {
            @compileError("patch(options com .resp = T) deve retornar async_task(Parsed(T))");
        }
    }

    try std.testing.expect(true);
}

test "delete infers parsed type when options has resp marker" {
    comptime {
        const DeleteResp = struct { ok: bool };
        const Result = @TypeOf(
            @as(*Self, undefined).delete(
                .url("https://example.com"),
                .headers(.{}),
                .{ .query = .{ .id = 1 }, .resp = DeleteResp },
            ),
        );
        if (Result != async_task(std.json.Parsed(DeleteResp))) {
            @compileError("delete(options com .resp = T) deve retornar async_task(Parsed(T))");
        }
    }

    try std.testing.expect(true);
}

test "merge_headers prepends content-type when missing in caller headers" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const caller_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
    };

    const merged = try client.merge_headers(caller_headers[0..], content_type_headers.json[0..]);
    defer if (merged.owned) |owned| allocator.free(owned);

    try std.testing.expectEqual(@as(usize, 2), merged.value.len);
    try std.testing.expectEqualStrings("content-type", merged.value[0].name);
    try std.testing.expectEqualStrings("application/json", merged.value[0].value);
    try std.testing.expectEqualStrings("accept", merged.value[1].name);
}

test "merge_headers keeps caller content-type untouched" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const caller_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "accept", .value = "application/json" },
    };

    const merged = try client.merge_headers(caller_headers[0..], content_type_headers.json[0..]);
    try std.testing.expect(merged.owned == null);
    try std.testing.expectEqual(@as(usize, 2), merged.value.len);
    try std.testing.expectEqualStrings("text/plain", merged.value[0].value);
}

test "headers arg supports authorization and content-type anonymous struct" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const headers_arg = HeadersArg.headers(.{
        .Authorization = "Token abc123",
        .@"Content-Type" = "application/json",
    });

    var effective = try client.prepare_request_headers_from_slice(
        headers_arg.slice(),
        empty_headers,
    );
    defer effective.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), effective.value.len);
    try std.testing.expectEqualStrings("Authorization", effective.value[0].name);
    try std.testing.expectEqualStrings("Token abc123", effective.value[0].value);
    try std.testing.expectEqualStrings("Content-Type", effective.value[1].name);
    try std.testing.expectEqualStrings("application/json", effective.value[1].value);
}

test "get accepts explicit authorization and content-type headers call shape" {
    comptime {
        const Task = @TypeOf(@as(*Self, undefined).get(
            .url("https://api.example.com/me"),
            .headers(.{
                .Authorization = "Token abc123",
                .@"Content-Type" = "application/json",
            }),
            .{},
        ));

        if (Task != async_task(Response)) {
            @compileError("get com headers anonimos deve retornar async_task(Response)");
        }
    }

    try std.testing.expect(true);
}

test "prepare_body ignores null optional payload" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    var prepared = try client.prepare_body(.{
        .url = "https://example.com",
        .payload = @as(?struct { id: u8 }, null),
    });
    defer prepared.deinit(allocator);

    try std.testing.expect(prepared.body == null);
    try std.testing.expectEqual(@as(usize, 0), prepared.default_headers.len);
}

test "sender transport options defaults and overrides" {
    const defaults = .{ .url = "https://example.com" };
    try std.testing.expectEqual(@as(?u64, null), sender_timeout_ms(defaults));
    try std.testing.expectEqual(@as(u8, 0), sender_retries(defaults));
    try std.testing.expectEqual(default_retry_backoff_ms, sender_retry_backoff_ms(defaults));
    try std.testing.expectEqual(default_retry_max_backoff_ms, sender_retry_max_backoff_ms(defaults));
    try std.testing.expect(sender_redirect_behavior(defaults) != .unhandled);

    const custom = .{
        .url = "https://example.com",
        .timeout_ms = @as(u64, 2500),
        .retries = @as(u8, 3),
        .retry_backoff_ms = @as(u64, 300),
        .retry_max_backoff_ms = @as(u64, 3_000),
        .redirect_policy = RedirectPolicy.manual,
        .max_redirects = @as(u16, 9),
    };

    try std.testing.expectEqual(@as(?u64, 2500), sender_timeout_ms(custom));
    try std.testing.expectEqual(@as(u8, 3), sender_retries(custom));
    try std.testing.expectEqual(@as(u64, 300), sender_retry_backoff_ms(custom));
    try std.testing.expectEqual(@as(u64, 3_000), sender_retry_max_backoff_ms(custom));
    try std.testing.expectEqual(
        std.http.Client.Request.RedirectBehavior.unhandled,
        sender_redirect_behavior(custom),
    );
}

test "client default request options roundtrip" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const default_options = client.default_request_options();
    try std.testing.expect(default_options.keep_alive);
    try std.testing.expectEqual(@as(?u64, null), default_options.timeout_ms);
    try std.testing.expectEqual(@as(u8, 0), default_options.retries);
    try std.testing.expectEqual(default_retry_backoff_ms, default_options.retry_backoff_ms);
    try std.testing.expectEqual(
        default_retry_max_backoff_ms,
        default_options.retry_max_backoff_ms,
    );
    try std.testing.expectEqual(RedirectPolicy.follow, default_options.redirect_policy);
    try std.testing.expectEqual(default_max_redirects, default_options.max_redirects);

    client.set_default_request_options(.{
        .keep_alive = false,
        .timeout_ms = 4200,
        .retries = 2,
        .retry_backoff_ms = 200,
        .retry_max_backoff_ms = 900,
        .redirect_policy = .manual,
        .max_redirects = 8,
    });

    const custom_options = client.default_request_options();
    try std.testing.expect(!custom_options.keep_alive);
    try std.testing.expectEqual(@as(?u64, 4200), custom_options.timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), custom_options.retries);
    try std.testing.expectEqual(@as(u64, 200), custom_options.retry_backoff_ms);
    try std.testing.expectEqual(@as(u64, 900), custom_options.retry_max_backoff_ms);
    try std.testing.expectEqual(RedirectPolicy.manual, custom_options.redirect_policy);
    try std.testing.expectEqual(@as(u16, 8), custom_options.max_redirects);
}

test "request option resolution uses client defaults" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    client.set_default_request_options(.{
        .keep_alive = false,
        .timeout_ms = 1111,
        .retries = 4,
        .retry_backoff_ms = 333,
        .retry_max_backoff_ms = 999,
        .redirect_policy = .fail,
        .max_redirects = 12,
    });

    const plain_sender = .{ .url = "https://example.com" };
    try std.testing.expect(!client.request_keep_alive(plain_sender));
    try std.testing.expectEqual(@as(?u64, 1111), client.request_timeout_ms(plain_sender));
    try std.testing.expectEqual(@as(u8, 4), client.request_retries(plain_sender));
    try std.testing.expectEqual(@as(u64, 333), client.request_retry_backoff_ms(plain_sender));
    try std.testing.expectEqual(@as(u64, 999), client.request_retry_max_backoff_ms(plain_sender));
    try std.testing.expectEqual(
        std.http.Client.Request.RedirectBehavior.not_allowed,
        client.request_redirect_behavior(plain_sender),
    );

    const override_sender = .{
        .url = "https://example.com",
        .keep_alive = true,
        .timeout_ms = @as(u64, 500),
        .retries = @as(u8, 1),
        .retry_backoff_ms = @as(u64, 40),
        .retry_max_backoff_ms = @as(u64, 80),
        .redirect_policy = RedirectPolicy.manual,
        .max_redirects = @as(u16, 2),
    };

    try std.testing.expect(client.request_keep_alive(override_sender));
    try std.testing.expectEqual(@as(?u64, 500), client.request_timeout_ms(override_sender));
    try std.testing.expectEqual(@as(u8, 1), client.request_retries(override_sender));
    try std.testing.expectEqual(@as(u64, 40), client.request_retry_backoff_ms(override_sender));
    try std.testing.expectEqual(@as(u64, 80), client.request_retry_max_backoff_ms(override_sender));
    try std.testing.expectEqual(
        std.http.Client.Request.RedirectBehavior.unhandled,
        client.request_redirect_behavior(override_sender),
    );
}

test "async get honors client default timeout/retry options" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    client.set_default_request_options(.{
        .timeout_ms = 0,
        .retries = 1,
        .retry_backoff_ms = 0,
        .retry_max_backoff_ms = 0,
    });

    try std.testing.expectError(
        error.RequestTimedOut,
        client.get(.url("http://127.0.0.1:1"), .headers(.{}), .{}).await(),
    );
}

test "async get uses caller client allocator and cookie state" {
    var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const failing_allocator = failing_allocator_state.allocator();

    var client: Self = undefined;
    try client.init(failing_allocator);
    defer client.deinit();

    try client.enable_cookies();
    try client.cookie_jar.?.set("session", "abc123");

    failing_allocator_state.fail_index = failing_allocator_state.alloc_index;

    const result = client.get(.url("http://127.0.0.1:1"), .headers(.{}), .{}).await();
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
    }
}

test "retry options sanitize zero and inverted backoff bounds" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    client.set_default_request_options(.{
        .retries = 3,
        .retry_backoff_ms = 0,
        .retry_max_backoff_ms = 10,
    });

    const plain_sender = .{ .url = "https://example.com" };
    const zero_backoff = client.build_retry_options(plain_sender, null);
    try std.testing.expectEqual(@as(u8, 3), zero_backoff.retries);
    try std.testing.expectEqual(default_retry_backoff_ms, zero_backoff.base_backoff_ms);
    try std.testing.expectEqual(default_retry_backoff_ms, zero_backoff.max_backoff_ms);

    client.set_default_request_options(.{
        .retries = 1,
        .retry_backoff_ms = 500,
        .retry_max_backoff_ms = 100,
    });

    const inverted_window = client.build_retry_options(plain_sender, null);
    try std.testing.expectEqual(@as(u64, 500), inverted_window.base_backoff_ms);
    try std.testing.expectEqual(@as(u64, 500), inverted_window.max_backoff_ms);
}

test "redirect behavior mapping" {
    const follow = sender_redirect_behavior(.{
        .url = "https://example.com",
        .redirect_policy = RedirectPolicy.follow,
        .max_redirects = @as(u16, 0),
    });
    try std.testing.expectEqual(std.http.Client.Request.RedirectBehavior.not_allowed, follow);

    const fail = sender_redirect_behavior(.{
        .url = "https://example.com",
        .redirect_policy = RedirectPolicy.fail,
    });
    try std.testing.expectEqual(std.http.Client.Request.RedirectBehavior.not_allowed, fail);
}

test "retry policy only retries idempotent methods" {
    try std.testing.expect(should_retry_request(.GET, error.ConnectionTimedOut));
    try std.testing.expect(!should_retry_request(.POST, error.ConnectionTimedOut));
}

test "backoff with jitter stays bounded" {
    const one = compute_backoff_with_jitter_ms(1, 100, 500);
    const two = compute_backoff_with_jitter_ms(2, 100, 500);
    const many = compute_backoff_with_jitter_ms(8, 100, 500);

    try std.testing.expect(one >= 100 and one <= 125);
    try std.testing.expect(two >= 200 and two <= 250);
    try std.testing.expect(many >= 500 and many <= 500);
}

test "response json parse into interface struct" {
    const allocator = std.testing.allocator;

    var response: Response = .{
        .allocator = allocator,
        .status = .ok,
        .body = try allocator.dupe(u8, "{\"id\":7,\"name\":\"maria\",\"extra\":\"x\"}"),
    };
    defer response.deinit();

    const User = struct {
        id: u32,
        name: []const u8,
    };

    var parsed = try response.json(User);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 7), parsed.value.id);
    try std.testing.expectEqualStrings("maria", parsed.value.name);
}

test "response json printer helpers format and write" {
    const allocator = std.testing.allocator;

    var response: Response = .{
        .allocator = allocator,
        .status = .ok,
        .body = try allocator.dupe(u8, "{\"id\":1,\"name\":\"ana\"}"),
    };
    defer response.deinit();

    const pretty = try response.json_formatted(.{
        .style = .pretty,
        .append_newline = false,
    });
    defer allocator.free(pretty);
    try std.testing.expect(std.mem.indexOfScalar(u8, pretty, '\n') != null);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try response.json_write_to(&out.writer, .{
        .style = .compact,
        .append_newline = false,
    });
    const compact = try out.toOwnedSlice();
    defer allocator.free(compact);
    try std.testing.expectEqualStrings("{\"id\":1,\"name\":\"ana\"}", compact);
}

test "typed one-shot parse helper" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const User = struct {
        id: u32,
        name: []const u8,
    };

    var parsed = try parse_json_response_of(.{
        .allocator = allocator,
        .status = .ok,
        .body = try allocator.dupe(u8, "{\"id\":1,\"name\":\"anna\"}"),
    }, User);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.id);
    try std.testing.expectEqualStrings("anna", parsed.value.name);
}

test "post returns async_task with await method" {
    comptime {
        const PostResp = struct { ok: bool };
        const Task = @TypeOf(
            @as(*Self, undefined).post(
                .url("https://example.com"),
                .headers(.{}),
                .{ .json = .{ .name = "ana" }, .resp = PostResp },
            ),
        );
        if (!@hasField(Task, "inner")) @compileError("async_task deve ter campo inner");
        if (!@hasDecl(Task, "await")) @compileError("async_task deve ter metodo await");
    }

    try std.testing.expect(true);
}

test "get returns async_task with raw Response when no resp marker" {
    comptime {
        const Task = @TypeOf(
            @as(*Self, undefined).get(.url("https://example.com"), .headers(.{}), .{}),
        );
        if (Task != async_task(Response)) {
            @compileError("get sem resp deve produzir async_task(Response)");
        }
    }

    try std.testing.expect(true);
}

test "send_now returns raw response when sender has no marker" {
    comptime {
        const ResultType = @typeInfo(@TypeOf(
            @as(*Self, undefined).send_now(.GET, .url("https://example.com"), .headers(.{}), .{}),
        )).error_union.payload;

        if (ResultType != Response) {
            @compileError("send_now sem resp deve produzir Response");
        }
    }

    try std.testing.expect(true);
}

test "send_now infers parsed response when sender has resp" {
    comptime {
        const Echo = struct {
            origin: []const u8 = "",
        };

        const ResultType = @typeInfo(@TypeOf(
            @as(*Self, undefined).send_now(
                .GET,
                .url("https://example.com"),
                .headers(.{}),
                .{ .resp = Echo },
            ),
        )).error_union.payload;

        if (ResultType != std.json.Parsed(Echo)) {
            @compileError("send_now com resp deve produzir std.json.Parsed(T)");
        }
    }

    try std.testing.expect(true);
}

test "put patch delete compile with resp marker" {
    comptime {
        const R = struct { id: u32 };

        _ = @TypeOf(@as(*Self, undefined).put(
            .url("https://example.com"),
            .headers(.{}),
            .{ .json = .{ .id = 1 }, .resp = R },
        ));
        _ = @TypeOf(@as(*Self, undefined).patch(
            .url("https://example.com"),
            .headers(.{}),
            .{ .json = .{ .id = 1 }, .resp = R },
        ));
        _ = @TypeOf(@as(*Self, undefined).delete(
            .url("https://example.com"),
            .headers(.{}),
            .{ .resp = R },
        ));
    }

    try std.testing.expect(true);
}

test "real httpbin roundtrip (opt-in)" {
    const allocator = std.testing.allocator;
    if (!should_run_real_http_tests(allocator)) return;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    const EchoPayload = struct {
        name: []const u8,
        age: u8,
    };

    const EchoResponse = struct {
        method: []const u8 = "",
        args: struct {
            name: []const u8 = "",
            page: []const u8 = "",
            age: []const u8 = "",
        } = .{},
        json: ?EchoPayload = null,
    };

    var get_response = client.get(
        .url("https://httpbin.org/anything"),
        .headers(.{}),
        .{ .query = .{ .name = "zig", .page = 1 }, .resp = EchoResponse },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer get_response.deinit();
    try std.testing.expectEqualStrings("GET", get_response.value.method);
    try std.testing.expectEqualStrings("zig", get_response.value.args.name);
    try std.testing.expectEqualStrings("1", get_response.value.args.page);

    const post_payload = EchoPayload{ .name = "post_name", .age = 11 };
    var post_result = client.post(
        .url("https://httpbin.org/anything"),
        .headers(.{}),
        .{ .payload = post_payload, .return_of = return_of(EchoResponse) },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer post_result.deinit();
    try std.testing.expectEqualStrings("POST", post_result.value.method);
    try std.testing.expect(post_result.value.json != null);
    try std.testing.expectEqualStrings("post_name", post_result.value.json.?.name);
    try std.testing.expectEqual(@as(u8, 11), post_result.value.json.?.age);

    var post_result_as = client.post(
        .url("https://httpbin.org/anything"),
        .headers(.{}),
        .{ .payload = post_payload, .resp = EchoResponse },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer post_result_as.deinit();
    try std.testing.expectEqualStrings("POST", post_result_as.value.method);
    try std.testing.expect(post_result_as.value.json != null);
    try std.testing.expectEqualStrings("post_name", post_result_as.value.json.?.name);
    try std.testing.expectEqual(@as(u8, 11), post_result_as.value.json.?.age);

    const put_payload = EchoPayload{ .name = "put_name", .age = 22 };
    var put_result = client.put(
        .url("https://httpbin.org/anything"),
        .headers(.{}),
        .{ .payload = put_payload, .resp = EchoResponse },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer put_result.deinit();
    try std.testing.expectEqualStrings("PUT", put_result.value.method);
    try std.testing.expect(put_result.value.json != null);
    try std.testing.expectEqualStrings("put_name", put_result.value.json.?.name);
    try std.testing.expectEqual(@as(u8, 22), put_result.value.json.?.age);

    const patch_payload = EchoPayload{ .name = "patch_name", .age = 33 };
    var patch_result = client.patch(
        .url("https://httpbin.org/anything"),
        .headers(.{}),
        .{ .payload = patch_payload, .resp = EchoResponse },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer patch_result.deinit();
    try std.testing.expectEqualStrings("PATCH", patch_result.value.method);
    try std.testing.expect(patch_result.value.json != null);
    try std.testing.expectEqualStrings("patch_name", patch_result.value.json.?.name);
    try std.testing.expectEqual(@as(u8, 33), patch_result.value.json.?.age);

    var delete_result = client.delete(
        .url("https://httpbin.org/anything"),
        .headers(.{}),
        .{ .query = .{ .name = "delete_name", .age = 44 }, .resp = EchoResponse },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer delete_result.deinit();
    try std.testing.expectEqualStrings("DELETE", delete_result.value.method);
    try std.testing.expectEqualStrings("delete_name", delete_result.value.args.name);
    try std.testing.expectEqualStrings("44", delete_result.value.args.age);

    const IpResponse = struct {
        origin: []const u8 = "",
    };

    var raw_ip = client.get(.url("https://httpbin.org/ip"), .headers(.{}), .{}).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer raw_ip.deinit();
    try std.testing.expect(raw_ip.status_code() == 200);

    var ip_typed = client.get(
        .url("https://httpbin.org/ip"),
        .headers(.{}),
        .{ .resp = IpResponse },
    ).await() catch |err| {
        if (should_skip_real_http_error(err)) return;
        return err;
    };
    defer ip_typed.deinit();
    try std.testing.expect(ip_typed.value.origin.len > 0);
}

test "method without body returns explicit error" {
    const allocator = std.testing.allocator;

    var client: Self = undefined;
    try client.init(allocator);
    defer client.deinit();

    try std.testing.expectError(
        error.MethodDoesNotSupportBody,
        client.delete(
            .url("https://example.com"),
            .headers(.{}),
            .{ .body = "{}" },
        ).await(),
    );
}
