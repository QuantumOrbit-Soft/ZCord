const std = @import("std");

allocator: std.mem.Allocator,
bytes: []u8,

pub const JsonBody = @This();

pub fn init(
    target: *JsonBody,
    allocator: std.mem.Allocator,
    comptime Payload: type,
    payload: Payload,
) std.mem.Allocator.Error!void {
    const bytes = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{ .emit_null_optional_fields = false },
    );

    target.* = .{
        .allocator = allocator,
        .bytes = bytes,
    };
}

pub fn deinit(self: *JsonBody) void {
    self.allocator.free(self.bytes);
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

    var body: JsonBody = undefined;
    try body.init(std.testing.allocator, Payload, .{ .content = "hello" });
    defer body.deinit();

    try std.testing.expectEqualStrings("{\"content\":\"hello\"}", body.slice());
}

test "JsonBody keeps explicit false boolean fields" {
    const Payload = struct {
        enabled: bool,
        note: ?[]const u8 = null,
    };

    var body: JsonBody = undefined;
    try body.init(std.testing.allocator, Payload, .{ .enabled = false });
    defer body.deinit();

    try std.testing.expectEqualStrings("{\"enabled\":false}", body.slice());
}
