const std = @import("std");
const zrqwest = @import("zrqwest");

pub const DiscordResult = @This();

pub const Empty = struct {
    allocator: std.mem.Allocator,
    success: bool,
    status_code: u16,
    error_body_or_null: ?[]u8 = null,

    const Self = @This();

    pub fn from_zrqwest_response(
        allocator: std.mem.Allocator,
        response: zrqwest.Response,
    ) !Self {
        var owned_response = response;
        defer owned_response.deinit();

        const status_code = owned_response.status_code();
        var result = Self{
            .allocator = allocator,
            .success = status_code >= 200 and status_code < 300,
            .status_code = status_code,
        };

        if (result.success) {
            return result;
        }

        if (0 < owned_response.body.len) {
            result.error_body_or_null = try allocator.dupe(u8, owned_response.body);
        }

        return result;
    }

    pub fn error_body(self: *const Self) ?[]const u8 {
        const body = self.error_body_or_null orelse return null;
        return body;
    }

    pub fn deinit(self: *Self) void {
        if (self.error_body_or_null) |body| {
            self.allocator.free(body);
        }
        self.* = undefined;
    }
};

pub fn Of(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        success: bool,
        status_code: u16,
        parsed_or_null: ?std.json.Parsed(T) = null,
        error_body_or_null: ?[]u8 = null,

        const Self = @This();

        pub fn from_zrqwest_response(
            allocator: std.mem.Allocator,
            response: zrqwest.Response,
        ) !Self {
            var owned_response = response;
            defer owned_response.deinit();

            const status_code = owned_response.status_code();

            var result = Self{
                .allocator = allocator,
                .success = status_code >= 200 and status_code < 300,
                .status_code = status_code,
            };

            if (result.success) {
                result.parsed_or_null = try std.json.parseFromSlice(
                    T,
                    allocator,
                    owned_response.body,
                    .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    },
                );
            } else {
                result.error_body_or_null = try allocator.dupe(u8, owned_response.body);
            }

            return result;
        }

        pub fn data(self: *const Self) ?T {
            const parsed = self.parsed_or_null orelse return null;
            return parsed.value;
        }

        pub fn error_body(self: *const Self) ?[]const u8 {
            const body = self.error_body_or_null orelse return null;
            return body;
        }

        pub fn deinit(self: *Self) void {
            if (self.parsed_or_null) |*parsed| {
                parsed.deinit();
            }
            if (self.error_body_or_null) |body| {
                self.allocator.free(body);
            }
            self.* = undefined;
        }
    };
}

test "DiscordResult.from_zrqwest_response parses 2xx payload" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: []const u8,
        username: []const u8,
    };

    const ResultType = DiscordResult.Of(User);
    const body = try allocator.dupe(u8, "{\"id\":\"42\",\"username\":\"ziggy\"}");

    var result = try ResultType.from_zrqwest_response(allocator, .{
        .allocator = allocator,
        .status = .ok,
        .body = body,
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    const user = result.data() orelse unreachable;
    try std.testing.expectEqualStrings("42", user.id);
    try std.testing.expectEqualStrings("ziggy", user.username);
}

test "DiscordResult.from_zrqwest_response keeps non-2xx body" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: []const u8,
    };

    const ResultType = DiscordResult.Of(User);
    const body = try allocator.dupe(u8, "{\"message\":\"401: Unauthorized\"}");

    var result = try ResultType.from_zrqwest_response(allocator, .{
        .allocator = allocator,
        .status = .unauthorized,
        .body = body,
    });
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expect(result.data() == null);
    try std.testing.expectEqual(@as(u16, 401), result.status_code);
    try std.testing.expectEqualStrings(
        "{\"message\":\"401: Unauthorized\"}",
        result.error_body() orelse unreachable,
    );
}

test "DiscordResult.from_zrqwest_response returns error on malformed success payload" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: []const u8,
    };

    const ResultType = DiscordResult.Of(User);
    const body = try allocator.dupe(u8, "{\"id\":");

    const maybe_result = ResultType.from_zrqwest_response(allocator, .{
        .allocator = allocator,
        .status = .ok,
        .body = body,
    }) catch null;
    try std.testing.expect(maybe_result == null);
}

test "DiscordResult.Empty handles no-content success" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "");

    var result = try DiscordResult.Empty.from_zrqwest_response(allocator, .{
        .allocator = allocator,
        .status = .no_content,
        .body = body,
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u16, 204), result.status_code);
    try std.testing.expect(result.error_body() == null);
}

test "DiscordResult.Empty keeps non-2xx body" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "{\"message\":\"Missing Access\"}");

    var result = try DiscordResult.Empty.from_zrqwest_response(allocator, .{
        .allocator = allocator,
        .status = .forbidden,
        .body = body,
    });
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u16, 403), result.status_code);
    try std.testing.expectEqualStrings(
        "{\"message\":\"Missing Access\"}",
        result.error_body() orelse unreachable,
    );
}
