const std = @import("std");
const GatewayClient = @import("gateway_client.zig").GatewayClient;

pub const option_depth_max: u8 = 3;

pub const MentionableKind = enum {
    user,
    role,
};

pub const ResolvedAttachment = struct {
    id: []const u8,
    filename: ?[]const u8 = null,
    url: ?[]const u8 = null,
    proxy_url: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    size: ?u64 = null,
};

pub const InteractionData = @This();

pub fn option_value(
    event: GatewayClient.SlashCommandEvent,
    name: []const u8,
) ?std.json.Value {
    const data = event.data orelse return null;
    return find_option_value_in_node(data, name, 0);
}

pub fn first_option_name_by_type(
    event: GatewayClient.SlashCommandEvent,
    option_type: u8,
) ?[]const u8 {
    const data = event.data orelse return null;
    const object = switch (data) {
        .object => |value| value,
        else => return null,
    };

    const options_value = object.get("options") orelse return null;
    const options = switch (options_value) {
        .array => |items| items.items,
        else => return null,
    };

    for (options) |option| {
        const option_object = switch (option) {
            .object => |value| value,
            else => continue,
        };
        const type_value = option_object.get("type") orelse continue;
        const candidate_type = integer_value(type_value) orelse continue;
        if (candidate_type == option_type) {} else continue;

        const name_value = option_object.get("name") orelse continue;
        return string_value(name_value);
    }

    return null;
}

pub fn mentionable_kind(
    event: GatewayClient.SlashCommandEvent,
    name: []const u8,
) ?MentionableKind {
    const id = option_string(event, name) orelse return null;

    if (resolved_value(event, "users", id) != null) return .user;
    if (resolved_value(event, "roles", id) != null) return .role;
    return null;
}

pub fn attachment(
    event: GatewayClient.SlashCommandEvent,
    name: []const u8,
) ?ResolvedAttachment {
    const id = option_string(event, name) orelse return null;
    const value = resolved_value(event, "attachments", id) orelse {
        return .{ .id = id };
    };
    const object = switch (value) {
        .object => |item| item,
        else => return .{ .id = id },
    };

    return .{
        .id = id,
        .filename = object_string(object, "filename"),
        .url = object_string(object, "url"),
        .proxy_url = object_string(object, "proxy_url"),
        .content_type = object_string(object, "content_type"),
        .size = object_unsigned(object, "size"),
    };
}

pub fn modal_field_value(
    event: GatewayClient.ModalSubmitEvent,
    custom_id: []const u8,
) ?[]const u8 {
    const data = event.data orelse return null;
    const object = switch (data) {
        .object => |value| value,
        else => return null,
    };

    const components_value = object.get("components") orelse return null;
    const rows = switch (components_value) {
        .array => |items| items.items,
        else => return null,
    };

    for (rows) |row_node| {
        const row_components = modal_row_components(row_node) orelse continue;
        const field_value = modal_field_value_in_row(row_components, custom_id) orelse continue;
        return field_value;
    }

    return null;
}

pub fn option_string(
    event: GatewayClient.SlashCommandEvent,
    name: []const u8,
) ?[]const u8 {
    const value = option_value(event, name) orelse return null;
    return string_value(value);
}

pub fn string_value(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn boolean_value(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |state| state,
        else => null,
    };
}

pub fn integer_value(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| {
            if (@round(number) == number) {} else return null;
            if (@as(f64, @floatFromInt(std.math.minInt(i64))) <= number and
                number <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {} else return null;
            return @intFromFloat(number);
        },
        .number_string => |number_text| std.fmt.parseInt(i64, number_text, 10) catch null,
        else => null,
    };
}

pub fn number_value(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string => |number_text| std.fmt.parseFloat(f64, number_text) catch null,
        else => null,
    };
}

fn resolved_value(
    event: GatewayClient.SlashCommandEvent,
    collection_name: []const u8,
    id: []const u8,
) ?std.json.Value {
    const data = event.data orelse return null;
    const data_object = switch (data) {
        .object => |value| value,
        else => return null,
    };

    const resolved_value_node = data_object.get("resolved") orelse return null;
    const resolved_object = switch (resolved_value_node) {
        .object => |value| value,
        else => return null,
    };

    const collection_value = resolved_object.get(collection_name) orelse return null;
    const collection_object = switch (collection_value) {
        .object => |value| value,
        else => return null,
    };

    return collection_object.get(id);
}

fn find_option_value_in_node(
    node: std.json.Value,
    name: []const u8,
    depth: u8,
) ?std.json.Value {
    if (depth < option_depth_max) {} else return null;

    const object = switch (node) {
        .object => |value| value,
        else => return null,
    };

    if (object.get("name")) |name_value| {
        if (string_value(name_value)) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return object.get("value");
            }
        }
    }

    const options_value = object.get("options") orelse return null;
    const options = switch (options_value) {
        .array => |items| items.items,
        else => return null,
    };

    for (options) |option_node| {
        if (find_option_value_in_node(option_node, name, depth + 1)) |value| {
            return value;
        }
    }

    return null;
}

fn modal_row_components(row_node: std.json.Value) ?[]std.json.Value {
    const row_object = switch (row_node) {
        .object => |value| value,
        else => return null,
    };
    const row_components_value = row_object.get("components") orelse return null;
    return switch (row_components_value) {
        .array => |items| items.items,
        else => null,
    };
}

fn modal_field_value_in_row(
    row_components: []std.json.Value,
    custom_id: []const u8,
) ?[]const u8 {
    for (row_components) |component_node| {
        const component_object = switch (component_node) {
            .object => |value| value,
            else => continue,
        };
        const candidate_id_value = component_object.get("custom_id") orelse continue;
        const candidate_id = string_value(candidate_id_value) orelse continue;
        if (std.mem.eql(u8, candidate_id, custom_id)) {} else continue;

        const field_value = component_object.get("value") orelse return null;
        return string_value(field_value);
    }

    return null;
}

fn object_string(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return string_value(value);
}

fn object_unsigned(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return unsigned_value(value);
}

fn unsigned_value(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| {
            if (0 <= number) {} else return null;
            return @intCast(number);
        },
        .float => |number| {
            if (@round(number) == number) {} else return null;
            if (0 <= number and number <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {} else {
                return null;
            }
            return @intFromFloat(number);
        },
        .number_string => |number_text| std.fmt.parseInt(u64, number_text, 10) catch null,
        else => null,
    };
}

test "InteractionData extracts modal text input values from Discord payload shape" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "custom_id": "zcord_sample:modal",
        \\  "components": [
        \\    {
        \\      "type": 1,
        \\      "components": [
        \\        {
        \\          "type": 4,
        \\          "custom_id": "feedback",
        \\          "value": "hello from modal"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const event = GatewayClient.ModalSubmitEvent{
        .id = "interaction-1",
        .token = "interaction-token",
        .custom_id = "zcord_sample:modal",
        .data = parsed.value,
    };

    const value = modal_field_value(event, "feedback") orelse return error.MissingModalField;
    try std.testing.expectEqualStrings("hello from modal", value);
}

test "InteractionData slash options search is bounded and finds nested values" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": "command-1",
        \\  "name": "zcord",
        \\  "options": [
        \\    {
        \\      "type": 1,
        \\      "name": "echo",
        \\      "options": [
        \\        { "type": 3, "name": "text", "value": "hello slash" }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const event = GatewayClient.SlashCommandEvent{
        .id = "interaction-2",
        .token = "interaction-token",
        .name = "zcord",
        .data = parsed.value,
    };

    const value = option_value(event, "text") orelse return error.MissingSlashOption;
    try std.testing.expectEqualStrings("hello slash", string_value(value) orelse unreachable);
}

test "InteractionData resolves mentionable role kind" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": "command-1",
        \\  "name": "zcord",
        \\  "options": [
        \\    { "type": 9, "name": "mention", "value": "role-1" }
        \\  ],
        \\  "resolved": {
        \\    "roles": {
        \\      "role-1": { "id": "role-1", "name": "LEADER" }
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const event = GatewayClient.SlashCommandEvent{
        .id = "interaction-3",
        .token = "interaction-token",
        .name = "zcord",
        .data = parsed.value,
    };

    try std.testing.expectEqual(
        MentionableKind.role,
        mentionable_kind(event, "mention") orelse unreachable,
    );
}

test "InteractionData resolves attachment metadata" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": "command-1",
        \\  "name": "zcord",
        \\  "options": [
        \\    { "type": 11, "name": "file", "value": "file-1" }
        \\  ],
        \\  "resolved": {
        \\    "attachments": {
        \\      "file-1": {
        \\        "id": "file-1",
        \\        "filename": "sample.txt",
        \\        "url": "https://cdn.discordapp.com/file.txt",
        \\        "content_type": "text/plain",
        \\        "size": 42
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const event = GatewayClient.SlashCommandEvent{
        .id = "interaction-4",
        .token = "interaction-token",
        .name = "zcord",
        .data = parsed.value,
    };

    const resolved_attachment = attachment(event, "file") orelse return error.MissingAttachment;
    try std.testing.expectEqualStrings("file-1", resolved_attachment.id);
    try std.testing.expectEqualStrings(
        "sample.txt",
        resolved_attachment.filename orelse unreachable,
    );
    try std.testing.expectEqualStrings(
        "https://cdn.discordapp.com/file.txt",
        resolved_attachment.url orelse unreachable,
    );
    try std.testing.expectEqual(@as(u64, 42), resolved_attachment.size orelse unreachable);
}
