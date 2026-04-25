const std = @import("std");

allocator: std.mem.Allocator,
value: []u8,

pub const AuthorizationHeader = @This();

pub fn init(
    target: *AuthorizationHeader,
    allocator: std.mem.Allocator,
    token_prefix: []const u8,
    token: []const u8,
) std.mem.Allocator.Error!void {
    const value = if (0 < token_prefix.len)
        try std.fmt.allocPrint(allocator, "{s} {s}", .{ token_prefix, token })
    else
        try allocator.dupe(u8, token);

    target.* = .{
        .allocator = allocator,
        .value = value,
    };
}

pub fn deinit(self: *AuthorizationHeader) void {
    self.allocator.free(self.value);
    self.* = undefined;
}

pub fn slice(self: *const AuthorizationHeader) []const u8 {
    return self.value;
}

test "AuthorizationHeader prefixes bot token" {
    var header: AuthorizationHeader = undefined;
    try header.init(std.testing.allocator, "Bot", "abc");
    defer header.deinit();

    try std.testing.expectEqualStrings("Bot abc", header.slice());
}

test "AuthorizationHeader accepts empty prefix" {
    var header: AuthorizationHeader = undefined;
    try header.init(std.testing.allocator, "", "abc");
    defer header.deinit();

    try std.testing.expectEqualStrings("abc", header.slice());
}
