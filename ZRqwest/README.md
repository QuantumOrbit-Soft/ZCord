# ZRqwest

Utility HTTP client library for Zig 0.16.

This README covers the main request API only.

Core ideas:

- fixed request shape with `get/post/put/patch/delete`
- explicit headers
- raw or typed responses
- `RequestBuilder` for incremental request assembly

## Requirements

- Zig `0.16.0`

## Installation

```bash
zig fetch --save git+https://github.com/Ahegys/zrqwest.git
```

In `build.zig`:

```zig
const zrqwest_dep = b.dependency("zrqwest", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zrqwest", zrqwest_dep.module("zrqwest"));
```

## Import

```zig
const zrqwest = @import("zrqwest");
```

## Creating the client

With your own allocator:

```zig
var client: zrqwest.RequestClient = undefined;
try client.init(allocator);
defer client.deinit();
```

With `page_allocator`:

```zig
var client = try zrqwest.RequestClient.new();
defer client.deinit();
```

## Simple GET

```zig
var resp = try client.get(
    .url("https://httpbin.org/ip"),
    .headers(.{}),
    .{},
).await();
defer resp.deinit();

std.debug.print("status={d}\n", .{resp.status_code()});
std.debug.print("body={s}\n", .{resp.body});
```

## GET with explicit headers

Headers are always provided manually. The library does not try to abstract auth.

```zig
var resp = try client.get(
    .url("https://api.example.com/me"),
    .headers(.{
        .@"Authorization" = "Token abc123",
        .@"Content-Type" = "application/json",
    }),
    .{},
).await();
defer resp.deinit();
```

## Typed response with `.resp`

```zig
const IpResponse = struct {
    origin: []const u8 = "",
};

var parsed = try client.get(
    .url("https://httpbin.org/ip"),
    .headers(.{}),
    .{ .resp = IpResponse },
).await();
defer parsed.deinit();

std.debug.print("ip={s}\n", .{parsed.value.origin});
```

## Typed response with `return_of`

```zig
var parsed = try client.get(
    .url("https://httpbin.org/ip"),
    .headers(.{}),
    .{ .return_of = zrqwest.return_of(struct { origin: []const u8 }) },
).await();
defer parsed.deinit();
```

## POST with JSON

```zig
const CreateUserResponse = struct {
    id: u64 = 0,
    name: []const u8 = "",
};

var created = try client.post(
    .url("https://api.example.com/users"),
    .headers(.{
        .@"Content-Type" = "application/json",
    }),
    .{
        .json = .{ .name = "Alice" },
        .resp = CreateUserResponse,
    },
).await();
defer created.deinit();
```

## Other methods

The same shape applies to `put`, `patch`, and `delete`.

```zig
_ = client.put(.url("https://api.example.com/users/1"), .headers(.{}), .{});
_ = client.patch(.url("https://api.example.com/users/1"), .headers(.{}), .{});
_ = client.delete(.url("https://api.example.com/users/1"), .headers(.{}), .{});
```

## Fields accepted in `options`

The third argument is an options struct.

Main fields:

- `.query`
- `.body`
- `.payload`
- `.payload_kind`
- `.json`
- `.form`
- `.multipart`
- `.resp`
- `.return_of`
- `.keep_alive`
- `.timeout_ms`
- `.retries`
- `.retry_backoff_ms`
- `.retry_max_backoff_ms`
- `.redirect_policy`
- `.max_redirects`

Important rules:

- `.url(...)` and `.headers(...)` are passed outside `options`
- `.json` and `.form` are mutually exclusive
- `.resp` and `.return_of` are mutually exclusive
- `GET` and `DELETE` do not accept request bodies

## Response

When you do not use `.resp` or `.return_of`, the result type is `zrqwest.Response`.

Main helpers:

- `resp.status_code()`
- `resp.is_success()`
- `resp.json(T)`
- `resp.json_with_options(T, options)`
- `resp.json_formatted(options)`
- `resp.json_write_to(writer, options)`
- `resp.deinit()`

## RequestBuilder

Use `RequestBuilder` when you want to assemble a request step by step.

```zig
var rb = zrqwest.request_builder(&client, .POST, "https://api.example.com/users");
defer rb.deinit();

try rb.header("accept", "application/json");
try rb.json(.{ .name = "Alice" });
rb.set_timeout_ms(3000);
rb.retries(2);

const UserResponse = struct {
    id: u64 = 0,
    name: []const u8 = "",
};

var parsed = try rb.send_json(UserResponse);
defer parsed.deinit();
```

Main builder methods:

- `header(name, value)`
- `query(.{ ... })`
- `body(raw)`
- `json(payload)`
- `form(payload)`
- `multipart(parts)`
- `set_keep_alive(bool)`
- `set_timeout_ms(?u64)`
- `retries(u8)`
- `set_retry_backoff_ms(u64)`
- `set_retry_max_backoff_ms(u64)`
- `set_redirect_policy(policy)`
- `set_max_redirects(u16)`
- `send()`
- `send_json(T)`

## Useful helpers

- `client.scratch_json(payload)`
- `client.scratch_post_form(payload)`
- `client.build_query(base_url, query)`
- `client.stream(.url(...), .headers(...), .{ ... })`
- `client.stream_to(.url(...), .headers(...), .{ ... }, writer)`

## Compile-time contracts

For open extension points:

```zig
comptime zrqwest.TransportContract.assert(MyTransport);
comptime zrqwest.CacheContract.assert(MyCache);
```

## Tests

```bash
zig build
zig build test --summary all
```
