const std = @import("std");
const zcord = @import("ZCord");
const Env = @import("internal").Env;
const SampleBot = @import("sample_bot.zig");
const SampleConfig = @import("sample_config.zig");

const env_file_path = ".env";
const sample_message_content = "ZCord sample message";
const edited_sample_message_content = "ZCord sample message edited";
const sample_reply_content = "ZCord sample reply";
const sample_reaction = "\u{1F44D}";
const sample_component_custom_id = "zcord_sample:open_modal";
const sample_status_custom_id = "zcord_sample:status";
const sample_public_custom_id = "zcord_sample:public";
const sample_danger_custom_id = "zcord_sample:danger";
const button_modal_emoji = "\u{1F4DD}";
const button_status_emoji = "\u{2139}\u{FE0F}";
const button_public_emoji = "\u{1F4E3}";
const button_danger_emoji = "\u{26A0}\u{FE0F}";
const button_docs_emoji = "\u{1F517}";
const interactive_panel_content = "ZCord interactive panel";
const sample_guild_command_name = "zcord";
const sample_guild_command_description = "ZCord interactive sample command";
const sample_embed_image_url = "https://cdn.discordapp.com/embed/avatars/1.png";
const sample_embed_thumbnail_url = "https://cdn.discordapp.com/embed/avatars/0.png";
const sample_link_button_url =
    "https://discord.com/developers/docs/interactions/message-components";

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();

    const allocator = debug_allocator.allocator();

    var env: Env = undefined;
    env.init(allocator);
    defer env.deinit();

    try env.load_file(env_file_path);

    var config: SampleConfig = undefined;
    config.init(&env);
    const token = config.token() catch {
        std.debug.print("Missing TOKEN or DISCORD_TOKEN in {s}\n", .{env_file_path});
        return error.MissingDiscordToken;
    };

    var request_client: zcord.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var discord: zcord.DiscordClient = undefined;
    try discord.init(.{
        .allocator = allocator,
        .client = &request_client,
        .token = token,
    });
    defer discord.deinit();

    discord.on(SampleBot.on_ready, .OnReady);
    discord.on(SampleBot.on_event, .OnEvent);
    discord.on(SampleBot.on_message, .OnMessage);
    discord.on(SampleBot.on_reaction, .OnReaction);
    discord.on(SampleBot.on_channel, .OnChannel);
    discord.on(SampleBot.on_voice, .OnVoice);
    discord.on(SampleBot.on_slash_command, .OnSlashCommand);
    discord.on(SampleBot.on_component, .OnComponent);
    discord.on(SampleBot.on_modal_submit, .OnModalSubmit);

    std.debug.print("ZCord sample using {s}\n", .{zcord.DiscordConfig.default_base_url});

    try run_rest_samples(allocator, &discord, config);
    try run_gateway_sample(&discord);
}

fn run_rest_samples(
    allocator: std.mem.Allocator,
    discord: *zcord.DiscordClient,
    config: SampleConfig,
) !void {
    const current_user_id = try run_users_resource(allocator, discord);
    defer if (current_user_id) |value| allocator.free(value);

    if (config.channel_id()) |channel_id| {
        try run_channels_resource(discord, channel_id);
        try run_messages_resource(discord, channel_id);
        try create_interactive_panel(discord, channel_id);
    } else {
        std.debug.print("Skipping channel test. Add CHANNEL_ID to {s}.\n", .{env_file_path});
    }

    const application_id = try resolve_application_id(allocator, config, current_user_id);
    defer if (application_id) |value| allocator.free(value);

    if (application_id) |value| {
        try run_slash_command_samples(discord, config, value);
    } else {
        print_skipped_application_commands();
    }
}

fn run_gateway_sample(
    discord: *zcord.DiscordClient,
) !void {
    std.debug.print("Gateway listening. Stop with Ctrl+C.\n", .{});
    try discord.run_gateway(.{
        .intents = zcord.GatewayIntents.message_events |
            zcord.GatewayIntents.voice_events,
    });
}

fn run_users_resource(
    allocator: std.mem.Allocator,
    discord: *zcord.DiscordClient,
) !?[]u8 {
    var result = try discord.users.get_current_user();
    defer result.deinit();

    std.debug.print("GET /users/@me -> {d}\n", .{result.status_code});
    if (result.data()) |user| {
        std.debug.print("Bot user: {s} ({s})\n", .{ user.username, user.id });
        return try allocator.dupe(u8, user.id);
    }

    print_error_body(result.error_body());
    return null;
}

fn run_channels_resource(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
) !void {
    var result = try discord.channels.get(channel_id);
    defer result.deinit();

    std.debug.print("GET /channels/{s} -> {d}\n", .{ channel_id, result.status_code });
    if (result.data()) |channel| {
        std.debug.print("Channel: {s} ({s})\n", .{
            channel.name orelse "(unnamed)",
            channel.id,
        });
        return;
    }

    print_error_body(result.error_body());
}

fn run_messages_resource(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
) !void {
    const fields = [_]zcord.EmbedField{
        .{
            .name = "Resource",
            .value = "messages.create/get/edit/reply/reaction/delete",
            .@"inline" = false,
        },
        .{ .name = "Embeds", .value = "author, footer, color, fields", .@"inline" = true },
        .{ .name = "Ownership", .value = "result.deinit owns parsed payload", .@"inline" = true },
    };
    const embeds = [_]zcord.Embed{
        .{
            .title = "ZCord sample",
            .description = "Testing message payloads with a richer embed.",
            .color = 0x5865F2,
            .author = .{ .name = "ZiCord SDK" },
            .footer = .{ .text = "REST resource sample" },
            .image = .{ .url = sample_embed_image_url },
            .thumbnail = .{ .url = sample_embed_thumbnail_url },
            .fields = fields[0..],
        },
    };

    var create_result = try discord.messages.create(.{
        .channel_id = channel_id,
        .content = sample_message_content,
        .embeds = embeds[0..],
    });
    defer create_result.deinit();

    std.debug.print("POST /channels/{s}/messages -> {d}\n", .{
        channel_id,
        create_result.status_code,
    });

    const message = create_result.data() orelse {
        print_error_body(create_result.error_body());
        return;
    };

    std.debug.print("Created message: {s}\n", .{message.id});
    try fetch_sample_message(discord, channel_id, message.id);
    try edit_sample_message(discord, channel_id, message.id);
    try add_sample_reaction(discord, channel_id, message.id);
    try remove_sample_reaction(discord, channel_id, message.id);
    try reply_to_sample_message(discord, channel_id, message.id);
    try delete_sample_message(discord, channel_id, message.id);
}

fn create_interactive_panel(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
) !void {
    const fields = [_]zcord.EmbedField{
        .{ .name = "Callback", .value = "button -> modal -> modal submit" },
        .{ .name = "Slash", .value = "/zcord supports typed options", .@"inline" = true },
        .{ .name = "Buttons", .value = "primary, secondary, success, danger, link" },
        .{ .name = "Message", .value = "!zcord rich sends another embed", .@"inline" = true },
    };
    const embeds = [_]zcord.Embed{
        .{
            .title = "ZCord interactive sample",
            .description = "Use this while the sample Gateway is running.",
            .color = 0x57F287,
            .author = .{ .name = "Gateway callbacks" },
            .footer = .{ .text = "Click the button after on_ready is printed" },
            .image = .{ .url = sample_embed_image_url },
            .thumbnail = .{ .url = sample_embed_thumbnail_url },
            .fields = fields[0..],
        },
    };
    const buttons = [_]zcord.Button{
        .{
            .style = @intFromEnum(zcord.ButtonStyle.primary),
            .label = "Open modal",
            .custom_id = sample_component_custom_id,
            .emoji = .{ .name = button_modal_emoji },
        },
        .{
            .style = @intFromEnum(zcord.ButtonStyle.secondary),
            .label = "Status",
            .custom_id = sample_status_custom_id,
            .emoji = .{ .name = button_status_emoji },
        },
        .{
            .style = @intFromEnum(zcord.ButtonStyle.success),
            .label = "Public reply",
            .custom_id = sample_public_custom_id,
            .emoji = .{ .name = button_public_emoji },
        },
        .{
            .style = @intFromEnum(zcord.ButtonStyle.danger),
            .label = "Danger",
            .custom_id = sample_danger_custom_id,
            .emoji = .{ .name = button_danger_emoji },
        },
        .{
            .style = @intFromEnum(zcord.ButtonStyle.link),
            .label = "Docs",
            .url = sample_link_button_url,
            .emoji = .{ .name = button_docs_emoji },
        },
    };
    const rows = [_]zcord.ActionRow{.{ .components = buttons[0..] }};

    var result = try discord.messages.create(.{
        .channel_id = channel_id,
        .content = interactive_panel_content,
        .embeds = embeds[0..],
        .components = rows[0..],
    });
    defer result.deinit();

    std.debug.print("POST interactive panel /channels/{s}/messages -> {d}\n", .{
        channel_id,
        result.status_code,
    });

    const message = result.data() orelse {
        print_error_body(result.error_body());
        return;
    };

    std.debug.print("Interactive panel ready: {s}\n", .{message.id});
}

fn fetch_sample_message(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
    message_id: []const u8,
) !void {
    var get_result = try discord.messages.get(.{
        .channel_id = channel_id,
        .message_id = message_id,
    });
    defer get_result.deinit();

    std.debug.print("GET /channels/{s}/messages/{s} -> {d}\n", .{
        channel_id,
        message_id,
        get_result.status_code,
    });

    if (get_result.success) return;

    print_error_body(get_result.error_body());
}

fn edit_sample_message(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
    message_id: []const u8,
) !void {
    var edit_result = try discord.messages.edit(.{
        .channel_id = channel_id,
        .message_id = message_id,
        .content = edited_sample_message_content,
    });
    defer edit_result.deinit();

    std.debug.print("PATCH /channels/{s}/messages/{s} -> {d}\n", .{
        channel_id,
        message_id,
        edit_result.status_code,
    });

    if (edit_result.success) return;

    print_error_body(edit_result.error_body());
}

fn add_sample_reaction(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
    message_id: []const u8,
) !void {
    var reaction_result = try discord.messages.add_reaction(.{
        .channel_id = channel_id,
        .message_id = message_id,
        .emoji = sample_reaction,
    });
    defer reaction_result.deinit();

    std.debug.print("PUT reaction /channels/{s}/messages/{s} -> {d}\n", .{
        channel_id,
        message_id,
        reaction_result.status_code,
    });

    if (reaction_result.success) return;

    print_error_body(reaction_result.error_body());
}

fn remove_sample_reaction(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
    message_id: []const u8,
) !void {
    var reaction_result = try discord.messages.remove_own_reaction(.{
        .channel_id = channel_id,
        .message_id = message_id,
        .emoji = sample_reaction,
    });
    defer reaction_result.deinit();

    std.debug.print("DELETE reaction /channels/{s}/messages/{s} -> {d}\n", .{
        channel_id,
        message_id,
        reaction_result.status_code,
    });

    if (reaction_result.success) return;

    print_error_body(reaction_result.error_body());
}

fn reply_to_sample_message(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
    message_id: []const u8,
) !void {
    var reply_result = try discord.messages.reply(.{
        .channel_id = channel_id,
        .message_id = message_id,
        .content = sample_reply_content,
        .mention_replied_user = false,
    });
    defer reply_result.deinit();

    std.debug.print("POST reply /channels/{s}/messages -> {d}\n", .{
        channel_id,
        reply_result.status_code,
    });

    const reply_message = reply_result.data() orelse {
        print_error_body(reply_result.error_body());
        return;
    };

    try delete_sample_message(discord, channel_id, reply_message.id);
}

fn delete_sample_message(
    discord: *zcord.DiscordClient,
    channel_id: []const u8,
    message_id: []const u8,
) !void {
    var delete_result = try discord.messages.delete(.{
        .channel_id = channel_id,
        .message_id = message_id,
    });
    defer delete_result.deinit();

    std.debug.print("DELETE /channels/{s}/messages/{s} -> {d}\n", .{
        channel_id,
        message_id,
        delete_result.status_code,
    });

    if (delete_result.success) return;

    print_error_body(delete_result.error_body());
}

fn resolve_application_id(
    allocator: std.mem.Allocator,
    config: SampleConfig,
    current_user_id: ?[]const u8,
) !?[]u8 {
    if (config.application_id()) |value| {
        return try allocator.dupe(u8, value);
    }

    const value = current_user_id orelse return null;
    return try allocator.dupe(u8, value);
}

fn run_slash_command_samples(
    discord: *zcord.DiscordClient,
    config: SampleConfig,
    application_id: []const u8,
) !void {
    try list_global_commands(discord, application_id);

    const guild_id = config.guild_id() orelse {
        print_skipped_guild_commands();
        return;
    };

    try list_guild_commands(discord, application_id, guild_id);
    try upsert_guild_command(discord, application_id, guild_id);
}

fn list_global_commands(
    discord: *zcord.DiscordClient,
    application_id: []const u8,
) !void {
    var result = try discord.slash_commands.list_global(application_id);
    defer result.deinit();

    std.debug.print("GET /applications/{s}/commands -> {d}\n", .{
        application_id,
        result.status_code,
    });
    print_command_count_or_error(result);
}

fn list_guild_commands(
    discord: *zcord.DiscordClient,
    application_id: []const u8,
    guild_id: []const u8,
) !void {
    var result = try discord.slash_commands.list_guild(application_id, guild_id);
    defer result.deinit();

    std.debug.print("GET /applications/{s}/guilds/{s}/commands -> {d}\n", .{
        application_id,
        guild_id,
        result.status_code,
    });
    print_command_count_or_error(result);
}

fn upsert_guild_command(
    discord: *zcord.DiscordClient,
    application_id: []const u8,
    guild_id: []const u8,
) !void {
    var command_options: SampleCommandOptions = undefined;
    command_options.init();

    var result = try discord.slash_commands.create_guild(.{
        .application_id = application_id,
        .guild_id = guild_id,
        .name = sample_guild_command_name,
        .description = sample_guild_command_description,
        .options = command_options.options[0..],
    });
    defer result.deinit();

    std.debug.print("UPSERT guild command /{s} -> {d}\n", .{
        sample_guild_command_name,
        result.status_code,
    });
    const command = result.data() orelse {
        print_error_body(result.error_body());
        return;
    };

    std.debug.print("Guild slash command ready: /{s} ({s})\n", .{
        command.name,
        command.id,
    });
}

const SampleCommandOptions = struct {
    choices: [3]zcord.SlashCommandsResource.CommandOptionChoice,
    channel_types: [1]u16,
    options: [15]zcord.SlashCommandsResource.CommandOption,

    fn init(self: *SampleCommandOptions) void {
        const Options = zcord.SlashCommandsResource.Options;
        const ChannelTypes = zcord.SlashCommandsResource.ChannelTypes;

        self.* = .{
            .choices = .{
                Options.choice_string("hello", "hello"),
                Options.choice_string("status", "status"),
                Options.choice_string("modal", "modal"),
            },
            .channel_types = .{ChannelTypes.guild_text},
            .options = undefined,
        };

        const text_option = Options.with_choices(
            Options.with_length(Options.string("text", "Text to echo", false), 1, 80),
            self.choices[0..],
        );
        const count_option = Options.with_range(
            Options.integer("count", "Example count", false),
            0,
            10,
        );
        const score_option = Options.with_range(
            Options.number("score", "Example decimal score", false),
            0,
            100,
        );
        const enabled_option = Options.boolean("enabled", "Example flag", false);
        const ephemeral_option = Options.boolean("ephemeral", "Reply only to you", false);
        const embed_option = Options.boolean("embed", "Include a response embed", false);
        const buttons_option = Options.boolean("buttons", "Include response buttons", false);
        const image_option = Options.with_length(
            Options.string("image_url", "Embed image URL", false),
            8,
            200,
        );
        const thumbnail_option = Options.with_length(
            Options.string("thumbnail_url", "Embed thumbnail URL", false),
            8,
            200,
        );
        const user_option = Options.user("user", "Example user mention", false);
        const channel_option = Options.with_channel_types(
            Options.channel("channel", "Example channel", false),
            self.channel_types[0..],
        );
        const role_option = Options.role("role", "Example role mention", false);
        const mention_option = Options.mentionable(
            "mention",
            "Example user or role mention",
            false,
        );
        const attachment_option = Options.attachment("file", "Example attachment", false);
        const link_option = Options.with_length(
            Options.string("link_url", "Link button URL", false),
            8,
            200,
        );

        self.options = .{
            text_option,
            count_option,
            score_option,
            enabled_option,
            ephemeral_option,
            embed_option,
            buttons_option,
            image_option,
            thumbnail_option,
            user_option,
            channel_option,
            role_option,
            mention_option,
            attachment_option,
            link_option,
        };
    }
};

fn print_command_count_or_error(result: zcord.SlashCommandsResource.command_list_result) void {
    if (result.data()) |commands| {
        std.debug.print("Command count: {d}\n", .{commands.len});
        return;
    }

    print_error_body(result.error_body());
}

fn print_error_body(body_or_null: ?[]const u8) void {
    if (body_or_null) |body| {
        std.debug.print("Discord error body: {s}\n", .{body});
    }
}

fn print_skipped_application_commands() void {
    std.debug.print(
        "Skipping slash command tests. Add APPLICATION_ID or a valid bot token.\n",
        .{},
    );
}

fn print_skipped_guild_commands() void {
    std.debug.print("Skipping guild command tests. Add GUILD_ID to {s}.\n", .{
        env_file_path,
    });
}
