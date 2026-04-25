const std = @import("std");
const zrqwest = @import("zrqwest");
const DiscordHttpClient = @import("../discord/http_client.zig").DiscordHttpClient;
const DiscordResult = @import("../discord/result.zig").DiscordResult;
const models = @import("../models/mod.zig");
const Routes = @import("../routes/mod.zig").Routes;

allocator: std.mem.Allocator,
client: *DiscordHttpClient,

pub const UsersResource = @This();

pub const User = models.User;
pub const get_current_user_result = DiscordResult.Of(User);

const Self = @This();

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    client: *DiscordHttpClient,
) void {
    self.* = .{
        .allocator = allocator,
        .client = client,
    };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn get_current_user(self: *Self) !get_current_user_result {
    const response = try self.client.get(Routes.users.current_user);
    return self.current_user_result_from_response(response);
}

fn current_user_result_from_response(
    self: *Self,
    response: zrqwest.Response,
) !get_current_user_result {
    return get_current_user_result.from_zrqwest_response(self.allocator, response);
}

test "UsersResource follows TigerStyle file-as-type pattern" {
    comptime {
        try std.testing.expect(@hasDecl(UsersResource, "init"));
        try std.testing.expect(@hasDecl(UsersResource, "deinit"));
        try std.testing.expect(@hasDecl(UsersResource, "get_current_user"));
        try std.testing.expect(@hasDecl(UsersResource, "User"));
        try std.testing.expect(@hasDecl(UsersResource, "get_current_user_result"));
    }
}

test "UsersResource has minimal state" {
    comptime {
        const fields = @typeInfo(UsersResource).@"struct".fields;
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("allocator", fields[0].name);
        try std.testing.expectEqualStrings("client", fields[1].name);
    }
}

test "UsersResource current-user route comes from centralized Routes module" {
    try std.testing.expectEqualStrings(
        Routes.users.current_user,
        "/users/@me",
    );
}

test "UsersResource parses current user response with single response owner" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "{\"id\":\"42\",\"username\":\"zig\"}");

    var fake_client: DiscordHttpClient = undefined;
    var users: UsersResource = undefined;
    users.init(allocator, &fake_client);

    var result = try users.current_user_result_from_response(.{
        .allocator = allocator,
        .status = .ok,
        .body = body,
    });
    defer result.deinit();

    const user = result.data() orelse unreachable;
    try std.testing.expectEqualStrings("42", user.id);
    try std.testing.expectEqualStrings("zig", user.username);
}
