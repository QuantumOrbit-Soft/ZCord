const std = @import("std");

allocator: std.mem.Allocator,
value: []u8,

pub const UserAgentHeader = @This();

pub fn init(
    target: *UserAgentHeader,
    allocator: std.mem.Allocator,
    user_agent: []const u8,
) std.mem.Allocator.Error!void {
    target.* = .{
        .allocator = allocator,
        .value = try allocator.dupe(u8, user_agent),
    };
}

pub fn deinit(self: *UserAgentHeader) void {
    self.allocator.free(self.value);
    self.* = undefined;
}

pub fn slice(self: *const UserAgentHeader) []const u8 {
    return self.value;
}

test "UserAgentHeader owns user-agent value" {
    var header: UserAgentHeader = undefined;
    try header.init(std.testing.allocator, "ZCord/0.1");
    defer header.deinit();

    try std.testing.expectEqualStrings("ZCord/0.1", header.slice());
}

test "UserAgentHeader preserves empty value for backwards compatibility" {
    var header: UserAgentHeader = undefined;
    try header.init(std.testing.allocator, "");
    defer header.deinit();

    try std.testing.expectEqualStrings("", header.slice());
}
