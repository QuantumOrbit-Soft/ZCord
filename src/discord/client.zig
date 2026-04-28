const std = @import("std");
const zrqwest = @import("zrqwest");
const DiscordConfig = @import("config.zig").DiscordConfig;
const GatewayClient = @import("gateway_client.zig").GatewayClient;
const DiscordHttpClient = @import("http_client.zig").DiscordHttpClient;
const InteractionData = @import("interaction_data.zig").InteractionData;
const UsersResource = @import("../resources/users.zig").UsersResource;
const ChannelsResource = @import("../resources/channels.zig").ChannelsResource;
const MessagesResource = @import("../resources/messages.zig").MessagesResource;
const SlashCommandsResource = @import("../resources/slash_commands.zig").SlashCommandsResource;
const models = @import("../models/mod.zig");
const callback_runtime_mod = @import("callback_runtime.zig");
const event_payload_mod = @import("event_payload.zig");
const assert = std.debug.assert;
const sync_io = std.Options.debug_io;

allocator: std.mem.Allocator,
client: *zrqwest.RequestClient,
http: DiscordHttpClient,
gateway: GatewayClient,
users: UsersResource,
channels: ChannelsResource,
messages: MessagesResource,
slash_commands: SlashCommandsResource,
callbacks: EventCallbacks = .{},
callback_runtime: CallbackRuntime = .{},
callback_jobs: []CallbackJob = &.{},
callback_payload_storage: []u8 = &.{},
callback_payload_bytes_max: u32 = 0,
callback_job_pool_mutex: std.Io.Mutex = .init,

pub const DiscordClient = @This();
const Self = @This();
const CallbackRuntime = callback_runtime_mod.CallbackRuntime;
const CallbackTask = callback_runtime_mod.CallbackTask;
pub const callback_payload_bytes_max_default: u32 = 64 * 1024;

pub const init_params = struct {
    allocator: std.mem.Allocator,
    client: *zrqwest.RequestClient,
    token: []const u8,
    base_url: []const u8 = DiscordConfig.default_base_url,
    token_prefix: []const u8 = "Bot",
    user_agent: []const u8 = "ZCord/0.1",
    request_body_bytes_max: u32 = DiscordConfig.default_request_body_bytes_max,
    response_body_bytes_max: u32 = DiscordConfig.default_response_body_bytes_max,
    callback_thread_count: u16 = callback_thread_count_default,
    callback_queue_capacity: u16 = callback_queue_capacity_default,
    callback_payload_bytes_max: u32 = callback_payload_bytes_max_default,
};

const InteractionIdentity = struct {
    id: []const u8,
    token: []const u8,
};

const callback_thread_count_default = callback_runtime_mod.callback_thread_count_default;
const callback_queue_capacity_default = callback_runtime_mod.callback_queue_capacity_default;

pub const Event = event_payload_mod.Event;
pub const EventPayload = event_payload_mod.EventPayload;

pub const DiscordContext = struct {
    discord: *Self,
    payload: EventPayload,

    pub const SendOptions = struct {
        content: []const u8 = "",
        embeds: []const models.Embed = &.{},
        components: []const models.ActionRow = &.{},
        tts: bool = false,
        nonce: ?[]const u8 = null,
    };

    pub const InteractionReplyOptions = struct {
        content: []const u8 = "",
        embeds: []const models.Embed = &.{},
        components: []const models.ActionRow = &.{},
        flags: ?u64 = null,
    };

    pub const ModalOptions = struct {
        custom_id: []const u8,
        title: []const u8,
        components: []const SlashCommandsResource.TextInputRow,
    };

    pub const MentionableKind = InteractionData.MentionableKind;
    pub const ResolvedAttachment = InteractionData.ResolvedAttachment;

    pub fn ready(self: DiscordContext) ?GatewayClient.ReadyEvent {
        return switch (self.payload) {
            .OnReady => |event| event,
            else => null,
        };
    }

    pub fn message(self: DiscordContext) ?GatewayClient.MessageCreateEvent {
        return switch (self.payload) {
            .OnMessage => |event| event,
            else => null,
        };
    }

    pub fn reaction(self: DiscordContext) ?GatewayClient.MessageReactionEvent {
        return switch (self.payload) {
            .OnReaction => |event| event,
            else => null,
        };
    }

    pub fn channel(self: DiscordContext) ?GatewayClient.ChannelEvent {
        return switch (self.payload) {
            .OnChannel => |event| event,
            else => null,
        };
    }

    pub fn voice(self: DiscordContext) ?GatewayClient.VoiceEvent {
        return switch (self.payload) {
            .OnVoice => |event| event,
            else => null,
        };
    }

    pub fn slash_command(self: DiscordContext) ?GatewayClient.SlashCommandEvent {
        return switch (self.payload) {
            .OnSlashCommand => |event| event,
            else => null,
        };
    }

    pub fn component(self: DiscordContext) ?GatewayClient.ComponentEvent {
        return switch (self.payload) {
            .OnComponent => |event| event,
            else => null,
        };
    }

    pub fn modal_submit(self: DiscordContext) ?GatewayClient.ModalSubmitEvent {
        return switch (self.payload) {
            .OnModalSubmit => |event| event,
            else => null,
        };
    }

    pub fn send(self: DiscordContext, content: []const u8) !void {
        try self.send_rich(.{ .content = content });
    }

    pub fn send_rich(self: DiscordContext, options: SendOptions) !void {
        const event = self.message() orelse return error.ContextIsNotMessage;
        try self.discord.send_message_and_ensure_ok(event.channel_id, options);
    }

    pub fn reply(self: DiscordContext, content: []const u8) !void {
        try self.reply_rich(.{ .content = content });
    }

    pub fn reply_rich(self: DiscordContext, options: SendOptions) !void {
        if (self.message()) |event| {
            try self.discord.reply_message_and_ensure_ok(
                event.channel_id,
                event.id,
                options,
            );
            return;
        }

        if (self.interaction_identity()) |identity| {
            try self.discord.reply_interaction_and_ensure_ok(identity, .{
                .content = options.content,
                .embeds = options.embeds,
                .components = options.components,
            });
            return;
        }

        return error.ContextCannotReply;
    }

    pub fn react(self: DiscordContext, emoji: []const u8) !void {
        const event = self.message() orelse return error.ContextIsNotMessage;
        try self.discord.add_reaction_and_ensure_ok(.{
            .channel_id = event.channel_id,
            .message_id = event.id,
            .emoji = emoji,
        });
    }

    pub fn interaction_reply(
        self: DiscordContext,
        options: InteractionReplyOptions,
    ) !void {
        const identity = self.interaction_identity() orelse return error.ContextIsNotInteraction;
        try self.discord.reply_interaction_and_ensure_ok(identity, options);
    }

    pub fn show_modal(self: DiscordContext, options: ModalOptions) !void {
        const identity = self.interaction_identity() orelse return error.ContextIsNotInteraction;
        try self.discord.respond_modal_and_ensure_ok(identity, options);
    }

    pub fn option_string(self: DiscordContext, name: []const u8) ?[]const u8 {
        const event = self.slash_command() orelse return null;
        const value = InteractionData.option_value(event, name) orelse return null;
        return InteractionData.string_value(value);
    }

    pub fn option_integer(self: DiscordContext, name: []const u8) ?i64 {
        const event = self.slash_command() orelse return null;
        const value = InteractionData.option_value(event, name) orelse return null;
        return InteractionData.integer_value(value);
    }

    pub fn option_number(self: DiscordContext, name: []const u8) ?f64 {
        const event = self.slash_command() orelse return null;
        const value = InteractionData.option_value(event, name) orelse return null;
        return InteractionData.number_value(value);
    }

    pub fn option_boolean(self: DiscordContext, name: []const u8) ?bool {
        const event = self.slash_command() orelse return null;
        const value = InteractionData.option_value(event, name) orelse return null;
        return InteractionData.boolean_value(value);
    }

    pub fn option_snowflake(self: DiscordContext, name: []const u8) ?[]const u8 {
        return self.option_string(name);
    }

    pub fn option_user_id(self: DiscordContext, name: []const u8) ?[]const u8 {
        return self.option_snowflake(name);
    }

    pub fn option_channel_id(self: DiscordContext, name: []const u8) ?[]const u8 {
        return self.option_snowflake(name);
    }

    pub fn option_role_id(self: DiscordContext, name: []const u8) ?[]const u8 {
        return self.option_snowflake(name);
    }

    pub fn option_mentionable_id(self: DiscordContext, name: []const u8) ?[]const u8 {
        return self.option_snowflake(name);
    }

    pub fn option_attachment_id(self: DiscordContext, name: []const u8) ?[]const u8 {
        return self.option_snowflake(name);
    }

    pub fn option_mentionable_kind(self: DiscordContext, name: []const u8) ?MentionableKind {
        const event = self.slash_command() orelse return null;
        return InteractionData.mentionable_kind(event, name);
    }

    pub fn option_attachment(self: DiscordContext, name: []const u8) ?ResolvedAttachment {
        const event = self.slash_command() orelse return null;
        return InteractionData.attachment(event, name);
    }

    pub fn subcommand(self: DiscordContext) ?[]const u8 {
        const event = self.slash_command() orelse return null;
        return InteractionData.first_option_name_by_type(
            event,
            @intFromEnum(SlashCommandsResource.CommandOptionType.sub_command),
        );
    }

    pub fn subcommand_group(self: DiscordContext) ?[]const u8 {
        const event = self.slash_command() orelse return null;
        return InteractionData.first_option_name_by_type(
            event,
            @intFromEnum(SlashCommandsResource.CommandOptionType.sub_command_group),
        );
    }

    pub fn modal_field(self: DiscordContext, custom_id: []const u8) ?[]const u8 {
        const event = self.modal_submit() orelse return null;
        return InteractionData.modal_field_value(event, custom_id);
    }

    fn interaction_identity(self: DiscordContext) ?InteractionIdentity {
        return switch (self.payload) {
            .OnSlashCommand => |event| .{ .id = event.id, .token = event.token },
            .OnComponent => |event| .{ .id = event.id, .token = event.token },
            .OnModalSubmit => |event| .{ .id = event.id, .token = event.token },
            else => null,
        };
    }
};

pub const EventCallback = *const fn (DiscordContext) void;

const EventCallbacks = struct {
    on_ready: ?EventCallback = null,
    on_event: ?EventCallback = null,
    on_message: ?EventCallback = null,
    on_reaction: ?EventCallback = null,
    on_channel: ?EventCallback = null,
    on_voice: ?EventCallback = null,
    on_slash_command: ?EventCallback = null,
    on_component: ?EventCallback = null,
    on_modal_submit: ?EventCallback = null,
};

const CallbackJob = struct {
    task: CallbackTask,
    discord: *Self,
    callback: EventCallback,
    payload: EventPayload,
    payload_allocator: std.heap.FixedBufferAllocator,
    payload_storage: []u8,
    active: bool = false,
};

const CallbackHandler = struct {
    discord: *Self,

    pub fn on_ready(self: *CallbackHandler, event: GatewayClient.ReadyEvent) !void {
        self.discord.dispatch_callback(.OnReady, .{ .OnReady = event });
    }

    pub fn on_event(self: *CallbackHandler, event: GatewayClient.GatewayEvent) !void {
        self.discord.dispatch_callback(.OnEvent, .{ .OnEvent = event });
    }

    pub fn on_message(self: *CallbackHandler, event: GatewayClient.MessageCreateEvent) !void {
        self.discord.dispatch_callback(.OnMessage, .{ .OnMessage = event });
    }

    pub fn on_reaction(self: *CallbackHandler, event: GatewayClient.MessageReactionEvent) !void {
        self.discord.dispatch_callback(.OnReaction, .{ .OnReaction = event });
    }

    pub fn on_channel(self: *CallbackHandler, event: GatewayClient.ChannelEvent) !void {
        self.discord.dispatch_callback(.OnChannel, .{ .OnChannel = event });
    }

    pub fn on_voice(self: *CallbackHandler, event: GatewayClient.VoiceEvent) !void {
        self.discord.dispatch_callback(.OnVoice, .{ .OnVoice = event });
    }

    pub fn on_slash_command(
        self: *CallbackHandler,
        event: GatewayClient.SlashCommandEvent,
    ) !void {
        self.discord.dispatch_callback(.OnSlashCommand, .{ .OnSlashCommand = event });
    }

    pub fn on_component(
        self: *CallbackHandler,
        event: GatewayClient.ComponentEvent,
    ) !void {
        self.discord.dispatch_callback(.OnComponent, .{ .OnComponent = event });
    }

    pub fn on_modal_submit(
        self: *CallbackHandler,
        event: GatewayClient.ModalSubmitEvent,
    ) !void {
        self.discord.dispatch_callback(.OnModalSubmit, .{ .OnModalSubmit = event });
    }
};

pub fn init(
    self: *Self,
    params: init_params,
) !void {
    const config = DiscordConfig{
        .base_url = params.base_url,
        .token = params.token,
        .token_prefix = params.token_prefix,
        .user_agent = params.user_agent,
        .request_body_bytes_max = params.request_body_bytes_max,
        .response_body_bytes_max = params.response_body_bytes_max,
    };
    const config_normalized = config.normalized();
    try config_normalized.validate();

    self.* = .{
        .allocator = params.allocator,
        .client = params.client,
        .http = undefined,
        .gateway = undefined,
        .users = undefined,
        .channels = undefined,
        .messages = undefined,
        .slash_commands = undefined,
        .callbacks = .{},
        .callback_runtime = .{},
        .callback_jobs = &.{},
        .callback_payload_storage = &.{},
        .callback_payload_bytes_max = 0,
        .callback_job_pool_mutex = .init,
    };
    errdefer self.* = undefined;

    try self.http.init(.{
        .allocator = params.allocator,
        .client = params.client,
        .config = config_normalized,
    });
    errdefer self.http.deinit();

    self.users.init(params.allocator, &self.http);
    self.channels.init(params.allocator, &self.http);
    self.messages.init(params.allocator, &self.http);
    self.slash_commands.init(params.allocator, &self.http);
    try self.gateway.init(params.allocator, config_normalized.token);
    errdefer self.gateway.deinit();

    try self.callback_runtime.init(
        params.allocator,
        params.callback_thread_count,
        params.callback_queue_capacity,
    );
    errdefer self.callback_runtime.deinit();

    try self.init_callback_job_pool(.{
        .allocator = params.allocator,
        .job_count = params.callback_queue_capacity,
        .payload_bytes_max = params.callback_payload_bytes_max,
    });
}

pub fn deinit(self: *Self) void {
    self.gateway.deinit();
    self.callback_runtime.deinit();
    self.deinit_callback_job_pool();
    self.messages.deinit();
    self.slash_commands.deinit();
    self.channels.deinit();
    self.users.deinit();
    self.http.deinit();
    self.* = undefined;
}

const init_callback_job_pool_params = struct {
    allocator: std.mem.Allocator,
    job_count: u16,
    payload_bytes_max: u32,
};

fn init_callback_job_pool(
    self: *Self,
    params: init_callback_job_pool_params,
) !void {
    assert(self.callback_jobs.len == 0);
    assert(self.callback_payload_storage.len == 0);

    if (0 < params.job_count) {} else return error.InvalidCallbackJobCount;
    if (0 < params.payload_bytes_max) {} else return error.InvalidCallbackPayloadBytesMax;

    const job_count: usize = @intCast(params.job_count);
    const payload_bytes_max: usize = @intCast(params.payload_bytes_max);
    const payload_storage_bytes = std.math.mul(
        usize,
        job_count,
        payload_bytes_max,
    ) catch return error.CallbackPayloadStorageTooLarge;

    const jobs = try params.allocator.alloc(CallbackJob, job_count);
    errdefer params.allocator.free(jobs);

    const payload_storage = try params.allocator.alloc(u8, payload_storage_bytes);
    errdefer params.allocator.free(payload_storage);

    for (jobs, 0..) |*job, index| {
        const payload_start = index * payload_bytes_max;
        const payload_end = payload_start + payload_bytes_max;
        const payload_slice = payload_storage[payload_start..payload_end];

        job.* = .{
            .task = .{
                .run = run_callback_task,
                .destroy = destroy_callback_task,
            },
            .discord = self,
            .callback = undefined,
            .payload = undefined,
            .payload_allocator = std.heap.FixedBufferAllocator.init(payload_slice),
            .payload_storage = payload_slice,
            .active = false,
        };
    }

    self.callback_jobs = jobs;
    self.callback_payload_storage = payload_storage;
    self.callback_payload_bytes_max = params.payload_bytes_max;
}

fn deinit_callback_job_pool(self: *Self) void {
    if (self.callback_jobs.len == 0) return;

    const payload_bytes_max: usize = @intCast(self.callback_payload_bytes_max);

    for (self.callback_jobs) |*job| {
        assert(!job.active);
        assert(job.payload_storage.len == payload_bytes_max);
    }

    @memset(self.callback_payload_storage, 0);
    self.allocator.free(self.callback_payload_storage);
    self.allocator.free(self.callback_jobs);
    self.callback_jobs = &.{};
    self.callback_payload_storage = &.{};
    self.callback_payload_bytes_max = 0;
}

pub fn on(self: *Self, callback: EventCallback, event: Event) void {
    switch (event) {
        .OnReady => self.callbacks.on_ready = callback,
        .OnEvent => self.callbacks.on_event = callback,
        .OnMessage => self.callbacks.on_message = callback,
        .OnReaction => self.callbacks.on_reaction = callback,
        .OnChannel => self.callbacks.on_channel = callback,
        .OnVoice => self.callbacks.on_voice = callback,
        .OnSlashCommand => self.callbacks.on_slash_command = callback,
        .OnComponent => self.callbacks.on_component = callback,
        .OnModalSubmit => self.callbacks.on_modal_submit = callback,
    }
}

pub fn run_gateway(self: *Self, options: GatewayClient.RunOptions) !void {
    var handler = CallbackHandler{ .discord = self };
    try self.gateway.run(CallbackHandler, &handler, options);
}

pub fn run_gateway_with_handler(
    self: *Self,
    comptime Handler: type,
    handler: *Handler,
    options: GatewayClient.RunOptions,
) !void {
    try self.gateway.run(Handler, handler, options);
}

pub fn disconnect_gateway(self: *Self) void {
    self.gateway.disconnect();
}

pub fn send_message(
    self: *Self,
    params: MessagesResource.create_params,
) !MessagesResource.message_result {
    return self.messages.create(params);
}

pub fn reply_message(
    self: *Self,
    params: MessagesResource.reply_params,
) !MessagesResource.message_result {
    return self.messages.reply(params);
}

pub fn add_reaction(
    self: *Self,
    params: MessagesResource.reaction_params,
) !MessagesResource.reaction_result {
    return self.messages.add_reaction(params);
}

pub fn remove_own_reaction(
    self: *Self,
    params: MessagesResource.reaction_params,
) !MessagesResource.reaction_result {
    return self.messages.remove_own_reaction(params);
}

pub fn register_global_slash_command(
    self: *Self,
    params: SlashCommandsResource.create_global_params,
) !SlashCommandsResource.command_result {
    return self.slash_commands.create_global(params);
}

pub fn register_guild_slash_command(
    self: *Self,
    params: SlashCommandsResource.create_guild_params,
) !SlashCommandsResource.command_result {
    return self.slash_commands.create_guild(params);
}

pub fn sync_global_slash_commands(
    self: *Self,
    params: SlashCommandsResource.overwrite_global_params,
) !SlashCommandsResource.command_list_result {
    return self.slash_commands.overwrite_global(params);
}

pub fn sync_guild_slash_commands(
    self: *Self,
    params: SlashCommandsResource.overwrite_guild_params,
) !SlashCommandsResource.command_list_result {
    return self.slash_commands.overwrite_guild(params);
}

fn send_message_and_ensure_ok(
    self: *Self,
    channel_id: []const u8,
    options: DiscordContext.SendOptions,
) !void {
    var result = try self.messages.create(.{
        .channel_id = channel_id,
        .content = options.content,
        .embeds = options.embeds,
        .components = options.components,
        .tts = options.tts,
        .nonce = options.nonce,
    });
    defer result.deinit();

    if (result.success) {} else return error.SendMessageFailed;
}

fn reply_message_and_ensure_ok(
    self: *Self,
    channel_id: []const u8,
    message_id: []const u8,
    options: DiscordContext.SendOptions,
) !void {
    var result = try self.messages.reply(.{
        .channel_id = channel_id,
        .message_id = message_id,
        .content = options.content,
        .embeds = options.embeds,
        .components = options.components,
        .tts = options.tts,
        .nonce = options.nonce,
    });
    defer result.deinit();

    if (result.success) {} else return error.ReplyMessageFailed;
}

fn add_reaction_and_ensure_ok(
    self: *Self,
    params: MessagesResource.reaction_params,
) !void {
    var result = try self.messages.add_reaction(params);
    defer result.deinit();

    if (result.success) {} else return error.AddReactionFailed;
}

fn reply_interaction_and_ensure_ok(
    self: *Self,
    identity: InteractionIdentity,
    options: DiscordContext.InteractionReplyOptions,
) !void {
    var result = try self.slash_commands.respond_to_interaction(.{
        .interaction_id = identity.id,
        .interaction_token = identity.token,
        .content = options.content,
        .embeds = options.embeds,
        .components = options.components,
        .flags = options.flags,
    });
    defer result.deinit();

    if (result.success) {} else return error.InteractionRespondFailed;
}

fn respond_modal_and_ensure_ok(
    self: *Self,
    identity: InteractionIdentity,
    options: DiscordContext.ModalOptions,
) !void {
    var result = try self.slash_commands.respond_modal_to_interaction(.{
        .interaction_id = identity.id,
        .interaction_token = identity.token,
        .custom_id = options.custom_id,
        .title = options.title,
        .components = options.components,
    });
    defer result.deinit();

    if (result.success) {} else return error.InteractionModalFailed;
}

fn dispatch_callback(self: *Self, event: Event, payload: EventPayload) void {
    const callback_or_null = switch (event) {
        .OnReady => self.callbacks.on_ready,
        .OnEvent => self.callbacks.on_event,
        .OnMessage => self.callbacks.on_message,
        .OnReaction => self.callbacks.on_reaction,
        .OnChannel => self.callbacks.on_channel,
        .OnVoice => self.callbacks.on_voice,
        .OnSlashCommand => self.callbacks.on_slash_command,
        .OnComponent => self.callbacks.on_component,
        .OnModalSubmit => self.callbacks.on_modal_submit,
    };
    const callback = callback_or_null orelse return;
    const job = self.create_callback_job(callback, payload) catch {
        self.run_callback_inline(callback, payload);
        return;
    };

    if (self.callback_runtime.enqueue(&job.task)) return;

    destroy_callback_task(&job.task);
    std.debug.print("ZCord callback queue full or closed for {s}\n", .{@tagName(event)});
    self.run_callback_inline(callback, payload);
}

fn run_callback_inline(self: *Self, callback: EventCallback, payload: EventPayload) void {
    assert(self.callback_jobs.len > 0);
    callback(.{
        .discord = self,
        .payload = payload,
    });
}

fn create_callback_job(
    self: *Self,
    callback: EventCallback,
    payload: EventPayload,
) !*CallbackJob {
    const job = try self.acquire_callback_job();
    errdefer self.release_callback_job(job);

    job.callback = callback;
    job.payload = try event_payload_mod.clone(job.payload_allocator.allocator(), payload);
    return job;
}

fn acquire_callback_job(self: *Self) !*CallbackJob {
    assert(self.callback_jobs.len > 0);
    assert(self.callback_payload_bytes_max > 0);

    self.callback_job_pool_mutex.lockUncancelable(sync_io);
    defer self.callback_job_pool_mutex.unlock(sync_io);

    for (self.callback_jobs) |*job| {
        if (job.active) continue;

        const payload_bytes_max: usize = @intCast(self.callback_payload_bytes_max);
        assert(job.payload_storage.len == payload_bytes_max);
        job.active = true;
        job.discord = self;
        job.callback = undefined;
        job.payload = undefined;
        job.task = .{
            .run = run_callback_task,
            .destroy = destroy_callback_task,
        };
        job.payload_allocator = std.heap.FixedBufferAllocator.init(job.payload_storage);
        return job;
    }

    return error.CallbackJobPoolFull;
}

fn release_callback_job(self: *Self, job: *CallbackJob) void {
    self.callback_job_pool_mutex.lockUncancelable(sync_io);
    defer self.callback_job_pool_mutex.unlock(sync_io);

    assert(job.discord == self);
    assert(job.active);
    assert(job.payload_allocator.end_index <= job.payload_storage.len);

    @memset(job.payload_storage[0..job.payload_allocator.end_index], 0);
    job.payload_allocator = std.heap.FixedBufferAllocator.init(job.payload_storage);
    job.callback = undefined;
    job.payload = undefined;
    job.active = false;
}

fn run_callback_task(task: *CallbackTask) void {
    const job: *CallbackJob = @fieldParentPtr("task", task);
    job.callback(.{
        .discord = job.discord,
        .payload = job.payload,
    });
}

fn destroy_callback_task(task: *CallbackTask) void {
    const job: *CallbackJob = @fieldParentPtr("task", task);
    job.discord.release_callback_job(job);
}

fn sleep_test_milliseconds(milliseconds: u64) void {
    std.Io.sleep(
        std.Options.debug_io,
        std.Io.Duration.fromMilliseconds(@intCast(milliseconds)),
        .awake,
    ) catch {};
}

test "DiscordClient dispatches registered callbacks without blocking gateway loop" {
    const allocator = std.testing.allocator;

    const Probe = struct {
        var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var content_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn reset() void {
            release.store(false, .release);
            done.store(false, .release);
            content_ok.store(false, .release);
        }

        fn on_message(ctx: DiscordContext) void {
            while (!release.load(.acquire)) {
                sleep_test_milliseconds(1);
            }

            const event = ctx.message() orelse return;
            content_ok.store(std.mem.eql(u8, event.content, "async hello"), .release);
            done.store(true, .release);
        }

        fn watchdog() void {
            sleep_test_milliseconds(200);
            release.store(true, .release);
        }
    };
    Probe.reset();

    var request_client: zrqwest.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var discord: DiscordClient = undefined;
    try discord.init(.{
        .allocator = allocator,
        .client = &request_client,
        .token = "abc",
        .callback_thread_count = 1,
        .callback_queue_capacity = 4,
    });
    defer discord.deinit();

    discord.on(Probe.on_message, .OnMessage);

    const watchdog = try std.Thread.spawn(.{}, Probe.watchdog, .{});
    defer watchdog.join();

    discord.dispatch_callback(.OnMessage, .{ .OnMessage = .{
        .id = "message-1",
        .channel_id = "channel-1",
        .content = "async hello",
    } });

    try std.testing.expect(!Probe.done.load(.acquire));
    Probe.release.store(true, .release);

    var attempts: u16 = 0;
    while (!Probe.done.load(.acquire) and attempts < 1000) : (attempts += 1) {
        sleep_test_milliseconds(1);
    }

    try std.testing.expect(Probe.done.load(.acquire));
    try std.testing.expect(Probe.content_ok.load(.acquire));
}

test "DiscordClient dispatch callback uses preallocated job payload storage" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();

    const Probe = struct {
        var done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var content_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn reset() void {
            done.store(false, .release);
            content_ok.store(false, .release);
        }

        fn on_message(ctx: DiscordContext) void {
            const event = ctx.message() orelse return;
            content_ok.store(std.mem.eql(u8, event.content, "preallocated"), .release);
            done.store(true, .release);
        }
    };
    Probe.reset();

    var request_client: zrqwest.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var discord: DiscordClient = undefined;
    try discord.init(.{
        .allocator = allocator,
        .client = &request_client,
        .token = "abc",
        .callback_thread_count = 1,
        .callback_queue_capacity = 2,
        .callback_payload_bytes_max = 2048,
    });
    defer discord.deinit();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    discord.on(Probe.on_message, .OnMessage);

    discord.dispatch_callback(.OnMessage, .{ .OnMessage = .{
        .id = "message-1",
        .channel_id = "channel-1",
        .content = "preallocated",
    } });

    var attempts: u16 = 0;
    while (!Probe.done.load(.acquire) and attempts < 1000) : (attempts += 1) {
        sleep_test_milliseconds(1);
    }

    try std.testing.expect(Probe.done.load(.acquire));
    try std.testing.expect(Probe.content_ok.load(.acquire));
    try std.testing.expect(!failing_allocator.has_induced_failure);
}

test "DiscordClient runs callback inline when fixed payload pool is too small" {
    const allocator = std.testing.allocator;

    const Probe = struct {
        var called: bool = false;

        fn reset() void {
            called = false;
        }

        fn on_message(ctx: DiscordContext) void {
            const event = ctx.message() orelse return;
            called = std.mem.eql(u8, event.content, "payload larger than pool");
        }
    };
    Probe.reset();

    var request_client: zrqwest.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var discord: DiscordClient = undefined;
    try discord.init(.{
        .allocator = allocator,
        .client = &request_client,
        .token = "abc",
        .callback_thread_count = 1,
        .callback_queue_capacity = 1,
        .callback_payload_bytes_max = 1,
    });
    defer discord.deinit();

    discord.on(Probe.on_message, .OnMessage);
    discord.dispatch_callback(.OnMessage, .{ .OnMessage = .{
        .id = "message-1",
        .channel_id = "channel-1",
        .content = "payload larger than pool",
    } });

    try std.testing.expect(Probe.called);
}

test "DiscordClient clones callback payload before parsed JSON is released" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": "command-1",
        \\  "name": "zcord",
        \\  "options": [
        \\    { "type": 3, "name": "text", "value": "owned payload" }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const cloned = try event_payload_mod.clone(arena.allocator(), .{
        .OnSlashCommand = .{
            .id = "interaction-1",
            .token = "interaction-token",
            .name = "zcord",
            .data = parsed.value,
        },
    });
    parsed.deinit();

    const context = DiscordContext{
        .discord = undefined,
        .payload = cloned,
    };

    try std.testing.expectEqualStrings(
        "owned payload",
        context.option_string("text") orelse return error.MissingClonedOption,
    );
}
