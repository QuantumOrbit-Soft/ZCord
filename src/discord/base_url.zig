const std = @import("std");

allocator: std.mem.Allocator,
value: []u8,

pub const BaseUrl = @This();

pub fn init(
    target: *BaseUrl,
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    target.* = .{
        .allocator = allocator,
        .value = try allocator.dupe(u8, value),
    };
}

pub fn deinit(self: *BaseUrl) void {
    self.allocator.free(self.value);
    self.* = undefined;
}

pub fn slice(self: *const BaseUrl) []const u8 {
    return self.value;
}

test "BaseUrl owns normalized base url value" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, "https://discord.com/api/v10");
    defer allocator.free(source);

    var base_url: BaseUrl = undefined;
    try base_url.init(allocator, source);
    defer base_url.deinit();

    try std.testing.expectEqualStrings("https://discord.com/api/v10", base_url.slice());
}

test "BaseUrl keeps trailing slash when caller provides it" {
    var base_url: BaseUrl = undefined;
    try base_url.init(std.testing.allocator, "https://discord.com/api/v10/");
    defer base_url.deinit();

    try std.testing.expectEqualStrings("https://discord.com/api/v10/", base_url.slice());
}
