const std = @import("std");
const kv_codec = @import("kv_codec.zig");

pub const Error = error{OutOfMemory};
pub const Format = enum {
    json,
    form,
};

pub fn encode(allocator: std.mem.Allocator, payload: anytype, format: Format) Error![]u8 {
    return switch (format) {
        .json => json(allocator, payload),
        .form => post_form(allocator, payload),
    };
}

pub fn json(allocator: std.mem.Allocator, payload: anytype) Error![]u8 {
    comptime kv_codec.assert_struct_payload(@TypeOf(payload), "scratch_json");
    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

pub fn post_form(allocator: std.mem.Allocator, payload: anytype) Error![]u8 {
    comptime kv_codec.assert_struct_payload(@TypeOf(payload), "scratch_post_form");

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var wrote_any_pair = false;
    kv_codec.write_pairs_from_struct(&writer.writer, payload, &wrote_any_pair, .plus) catch {
        return error.OutOfMemory;
    };

    return writer.toOwnedSlice() catch return error.OutOfMemory;
}

test "json accepts anonymous and named structs" {
    const User = struct {
        name: []const u8,
        active: bool,
    };

    const allocator = std.testing.allocator;

    const anonymous = try json(allocator, .{ .id = 1, .name = "john" });
    defer allocator.free(anonymous);
    try std.testing.expectEqualStrings("{\"id\":1,\"name\":\"john\"}", anonymous);

    const named = try json(allocator, User{ .name = "maria", .active = true });
    defer allocator.free(named);
    try std.testing.expectEqualStrings("{\"name\":\"maria\",\"active\":true}", named);
}

test "post_form accepts anonymous and named structs" {
    const Role = enum { admin, user };
    const FormData = struct {
        role: Role,
        page: usize,
        note: ?[]const u8,
    };

    const allocator = std.testing.allocator;

    const anonymous = try post_form(allocator, .{
        .name = "John Doe",
        .age = 28,
        .active = true,
    });
    defer allocator.free(anonymous);
    try std.testing.expectEqualStrings("name=John+Doe&age=28&active=true", anonymous);

    const named = try post_form(allocator, FormData{
        .role = .admin,
        .page = 3,
        .note = null,
    });
    defer allocator.free(named);
    try std.testing.expectEqualStrings("role=admin&page=3", named);
}

test "encode delegates to json and form" {
    const allocator = std.testing.allocator;

    const as_json = try encode(allocator, .{ .id = 3 }, .json);
    defer allocator.free(as_json);
    try std.testing.expectEqualStrings("{\"id\":3}", as_json);

    const as_form = try encode(allocator, .{ .name = "john doe" }, .form);
    defer allocator.free(as_form);
    try std.testing.expectEqualStrings("name=john+doe", as_form);
}
