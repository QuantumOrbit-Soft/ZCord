const std = @import("std");
const assert = std.debug.assert;

buffer: []u8,
bytes: []const u8,

pub const JsonBody = @This();
pub const Error = error{
    JsonBodyTooLarge,
};

pub fn init(
    target: *JsonBody,
    buffer: []u8,
    comptime Payload: type,
    payload: Payload,
) Error!void {
    assert(buffer.len > 0);

    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(
        payload,
        .{ .emit_null_optional_fields = false },
        &writer,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.JsonBodyTooLarge,
    };

    target.* = .{
        .buffer = buffer,
        .bytes = writer.buffered(),
    };

    assert(target.bytes.len <= target.buffer.len);
}

pub fn deinit(self: *JsonBody) void {
    assert(self.bytes.len <= self.buffer.len);
    @memset(self.buffer[0..self.bytes.len], 0);
    self.* = undefined;
}

pub fn slice(self: *const JsonBody) []const u8 {
    return self.bytes;
}

test "JsonBody serializes payload and omits null optionals" {
    const Payload = struct {
        content: []const u8,
        nonce: ?[]const u8 = null,
    };

    var buffer: [128]u8 = undefined;
    var body: JsonBody = undefined;
    try body.init(buffer[0..], Payload, .{ .content = "hello" });
    defer body.deinit();

    try std.testing.expectEqualStrings("{\"content\":\"hello\"}", body.slice());
}

test "JsonBody keeps explicit false boolean fields" {
    const Payload = struct {
        enabled: bool,
        note: ?[]const u8 = null,
    };

    var buffer: [128]u8 = undefined;
    var body: JsonBody = undefined;
    try body.init(buffer[0..], Payload, .{ .enabled = false });
    defer body.deinit();

    try std.testing.expectEqualStrings("{\"enabled\":false}", body.slice());
}

test "JsonBody rejects payloads larger than caller buffer" {
    const Payload = struct {
        content: []const u8,
    };

    var buffer: [8]u8 = undefined;
    var body: JsonBody = undefined;

    try std.testing.expectError(
        error.JsonBodyTooLarge,
        body.init(buffer[0..], Payload, .{ .content = "hello" }),
    );
}
