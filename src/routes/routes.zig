const std = @import("std");
const PathBuilder = @import("path_builder.zig").PathBuilder;

pub const Routes = @This();

pub const build_path_error = error{
    EmptyRouteParam,
    InvalidRouteParam,
    PathBufferTooSmall,
};

pub const users = struct {
    pub const current_user = "/users/@me";
};

pub const channels = struct {
    pub fn get(path_buffer: []u8, channel_id: []const u8) build_path_error![]const u8 {
        try validate_route_param(channel_id);
        return write_path(path_buffer, &.{ "/channels/", channel_id });
    }
};

pub const applications = struct {
    pub fn global_commands(
        path_buffer: []u8,
        application_id: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(application_id);
        return write_path(path_buffer, &.{ "/applications/", application_id, "/commands" });
    }

    pub fn guild_commands(
        path_buffer: []u8,
        application_id: []const u8,
        guild_id: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(application_id);
        try validate_route_param(guild_id);
        return write_path(path_buffer, &.{
            "/applications/",
            application_id,
            "/guilds/",
            guild_id,
            "/commands",
        });
    }

    pub fn global_command(
        path_buffer: []u8,
        application_id: []const u8,
        command_id: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(application_id);
        try validate_route_param(command_id);
        return write_path(path_buffer, &.{
            "/applications/",
            application_id,
            "/commands/",
            command_id,
        });
    }

    pub fn guild_command(
        path_buffer: []u8,
        application_id: []const u8,
        guild_id: []const u8,
        command_id: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(application_id);
        try validate_route_param(guild_id);
        try validate_route_param(command_id);
        return write_path(path_buffer, &.{
            "/applications/",
            application_id,
            "/guilds/",
            guild_id,
            "/commands/",
            command_id,
        });
    }
};

pub const interactions = struct {
    pub fn callback(
        path_buffer: []u8,
        interaction_id: []const u8,
        interaction_token: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(interaction_id);
        try validate_encoded_route_param(interaction_token);
        return write_path(path_buffer, &.{
            "/interactions/",
            interaction_id,
            "/",
            interaction_token,
            "/callback",
        });
    }
};

pub const messages = struct {
    pub fn index(path_buffer: []u8, channel_id: []const u8) build_path_error![]const u8 {
        try validate_route_param(channel_id);
        return write_path(path_buffer, &.{ "/channels/", channel_id, "/messages" });
    }

    pub fn get(
        path_buffer: []u8,
        channel_id: []const u8,
        message_id: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(channel_id);
        try validate_route_param(message_id);
        return write_path(path_buffer, &.{ "/channels/", channel_id, "/messages/", message_id });
    }

    pub fn reaction_me(
        path_buffer: []u8,
        channel_id: []const u8,
        message_id: []const u8,
        encoded_emoji: []const u8,
    ) build_path_error![]const u8 {
        try validate_route_param(channel_id);
        try validate_route_param(message_id);
        try validate_encoded_route_param(encoded_emoji);
        return write_path(path_buffer, &.{
            "/channels/",
            channel_id,
            "/messages/",
            message_id,
            "/reactions/",
            encoded_emoji,
            "/@me",
        });
    }
};

fn validate_route_param(param: []const u8) build_path_error!void {
    if (0 < param.len) {} else return error.EmptyRouteParam;

    for (param) |byte| {
        if (std.ascii.isDigit(byte)) {} else return error.InvalidRouteParam;
    }
}

fn validate_encoded_route_param(param: []const u8) build_path_error!void {
    if (0 < param.len) {} else return error.EmptyRouteParam;

    for (param) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or
            byte == '%' or
            byte == '-' or
            byte == '_' or
            byte == '.' or
            byte == '~';
        if (valid) {} else return error.InvalidRouteParam;
    }
}

fn write_path(path_buffer: []u8, parts: []const []const u8) build_path_error![]const u8 {
    return PathBuilder.build(path_buffer, parts);
}

test "Routes exposes users current-user path in one module" {
    try std.testing.expectEqualStrings("/users/@me", Routes.users.current_user);
}

test "Routes.channels.get builds channel path into caller buffer" {
    var path_buffer: [64]u8 = undefined;
    const path = try Routes.channels.get(path_buffer[0..], "123");

    try std.testing.expectEqualStrings("/channels/123", path);
}

test "Routes.messages.index builds channel messages path" {
    var path_buffer: [128]u8 = undefined;
    const path = try Routes.messages.index(path_buffer[0..], "123");

    try std.testing.expectEqualStrings("/channels/123/messages", path);
}

test "Routes.messages.get builds single message path" {
    var path_buffer: [128]u8 = undefined;
    const path = try Routes.messages.get(path_buffer[0..], "123", "999");

    try std.testing.expectEqualStrings("/channels/123/messages/999", path);
}

test "Routes.applications builds command paths" {
    var path_buffer: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/applications/777/commands",
        try Routes.applications.global_commands(path_buffer[0..], "777"),
    );
    try std.testing.expectEqualStrings(
        "/applications/777/guilds/888/commands",
        try Routes.applications.guild_commands(path_buffer[0..], "777", "888"),
    );
    try std.testing.expectEqualStrings(
        "/applications/777/commands/999",
        try Routes.applications.global_command(path_buffer[0..], "777", "999"),
    );
    try std.testing.expectEqualStrings(
        "/applications/777/guilds/888/commands/999",
        try Routes.applications.guild_command(path_buffer[0..], "777", "888", "999"),
    );
}

test "Routes.interactions builds callback path and rejects slash in token" {
    var path_buffer: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/interactions/123/token.value-1_/callback",
        try Routes.interactions.callback(path_buffer[0..], "123", "token.value-1_"),
    );
    try std.testing.expectError(
        error.InvalidRouteParam,
        Routes.interactions.callback(path_buffer[0..], "123", "bad/token"),
    );
}

test "Routes messages path builder rejects slash in route param" {
    var path_buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.InvalidRouteParam,
        Routes.messages.get(path_buffer[0..], "12/3", "999"),
    );
}

test "Routes path builders reject empty route params" {
    var path_buffer: [64]u8 = undefined;
    try std.testing.expectError(
        error.EmptyRouteParam,
        Routes.channels.get(path_buffer[0..], ""),
    );
}

test "Routes messages path builder rejects route param with spaces" {
    var path_buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.InvalidRouteParam,
        Routes.messages.index(path_buffer[0..], "12 3"),
    );
}

test "Routes messages path builder rejects non-digit route params" {
    var path_buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.InvalidRouteParam,
        Routes.messages.get(path_buffer[0..], "abc", "999"),
    );
    try std.testing.expectError(
        error.InvalidRouteParam,
        Routes.messages.get(path_buffer[0..], "123", "99?9"),
    );
}

test "Routes path builders reject insufficient buffers" {
    var path_buffer: [8]u8 = undefined;
    try std.testing.expectError(
        error.PathBufferTooSmall,
        Routes.messages.index(path_buffer[0..], "123"),
    );
}
