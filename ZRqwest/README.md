# ZRqwest

Biblioteca utilitária de HTTP para Zig 0.16.

O foco da API e simples:

- requests com `get/post/put/patch/delete`
- headers explicitos
- resposta raw ou tipada
- `RequestBuilder` para montagem incremental

Esta README cobre so a parte principal de request da lib.

## Requisitos

- Zig `0.16.0`

## Instalacao

```bash
zig fetch --save git+https://github.com/Ahegys/zrqwest.git
```

No `build.zig`:

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

## Criando o client

Com allocator proprio:

```zig
var client: zrqwest.RequestClient = undefined;
try client.init(allocator);
defer client.deinit();
```

Com `page_allocator`:

```zig
var client = try zrqwest.RequestClient.new();
defer client.deinit();
```

## GET simples

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

## GET com headers explicitos

Os headers sao enviados manualmente. A lib nao tenta abstrair auth.

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

## Resposta tipada com `.resp`

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

## Resposta tipada com `return_of`

```zig
var parsed = try client.get(
    .url("https://httpbin.org/ip"),
    .headers(.{}),
    .{ .return_of = zrqwest.return_of(struct { origin: []const u8 }) },
).await();
defer parsed.deinit();
```

## POST com JSON

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

## Outros metodos

O mesmo formato vale para `put`, `patch` e `delete`.

```zig
_ = client.put(.url("https://api.example.com/users/1"), .headers(.{}), .{});
_ = client.patch(.url("https://api.example.com/users/1"), .headers(.{}), .{});
_ = client.delete(.url("https://api.example.com/users/1"), .headers(.{}), .{});
```

## Campos aceitos em `options`

O terceiro argumento da request e um struct com opcionais.

Campos principais:

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

Regras importantes:

- `.url(...)` e `.headers(...)` sao passados fora de `options`
- `.json` e `.form` sao mutuamente exclusivos
- `.resp` e `.return_of` sao mutuamente exclusivos
- `GET` e `DELETE` nao aceitam body

## Response

Quando voce nao usa `.resp` nem `.return_of`, o retorno e `zrqwest.Response`.

Helpers principais:

- `resp.status_code()`
- `resp.is_success()`
- `resp.json(T)`
- `resp.json_with_options(T, options)`
- `resp.json_formatted(options)`
- `resp.json_write_to(writer, options)`
- `resp.deinit()`

## RequestBuilder

Para montar a request por etapas:

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

Metodos principais do builder:

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

## Helpers uteis

- `client.scratch_json(payload)`
- `client.scratch_post_form(payload)`
- `client.build_query(base_url, query)`
- `client.stream(.url(...), .headers(...), .{ ... })`
- `client.stream_to(.url(...), .headers(...), .{ ... }, writer)`

## Contracts

Para extensao aberta em `comptime`:

```zig
comptime zrqwest.TransportContract.assert(MyTransport);
comptime zrqwest.CacheContract.assert(MyCache);
```

## Testes

```bash
zig build
zig build test --summary all
```
