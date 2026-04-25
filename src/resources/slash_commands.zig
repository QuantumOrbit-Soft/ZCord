const std = @import("std");
const zrqwest = @import("zrqwest");
const DiscordHttpClient = @import("../discord/http_client.zig").DiscordHttpClient;
const DiscordResult = @import("../discord/result.zig").DiscordResult;
const models = @import("../models/mod.zig");
const Routes = @import("../routes/mod.zig").Routes;

allocator: std.mem.Allocator,
client: *DiscordHttpClient,

pub const SlashCommandsResource = @This();

pub const CommandType = enum(u8) {
    chat_input = 1,
    user = 2,
    message = 3,
};

pub const CommandOptionType = enum(u8) {
    sub_command = 1,
    sub_command_group = 2,
    string = 3,
    integer = 4,
    boolean = 5,
    user = 6,
    channel = 7,
    role = 8,
    mentionable = 9,
    number = 10,
    attachment = 11,
};

pub const ChannelTypes = struct {
    pub const guild_text: u16 = 0;
    pub const dm: u16 = 1;
    pub const guild_voice: u16 = 2;
    pub const group_dm: u16 = 3;
    pub const guild_category: u16 = 4;
    pub const guild_announcement: u16 = 5;
    pub const announcement_thread: u16 = 10;
    pub const public_thread: u16 = 11;
    pub const private_thread: u16 = 12;
    pub const guild_stage_voice: u16 = 13;
    pub const guild_directory: u16 = 14;
    pub const guild_forum: u16 = 15;
    pub const guild_media: u16 = 16;
};

pub const InteractionCallbackType = enum(u8) {
    pong = 1,
    channel_message_with_source = 4,
    deferred_channel_message_with_source = 5,
    deferred_update_message = 6,
    update_message = 7,
    autocomplete_result = 8,
    modal = 9,
};

pub const CommandOptionChoice = struct {
    name: []const u8,
    value: std.json.Value,
};

pub const CommandOption = struct {
    type: u8,
    name: []const u8,
    description: []const u8,
    required: ?bool = null,
    choices: []const CommandOptionChoice = &.{},
    options: []const CommandOption = &.{},
    channel_types: []const u16 = &.{},
    min_value: ?f64 = null,
    max_value: ?f64 = null,
    min_length: ?u16 = null,
    max_length: ?u16 = null,
    autocomplete: ?bool = null,
};

pub const Options = struct {
    pub fn string(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.string),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn integer(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.integer),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn number(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.number),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn boolean(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.boolean),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn user(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.user),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn channel(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.channel),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn role(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.role),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn mentionable(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.mentionable),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn attachment(name: []const u8, description: []const u8, required: bool) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.attachment),
            .name = name,
            .description = description,
            .required = required,
        };
    }

    pub fn sub_command(
        name: []const u8,
        description: []const u8,
        options: []const CommandOption,
    ) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.sub_command),
            .name = name,
            .description = description,
            .options = options,
        };
    }

    pub fn sub_command_group(
        name: []const u8,
        description: []const u8,
        options: []const CommandOption,
    ) CommandOption {
        return .{
            .type = @intFromEnum(CommandOptionType.sub_command_group),
            .name = name,
            .description = description,
            .options = options,
        };
    }

    pub fn choice_string(name: []const u8, value: []const u8) CommandOptionChoice {
        return .{ .name = name, .value = .{ .string = value } };
    }

    pub fn choice_integer(name: []const u8, value: i64) CommandOptionChoice {
        return .{ .name = name, .value = .{ .integer = value } };
    }

    pub fn choice_number(name: []const u8, value: f64) CommandOptionChoice {
        return .{ .name = name, .value = .{ .float = value } };
    }

    pub fn with_choices(
        option: CommandOption,
        choices: []const CommandOptionChoice,
    ) CommandOption {
        var result = option;
        result.choices = choices;
        return result;
    }

    pub fn with_autocomplete(option: CommandOption, enabled: bool) CommandOption {
        var result = option;
        result.autocomplete = enabled;
        return result;
    }

    pub fn with_range(
        option: CommandOption,
        min_value: ?f64,
        max_value: ?f64,
    ) CommandOption {
        var result = option;
        result.min_value = min_value;
        result.max_value = max_value;
        return result;
    }

    pub fn with_length(
        option: CommandOption,
        min_length: ?u16,
        max_length: ?u16,
    ) CommandOption {
        var result = option;
        result.min_length = min_length;
        result.max_length = max_length;
        return result;
    }

    pub fn with_channel_types(
        option: CommandOption,
        channel_types: []const u16,
    ) CommandOption {
        var result = option;
        result.channel_types = channel_types;
        return result;
    }

    pub fn optional(option: CommandOption) CommandOption {
        var result = option;
        result.required = false;
        return result;
    }

    pub fn force_required(option: CommandOption) CommandOption {
        var result = option;
        result.required = true;
        return result;
    }
};

pub const TextInputStyle = enum(u8) {
    short = 1,
    paragraph = 2,
};

pub const TextInput = struct {
    type: u8 = 4,
    custom_id: []const u8,
    style: u8,
    label: []const u8,
    min_length: ?u16 = null,
    max_length: ?u16 = null,
    required: ?bool = null,
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
};

pub const TextInputRow = struct {
    type: u8 = 1,
    components: []const TextInput,
};

pub const Modals = struct {
    pub fn text_input(
        custom_id: []const u8,
        label: []const u8,
        style: TextInputStyle,
    ) TextInput {
        return .{
            .custom_id = custom_id,
            .label = label,
            .style = @intFromEnum(style),
        };
    }

    pub fn row(components: []const TextInput) TextInputRow {
        return .{ .components = components };
    }

    pub fn with_required(input: TextInput, enabled: bool) TextInput {
        var result = input;
        result.required = enabled;
        return result;
    }

    pub fn with_placeholder(input: TextInput, placeholder: []const u8) TextInput {
        var result = input;
        result.placeholder = placeholder;
        return result;
    }

    pub fn with_value(input: TextInput, value: []const u8) TextInput {
        var result = input;
        result.value = value;
        return result;
    }

    pub fn with_length(input: TextInput, min_length: ?u16, max_length: ?u16) TextInput {
        var result = input;
        result.min_length = min_length;
        result.max_length = max_length;
        return result;
    }
};

pub const sync_command = struct {
    name: []const u8,
    description: []const u8,
    type: u8 = @intFromEnum(CommandType.chat_input),
    dm_permission: ?bool = null,
    options: []const CommandOption = &.{},
};

pub const create_global_params = struct {
    application_id: []const u8,
    name: []const u8,
    description: []const u8,
    dm_permission: ?bool = null,
    options: []const CommandOption = &.{},
};

pub const create_guild_params = struct {
    application_id: []const u8,
    guild_id: []const u8,
    name: []const u8,
    description: []const u8,
    dm_permission: ?bool = null,
    options: []const CommandOption = &.{},
};

pub const overwrite_global_params = struct {
    application_id: []const u8,
    commands: []const sync_command,
};

pub const overwrite_guild_params = struct {
    application_id: []const u8,
    guild_id: []const u8,
    commands: []const sync_command,
};

pub const delete_global_params = struct {
    application_id: []const u8,
    command_id: []const u8,
};

pub const delete_guild_params = struct {
    application_id: []const u8,
    guild_id: []const u8,
    command_id: []const u8,
};

pub const interaction_response_params = struct {
    interaction_id: []const u8,
    interaction_token: []const u8,
    content: []const u8 = "",
    embeds: []const models.Embed = &.{},
    components: []const models.ActionRow = &.{},
    flags: ?u64 = null,
};

pub const modal_response_params = struct {
    interaction_id: []const u8,
    interaction_token: []const u8,
    custom_id: []const u8,
    title: []const u8,
    components: []const TextInputRow,
};

pub const command_result = DiscordResult.Of(models.ApplicationCommand);
pub const command_list_result = DiscordResult.Of([]models.ApplicationCommand);
pub const empty_result = DiscordResult.Empty;

const Self = @This();
const route_path_bytes_max: usize = 896;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    client: *DiscordHttpClient,
) void {
    self.* = .{ .allocator = allocator, .client = client };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn create_global(self: *Self, params: create_global_params) !command_result {
    try validate_command_options(params.options, 0);
    const response = try self.create_global_response(params);
    return command_result.from_zrqwest_response(self.allocator, response);
}

pub fn list_global(self: *Self, application_id: []const u8) !command_list_result {
    const response = try self.list_global_response(application_id);
    return command_list_result.from_zrqwest_response(self.allocator, response);
}

pub fn list_guild(
    self: *Self,
    application_id: []const u8,
    guild_id: []const u8,
) !command_list_result {
    const response = try self.list_guild_response(application_id, guild_id);
    return command_list_result.from_zrqwest_response(self.allocator, response);
}

pub fn create_guild(self: *Self, params: create_guild_params) !command_result {
    try validate_command_options(params.options, 0);
    const response = try self.create_guild_response(params);
    return command_result.from_zrqwest_response(self.allocator, response);
}

pub fn overwrite_global(self: *Self, params: overwrite_global_params) !command_list_result {
    try validate_sync_commands(params.commands);
    const response = try self.overwrite_global_response(params);
    return command_list_result.from_zrqwest_response(self.allocator, response);
}

pub fn overwrite_guild(self: *Self, params: overwrite_guild_params) !command_list_result {
    try validate_sync_commands(params.commands);
    const response = try self.overwrite_guild_response(params);
    return command_list_result.from_zrqwest_response(self.allocator, response);
}

pub fn delete_global(self: *Self, params: delete_global_params) !empty_result {
    const response = try self.delete_global_response(params);
    return empty_result.from_zrqwest_response(self.allocator, response);
}

pub fn delete_guild(self: *Self, params: delete_guild_params) !empty_result {
    const response = try self.delete_guild_response(params);
    return empty_result.from_zrqwest_response(self.allocator, response);
}

pub fn respond_to_interaction(self: *Self, params: interaction_response_params) !empty_result {
    const response = try self.respond_to_interaction_response(params);
    return empty_result.from_zrqwest_response(self.allocator, response);
}

pub fn respond_modal_to_interaction(self: *Self, params: modal_response_params) !empty_result {
    try validate_modal_rows(params.components);
    const response = try self.respond_modal_to_interaction_response(params);
    return empty_result.from_zrqwest_response(self.allocator, response);
}

fn list_global_response(self: *Self, application_id: []const u8) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.global_commands(path_buffer[0..], application_id);
    return self.client.get(path);
}

fn list_guild_response(
    self: *Self,
    application_id: []const u8,
    guild_id: []const u8,
) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.guild_commands(path_buffer[0..], application_id, guild_id);
    return self.client.get(path);
}

fn create_global_response(self: *Self, params: create_global_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.global_commands(path_buffer[0..], params.application_id);
    return self.client.post(path, sync_command, .{
        .name = params.name,
        .description = params.description,
        .dm_permission = params.dm_permission,
        .options = params.options,
    });
}

fn create_guild_response(self: *Self, params: create_guild_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.guild_commands(
        path_buffer[0..],
        params.application_id,
        params.guild_id,
    );
    return self.client.post(path, sync_command, .{
        .name = params.name,
        .description = params.description,
        .dm_permission = params.dm_permission,
        .options = params.options,
    });
}

fn overwrite_global_response(self: *Self, params: overwrite_global_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.global_commands(path_buffer[0..], params.application_id);
    return self.client.put(path, []const sync_command, params.commands);
}

fn overwrite_guild_response(self: *Self, params: overwrite_guild_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.guild_commands(
        path_buffer[0..],
        params.application_id,
        params.guild_id,
    );
    return self.client.put(path, []const sync_command, params.commands);
}

fn delete_global_response(self: *Self, params: delete_global_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.global_command(
        path_buffer[0..],
        params.application_id,
        params.command_id,
    );
    return self.client.delete(path);
}

fn delete_guild_response(self: *Self, params: delete_guild_params) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.applications.guild_command(
        path_buffer[0..],
        params.application_id,
        params.guild_id,
        params.command_id,
    );
    return self.client.delete(path);
}

fn respond_to_interaction_response(
    self: *Self,
    params: interaction_response_params,
) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.interactions.callback(
        path_buffer[0..],
        params.interaction_id,
        params.interaction_token,
    );

    return self.client.post_no_auth(path, struct {
        type: u8,
        data: struct {
            content: []const u8,
            embeds: ?[]const models.Embed,
            components: ?[]const models.ActionRow,
            flags: ?u64,
        },
    }, .{
        .type = @intFromEnum(InteractionCallbackType.channel_message_with_source),
        .data = .{
            .content = params.content,
            .embeds = optional_embeds(params.embeds),
            .components = optional_components(params.components),
            .flags = params.flags,
        },
    });
}

fn respond_modal_to_interaction_response(
    self: *Self,
    params: modal_response_params,
) !zrqwest.Response {
    var path_buffer: [route_path_bytes_max]u8 = undefined;
    const path = try Routes.interactions.callback(
        path_buffer[0..],
        params.interaction_id,
        params.interaction_token,
    );

    return self.client.post_no_auth(path, struct {
        type: u8,
        data: struct {
            custom_id: []const u8,
            title: []const u8,
            components: []const TextInputRow,
        },
    }, .{
        .type = @intFromEnum(InteractionCallbackType.modal),
        .data = .{
            .custom_id = params.custom_id,
            .title = params.title,
            .components = params.components,
        },
    });
}

fn validate_sync_commands(commands: []const sync_command) !void {
    for (commands) |command| {
        if (0 < command.name.len) {} else return error.InvalidCommandName;
        if (0 < command.description.len) {} else return error.InvalidCommandDescription;
        try validate_command_options(command.options, 0);
    }
}

fn optional_embeds(embeds: []const models.Embed) ?[]const models.Embed {
    if (0 < embeds.len) return embeds;
    return null;
}

fn optional_components(components: []const models.ActionRow) ?[]const models.ActionRow {
    if (0 < components.len) return components;
    return null;
}

fn validate_command_options(options: []const CommandOption, depth: u8) !void {
    if (options.len <= 25) {} else return error.InvalidCommandOptionCount;
    if (depth <= 2) {} else return error.InvalidCommandOptionDepth;

    for (options) |option| {
        if (0 < option.name.len) {} else return error.InvalidCommandOptionName;
        if (0 < option.description.len) {} else return error.InvalidCommandOptionDescription;
        if (option.choices.len <= 25) {} else return error.InvalidCommandOptionChoiceCount;
        try validate_choice_settings(option);
        try validate_option_ranges(option);

        if (0 < option.options.len) {
            try validate_command_options(option.options, depth + 1);
        }
    }
}

fn validate_choice_settings(option: CommandOption) !void {
    if (option.autocomplete) |_| {
        if (0 < option.choices.len) {
            return error.CommandOptionCannotUseChoicesAndAutocomplete;
        }
    }

    if (0 < option.choices.len) {} else return;

    switch (option.type) {
        @intFromEnum(CommandOptionType.string),
        @intFromEnum(CommandOptionType.integer),
        @intFromEnum(CommandOptionType.number),
        => {},
        else => return error.InvalidCommandOptionChoiceType,
    }
}

fn validate_option_ranges(option: CommandOption) !void {
    if (option.min_value) |min_value| {
        if (option.max_value) |max_value| {
            if (min_value <= max_value) {} else return error.InvalidCommandOptionRange;
        }
    }

    if (option.min_length) |min_length| {
        if (option.max_length) |max_length| {
            if (min_length <= max_length) {} else return error.InvalidCommandOptionLengthRange;
        }
    }
}

fn validate_modal_rows(rows: []const TextInputRow) !void {
    if (0 < rows.len and rows.len <= 5) {} else return error.InvalidModalRowCount;

    for (rows) |row| {
        if (row.type == 1) {} else return error.InvalidModalRowType;
        if (row.components.len == 1) {} else return error.InvalidModalRowComponentCount;

        for (row.components) |text_input| {
            try validate_modal_text_input(text_input);
        }
    }
}

fn validate_modal_text_input(text_input: TextInput) !void {
    if (text_input.type == 4) {} else return error.InvalidModalComponentType;
    if (0 < text_input.custom_id.len) {} else return error.InvalidModalCustomId;
    if (0 < text_input.label.len) {} else return error.InvalidModalLabel;

    const is_short = text_input.style == @intFromEnum(TextInputStyle.short);
    const is_paragraph = text_input.style == @intFromEnum(TextInputStyle.paragraph);
    if (is_short or is_paragraph) {} else return error.InvalidTextInputStyle;

    if (text_input.min_length) |min_length| {
        if (text_input.max_length) |max_length| {
            if (min_length <= max_length) {} else return error.InvalidModalTextLengthRange;
        }
    }
}

test "SlashCommandsResource builds command paths" {
    var path_buffer: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/applications/777/commands",
        try Routes.applications.global_commands(path_buffer[0..], "777"),
    );
    try std.testing.expectEqualStrings(
        "/interactions/123/token/callback",
        try Routes.interactions.callback(path_buffer[0..], "123", "token"),
    );
}

test "SlashCommandsResource validates option bounds" {
    var options: [26]CommandOption = undefined;
    for (&options, 0..) |*option, index| {
        option.* = Options.string("name", "description", index == 0);
    }

    try std.testing.expectError(
        error.InvalidCommandOptionCount,
        validate_command_options(options[0..], 0),
    );
}

test "SlashCommandsResource validates choices and autocomplete as exclusive" {
    const option = Options.with_choices(
        Options.with_autocomplete(Options.string("term", "Search term", true), true),
        &.{Options.choice_string("Zig", "zig")},
    );

    try std.testing.expectError(
        error.CommandOptionCannotUseChoicesAndAutocomplete,
        validate_command_options(&.{option}, 0),
    );
}

test "SlashCommandsResource serializes channel_types as numeric array" {
    const allocator = std.testing.allocator;
    const channel_types = [_]u16{ChannelTypes.guild_text};
    const option = Options.with_channel_types(
        Options.channel("channel", "Target channel", false),
        channel_types[0..],
    );

    const body = try std.json.Stringify.valueAlloc(allocator, option, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"channel_types\":[0]",
    ) != null);
}

test "SlashCommandsResource validates modal text input rows" {
    const input = Modals.text_input("topic", "Topic", .short);
    const row = Modals.row(&.{input});

    try validate_modal_rows(&.{row});

    const invalid = Modals.row(&.{});
    try std.testing.expectError(
        error.InvalidModalRowComponentCount,
        validate_modal_rows(&.{invalid}),
    );
}
