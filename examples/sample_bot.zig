const std = @import("std");
const zcord = @import("ZCord");

const SampleBot = @This();
const sample_component_custom_id = "zcord_sample:open_modal";
const sample_status_custom_id = "zcord_sample:status";
const sample_public_custom_id = "zcord_sample:public";
const sample_danger_custom_id = "zcord_sample:danger";
const button_modal_emoji = "\u{1F4DD}";
const button_status_emoji = "\u{2139}\u{FE0F}";
const button_public_emoji = "\u{1F4E3}";
const button_danger_emoji = "\u{26A0}\u{FE0F}";
const button_docs_emoji = "\u{1F517}";
const sample_modal_custom_id = "zcord_sample:modal";
const sample_modal_field_id = "feedback";
const sample_embed_image_url = "https://cdn.discordapp.com/embed/avatars/1.png";
const sample_embed_thumbnail_url = "https://cdn.discordapp.com/embed/avatars/0.png";
const sample_link_button_url =
    "https://discord.com/developers/docs/interactions/message-components";
const ephemeral_message_flag: u64 = 64;

const ReferenceKind = enum {
    user,
    channel,
    role,
};

pub fn init(self: *SampleBot) void {
    self.* = .{};
}

pub fn on_ready(ctx: zcord.DiscordContext) void {
    const event = ctx.ready() orelse return;

    std.debug.print("on_ready: {s} ({s}) session={s}\n", .{
        event.user.username,
        event.user.id,
        event.session_id,
    });
}

pub fn on_event(ctx: zcord.DiscordContext) void {
    const event = switch (ctx.payload) {
        .OnEvent => |gateway_event| gateway_event,
        else => return,
    };

    std.debug.print("on_event: {s}", .{event.name});
    if (event.sequence) |sequence| {
        std.debug.print(" seq={d}", .{sequence});
    }
    std.debug.print("\n", .{});
}

pub fn on_message(ctx: zcord.DiscordContext) void {
    const event = ctx.message() orelse return;

    const author_name = if (event.author) |author| author.username else "unknown";
    std.debug.print("on_message: {s}: {s}\n", .{ author_name, event.content });

    if (std.mem.eql(u8, event.content, "!zcord ping")) {
        ctx.reply("pong from ZCord") catch |err| print_callback_error("reply", err);
        return;
    }

    if (std.mem.eql(u8, event.content, "!zcord") or
        std.mem.eql(u8, event.content, "!zcord rich"))
    {
        send_rich_message(ctx);
        return;
    }
}

pub fn on_reaction(ctx: zcord.DiscordContext) void {
    const event = ctx.reaction() orelse return;

    std.debug.print("on_reaction: action={s} message={s} user={s} emoji={s}\n", .{
        @tagName(event.action),
        event.message_id,
        event.user_id,
        event.emoji.name orelse "(custom)",
    });
}

pub fn on_channel(ctx: zcord.DiscordContext) void {
    const event = ctx.channel() orelse return;
    switch (event.action) {
        .create, .update, .delete => {
            const channel = event.channel orelse return;
            std.debug.print("on_channel: action={s} channel={s}", .{
                @tagName(event.action),
                channel.id,
            });
            if (channel.name) |name| {
                std.debug.print(" name={s}", .{name});
            }
            if (channel.guild_id) |guild_id| {
                std.debug.print(" guild={s}", .{guild_id});
            }
            std.debug.print("\n", .{});
        },
        .pins_update => {
            const pins = event.pins_update orelse return;
            std.debug.print("on_channel: action=pins_update channel={s}", .{
                pins.channel_id,
            });
            if (pins.guild_id) |guild_id| {
                std.debug.print(" guild={s}", .{guild_id});
            }
            if (pins.last_pin_timestamp) |timestamp| {
                std.debug.print(" last_pin={s}", .{timestamp});
            }
            std.debug.print("\n", .{});
        },
    }
}

pub fn on_voice(ctx: zcord.DiscordContext) void {
    const event = ctx.voice() orelse return;
    switch (event.action) {
        .state_update => {
            const state = event.state orelse return;
            std.debug.print("on_voice: action=state_update user={s}", .{state.user_id});
            if (state.channel_id) |channel_id| {
                std.debug.print(" channel={s}", .{channel_id});
            } else {
                std.debug.print(" channel=(left)", .{});
            }
            if (state.guild_id) |guild_id| {
                std.debug.print(" guild={s}", .{guild_id});
            }
            std.debug.print(" muted={}", .{state.mute or state.self_mute});
            std.debug.print(" deafened={}\n", .{state.deaf or state.self_deaf});
        },
        .server_update => {
            const server = event.server orelse return;
            std.debug.print("on_voice: action=server_update guild={s}", .{
                server.guild_id,
            });
            if (server.endpoint) |endpoint| {
                std.debug.print(" endpoint={s}", .{endpoint});
            }
            std.debug.print(" token=(redacted)\n", .{});
        },
    }
}

pub fn on_slash_command(ctx: zcord.DiscordContext) void {
    const event = ctx.slash_command() orelse return;

    std.debug.print("on_slash_command: /{s} interaction={s}\n", .{
        event.name,
        event.id,
    });

    var response_buffer: [1024]u8 = undefined;
    const text = ctx.option_string("text") orelse "(none)";
    const count = ctx.option_integer("count") orelse 0;
    const score = ctx.option_number("score") orelse 0;
    const enabled = ctx.option_boolean("enabled") orelse false;
    const ephemeral = ctx.option_boolean("ephemeral") orelse false;
    const include_embed = ctx.option_boolean("embed") orelse true;
    const include_buttons = ctx.option_boolean("buttons") orelse true;
    const image_url = option_url_or_default(ctx, "image_url", sample_embed_image_url);
    const thumbnail_url = option_url_or_default(
        ctx,
        "thumbnail_url",
        sample_embed_thumbnail_url,
    );
    const link_url = option_url_or_default(ctx, "link_url", sample_link_button_url);

    var user_buffer: [96]u8 = undefined;
    var channel_buffer: [96]u8 = undefined;
    var role_buffer: [96]u8 = undefined;
    var mention_buffer: [160]u8 = undefined;
    var attachment_buffer: [384]u8 = undefined;
    var toggle_buffer: [96]u8 = undefined;
    var image_buffer: [512]u8 = undefined;

    const user_ref = format_reference(
        user_buffer[0..],
        .user,
        ctx.option_user_id("user"),
    );
    const channel_ref = format_reference(
        channel_buffer[0..],
        .channel,
        ctx.option_channel_id("channel"),
    );
    const role_ref = format_reference(
        role_buffer[0..],
        .role,
        ctx.option_role_id("role"),
    );
    const mention_ref = format_mentionable_reference(
        mention_buffer[0..],
        ctx.option_mentionable_id("mention"),
        ctx.option_mentionable_kind("mention"),
    );
    const attachment_ref = format_attachment_reference(
        attachment_buffer[0..],
        ctx.option_attachment("file"),
    );
    const toggle_ref = std.fmt.bufPrint(
        toggle_buffer[0..],
        "enabled={}\nembed={}\nbuttons={}",
        .{ enabled, include_embed, include_buttons },
    ) catch "toggle formatting failed";
    const image_ref = std.fmt.bufPrint(
        image_buffer[0..],
        "image: {s}\nthumbnail: {s}\nlink: {s}",
        .{ image_url, thumbnail_url, link_url },
    ) catch "image formatting failed";

    const response = std.fmt.bufPrint(
        response_buffer[0..],
        "slash ok\ntext={s}\ncount={d}\nscore={d}\nvisibility={s}",
        .{ text, count, score, if (ephemeral) "ephemeral" else "public" },
    ) catch "slash ok";

    const fields = [_]zcord.EmbedField{
        .{ .name = "Visibility", .value = if (ephemeral) "ephemeral" else "public" },
        .{ .name = "Toggles", .value = toggle_ref },
        .{ .name = "User", .value = user_ref, .@"inline" = true },
        .{ .name = "Channel", .value = channel_ref, .@"inline" = true },
        .{ .name = "Role", .value = role_ref, .@"inline" = true },
        .{ .name = "Mentionable", .value = mention_ref },
        .{ .name = "Attachment", .value = attachment_ref },
        .{ .name = "Media", .value = image_ref },
    };
    const embeds = [_]zcord.Embed{.{
        .title = "ZCord slash response",
        .description = "This embed is controlled by slash command options.",
        .color = 0x5865F2,
        .author = .{ .name = "ZiCord interactions" },
        .footer = .{ .text = "Set image_url and thumbnail_url to override images" },
        .image = .{ .url = image_url },
        .thumbnail = .{ .url = thumbnail_url },
        .fields = fields[0..],
    }};
    const buttons = response_buttons(link_url);
    const rows = [_]zcord.ActionRow{.{ .components = buttons[0..] }};
    const embed_slice: []const zcord.Embed = if (include_embed) embeds[0..] else &.{};
    const component_slice: []const zcord.ActionRow = if (include_buttons) rows[0..] else &.{};
    const flags: ?u64 = if (ephemeral) ephemeral_message_flag else null;

    ctx.interaction_reply(.{
        .content = response,
        .embeds = embed_slice,
        .components = component_slice,
        .flags = flags,
    }) catch |err| {
        print_callback_error("interaction_reply", err);
    };
}

pub fn on_component(ctx: zcord.DiscordContext) void {
    const event = ctx.component() orelse return;

    std.debug.print("on_component: custom_id={s} interaction={s}\n", .{
        event.custom_id,
        event.id,
    });

    if (std.mem.eql(u8, event.custom_id, sample_component_custom_id)) {
        show_feedback_modal(ctx);
        return;
    }

    if (std.mem.eql(u8, event.custom_id, sample_status_custom_id)) {
        ctx.interaction_reply(.{
            .content = "status ok: component callback is alive",
            .flags = ephemeral_message_flag,
        }) catch |err| print_callback_error("status_reply", err);
        return;
    }

    if (std.mem.eql(u8, event.custom_id, sample_public_custom_id)) {
        ctx.interaction_reply(.{
            .content = "public component reply from ZCord",
        }) catch |err| print_callback_error("public_reply", err);
        return;
    }

    if (std.mem.eql(u8, event.custom_id, sample_danger_custom_id)) {
        ctx.interaction_reply(.{
            .content = "danger button clicked",
            .flags = ephemeral_message_flag,
        }) catch |err| print_callback_error("danger_reply", err);
        return;
    }

    ctx.interaction_reply(.{
        .content = "component ok",
        .flags = ephemeral_message_flag,
    }) catch |err| print_callback_error("component_reply", err);
}

pub fn on_modal_submit(ctx: zcord.DiscordContext) void {
    const event = ctx.modal_submit() orelse return;

    std.debug.print("on_modal_submit: custom_id={s} interaction={s}\n", .{
        event.custom_id,
        event.id,
    });

    const feedback = ctx.modal_field(sample_modal_field_id) orelse "(empty)";
    var response_buffer: [256]u8 = undefined;
    const response = std.fmt.bufPrint(
        response_buffer[0..],
        "modal ok: {s}",
        .{feedback},
    ) catch "modal ok";

    ctx.interaction_reply(.{
        .content = response,
        .flags = ephemeral_message_flag,
    }) catch |err| print_callback_error("modal_reply", err);
}

fn send_rich_message(ctx: zcord.DiscordContext) void {
    const fields = [_]zcord.EmbedField{
        .{ .name = "Trigger", .value = "!zcord rich", .@"inline" = true },
        .{ .name = "Components", .value = "button + modal", .@"inline" = true },
        .{ .name = "Reply API", .value = "DiscordContext.send_rich" },
    };
    const embeds = [_]zcord.Embed{
        .{
            .title = "ZCord rich callback",
            .description = "This was sent from DiscordContext.send_rich.",
            .color = 0x57F287,
            .author = .{ .name = "ZiCord Gateway" },
            .footer = .{ .text = "Generated from MESSAGE_CREATE callback" },
            .image = .{ .url = sample_embed_image_url },
            .thumbnail = .{ .url = sample_embed_thumbnail_url },
            .fields = fields[0..],
        },
    };
    const buttons = response_buttons(sample_link_button_url);
    const rows = [_]zcord.ActionRow{.{ .components = buttons[0..] }};

    ctx.send_rich(.{
        .content = "rich message from callback",
        .embeds = embeds[0..],
        .components = rows[0..],
    }) catch |err| print_callback_error("send_rich", err);
}

fn show_feedback_modal(ctx: zcord.DiscordContext) void {
    const Modals = zcord.SlashCommandsResource.Modals;

    const input = Modals.with_required(
        Modals.with_length(
            Modals.text_input(sample_modal_field_id, "Feedback", .paragraph),
            1,
            200,
        ),
        true,
    );
    const inputs = [_]zcord.SlashCommandsResource.TextInput{input};
    const rows = [_]zcord.SlashCommandsResource.TextInputRow{
        Modals.row(inputs[0..]),
    };

    ctx.show_modal(.{
        .custom_id = sample_modal_custom_id,
        .title = "ZCord sample modal",
        .components = rows[0..],
    }) catch |err| print_callback_error("show_modal", err);
}

fn response_buttons(link_url: []const u8) [5]zcord.Button {
    return .{
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
            .url = link_url,
            .emoji = .{ .name = button_docs_emoji },
        },
    };
}

fn option_url_or_default(
    ctx: zcord.DiscordContext,
    name: []const u8,
    default_url: []const u8,
) []const u8 {
    const value = ctx.option_string(name) orelse return default_url;
    if (is_http_url(value)) return value;
    return default_url;
}

fn is_http_url(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "http://");
}

fn format_reference(
    buffer: []u8,
    kind: ReferenceKind,
    id_or_null: ?[]const u8,
) []const u8 {
    const id = id_or_null orelse return "(not provided)";

    return switch (kind) {
        .user => std.fmt.bufPrint(buffer, "<@{s}>\n`{s}`", .{ id, id }) catch id,
        .channel => std.fmt.bufPrint(buffer, "<#{s}>\n`{s}`", .{ id, id }) catch id,
        .role => std.fmt.bufPrint(buffer, "<@&{s}>\n`{s}`", .{ id, id }) catch id,
    };
}

fn format_mentionable_reference(
    buffer: []u8,
    id_or_null: ?[]const u8,
    kind_or_null: ?zcord.DiscordContext.MentionableKind,
) []const u8 {
    const id = id_or_null orelse return "(not provided)";
    const kind = kind_or_null orelse return std.fmt.bufPrint(
        buffer,
        "unknown mentionable\n`{s}`",
        .{id},
    ) catch id;

    return switch (kind) {
        .user => std.fmt.bufPrint(buffer, "user <@{s}>\n`{s}`", .{ id, id }) catch id,
        .role => std.fmt.bufPrint(buffer, "role <@&{s}>\n`{s}`", .{ id, id }) catch id,
    };
}

fn format_attachment_reference(
    buffer: []u8,
    attachment_or_null: ?zcord.DiscordContext.ResolvedAttachment,
) []const u8 {
    const attachment = attachment_or_null orelse return "(not provided)";
    const filename = attachment.filename orelse "(unknown filename)";
    const url = attachment.url orelse "(no url)";
    const content_type = attachment.content_type orelse "(unknown content type)";

    if (attachment.size) |size| {
        return std.fmt.bufPrint(
            buffer,
            "{s}\n`{s}`\n{s}\n{s}\n{d} bytes",
            .{ filename, attachment.id, content_type, url, size },
        ) catch attachment.id;
    }

    return std.fmt.bufPrint(
        buffer,
        "{s}\n`{s}`\n{s}\n{s}",
        .{ filename, attachment.id, content_type, url },
    ) catch attachment.id;
}

fn print_callback_error(action: []const u8, err: anyerror) void {
    std.debug.print("{s} failed: {s}\n", .{ action, @errorName(err) });
}
