const std = @import("std");

auth_header_value: []const u8,
user_agent_header_value: []const u8,

pub const init_params = struct {
    auth_header_value: []const u8,
    user_agent_header_value: []const u8,
};

pub const HeaderSet = @This();

pub fn init(target: *HeaderSet, params: init_params) void {
    target.* = .{
        .auth_header_value = params.auth_header_value,
        .user_agent_header_value = params.user_agent_header_value,
    };
}

pub fn authorized(self: *const HeaderSet) [2]std.http.Header {
    return .{
        .{ .name = "authorization", .value = self.auth_header_value },
        .{ .name = "user-agent", .value = self.user_agent_header_value },
    };
}

pub fn authorized_json(self: *const HeaderSet) [3]std.http.Header {
    return .{
        .{ .name = "authorization", .value = self.auth_header_value },
        .{ .name = "user-agent", .value = self.user_agent_header_value },
        .{ .name = "content-type", .value = "application/json" },
    };
}

pub fn public(self: *const HeaderSet) [1]std.http.Header {
    return .{
        .{ .name = "user-agent", .value = self.user_agent_header_value },
    };
}

pub fn public_json(self: *const HeaderSet) [2]std.http.Header {
    return .{
        .{ .name = "user-agent", .value = self.user_agent_header_value },
        .{ .name = "content-type", .value = "application/json" },
    };
}

test "HeaderSet builds authorized headers" {
    var headers: HeaderSet = undefined;
    headers.init(.{
        .auth_header_value = "Bot token",
        .user_agent_header_value = "ZCord",
    });

    const values = headers.authorized();

    try std.testing.expectEqualStrings("authorization", values[0].name);
    try std.testing.expectEqualStrings("Bot token", values[0].value);
    try std.testing.expectEqualStrings("user-agent", values[1].name);
    try std.testing.expectEqualStrings("ZCord", values[1].value);
}

test "HeaderSet builds json headers with explicit content type" {
    var headers: HeaderSet = undefined;
    headers.init(.{
        .auth_header_value = "Bot token",
        .user_agent_header_value = "ZCord",
    });

    const values = headers.authorized_json();

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("content-type", values[2].name);
    try std.testing.expectEqualStrings("application/json", values[2].value);
}

test "HeaderSet builds public json headers without authorization" {
    var headers: HeaderSet = undefined;
    headers.init(.{
        .auth_header_value = "Bot token",
        .user_agent_header_value = "ZCord",
    });

    const values = headers.public_json();

    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("user-agent", values[0].name);
    try std.testing.expectEqualStrings("content-type", values[1].name);
}
