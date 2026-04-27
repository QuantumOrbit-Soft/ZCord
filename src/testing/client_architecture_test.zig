const std = @import("std");
const zcord = @import("../root.zig");

test "DiscordConfig.validate requires base_url and token" {
    var cfg_missing_base = zcord.DiscordConfig{
        .base_url = "",
        .token = "abc",
    };
    try std.testing.expectError(error.MissingBaseUrl, cfg_missing_base.validate());

    var cfg_missing_token = zcord.DiscordConfig{
        .base_url = "https://discord.com/api/v10",
        .token = "",
    };
    try std.testing.expectError(error.MissingToken, cfg_missing_token.validate());
}

test "DiscordConfig.validate rejects base_url with missing host" {
    var cfg_missing_host = zcord.DiscordConfig{
        .base_url = "https://",
        .token = "abc",
    };
    try std.testing.expectError(error.InvalidBaseUrl, cfg_missing_host.validate());
}

test "DiscordConfig defaults to Discord REST API base URL" {
    const cfg = zcord.DiscordConfig{
        .token = "abc",
    };

    try cfg.validate();
    try std.testing.expectEqualStrings(
        zcord.DiscordConfig.default_base_url,
        cfg.normalized().base_url,
    );
}

test "DiscordClient.init accepts external zrqwest client" {
    const allocator = std.testing.allocator;

    var request_client: zcord.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var sdk: zcord.DiscordClient = undefined;
    try sdk.init(.{
        .allocator = allocator,
        .client = &request_client,
        .base_url = "https://discord.com/api/v10",
        .token = "abc",
    });
    defer sdk.deinit();

    try std.testing.expect(@TypeOf(sdk.users) == zcord.UsersResource);
    try std.testing.expect(@TypeOf(sdk.channels) == zcord.ChannelsResource);
    try std.testing.expect(@TypeOf(sdk.messages) == zcord.MessagesResource);
    try std.testing.expect(@TypeOf(sdk.slash_commands) == zcord.SlashCommandsResource);
    try std.testing.expect(@TypeOf(sdk.client) == *zcord.RequestClient);
}

test "DiscordClient keeps borrowed transport and owned runtime state" {
    comptime {
        const fields = @typeInfo(zcord.DiscordClient).@"struct".fields;
        try std.testing.expectEqual(@as(usize, 10), fields.len);
        try std.testing.expectEqualStrings("allocator", fields[0].name);
        try std.testing.expectEqualStrings("client", fields[1].name);
        try std.testing.expectEqualStrings("http", fields[2].name);
        try std.testing.expectEqualStrings("gateway", fields[3].name);
        try std.testing.expectEqualStrings("users", fields[4].name);
        try std.testing.expectEqualStrings("channels", fields[5].name);
        try std.testing.expectEqualStrings("messages", fields[6].name);
        try std.testing.expectEqualStrings("slash_commands", fields[7].name);
        try std.testing.expectEqualStrings("callbacks", fields[8].name);
        try std.testing.expectEqualStrings("callback_runtime", fields[9].name);
    }
}

test "DiscordClient exposes typed callback registry API" {
    comptime {
        try std.testing.expect(@hasDecl(zcord.DiscordClient, "on"));
        try std.testing.expect(@hasDecl(zcord.DiscordClient, "run_gateway"));
        try std.testing.expect(@hasDecl(zcord.DiscordClient, "run_gateway_with_handler"));
        try std.testing.expect(@hasDecl(zcord.DiscordClient, "disconnect_gateway"));
        try std.testing.expect(@hasDecl(zcord, "Event"));
        try std.testing.expect(@hasDecl(zcord, "DiscordContext"));
        try std.testing.expect(@hasDecl(zcord, "GatewayEvent"));
        try std.testing.expect(@hasDecl(zcord, "ReadyEvent"));
        try std.testing.expect(@hasDecl(zcord, "MessageCreateEvent"));
        try std.testing.expect(@hasDecl(zcord, "MessageReactionEvent"));
        try std.testing.expect(@hasDecl(zcord, "MessageReactionAddEvent"));
        try std.testing.expect(@hasDecl(zcord, "ChannelEvent"));
        try std.testing.expect(@hasDecl(zcord, "ChannelAction"));
        try std.testing.expect(@hasDecl(zcord, "ChannelPinsUpdateEvent"));
        try std.testing.expect(@hasDecl(zcord, "VoiceEvent"));
        try std.testing.expect(@hasDecl(zcord, "VoiceAction"));
        try std.testing.expect(@hasDecl(zcord, "VoiceStateEvent"));
        try std.testing.expect(@hasDecl(zcord, "VoiceServerUpdateEvent"));
        try std.testing.expect(@hasDecl(zcord, "SlashCommandEvent"));
        try std.testing.expect(@hasDecl(zcord, "ComponentEvent"));
        try std.testing.expect(@hasDecl(zcord, "ModalSubmitEvent"));
        try std.testing.expect(@hasDecl(zcord, "ReactionAction"));
    }
}

test "DiscordClient exposes bounded callback runtime options" {
    comptime {
        const Params = zcord.DiscordClient.init_params;
        try std.testing.expect(@hasField(Params, "callback_thread_count"));
        try std.testing.expect(@hasField(Params, "callback_queue_capacity"));
    }
}

test "DiscordClient delegates callback runtime and payload ownership" {
    comptime {
        const CallbackRuntime = @import("../discord/callback_runtime.zig").CallbackRuntime;
        const EventPayload = @import("../discord/event_payload.zig");
        try std.testing.expect(@hasDecl(CallbackRuntime, "init"));
        try std.testing.expect(@hasDecl(CallbackRuntime, "enqueue"));
        try std.testing.expect(@hasDecl(EventPayload, "clone"));
        try std.testing.expect(@hasDecl(EventPayload, "EventPayload"));
    }
}

test "DiscordClient source keeps async callback internals out of coordinator" {
    assert_source_absent(@embedFile("../discord/client.zig"), "const CallbackRuntime = struct");
    assert_source_absent(@embedFile("../discord/client.zig"), "fn clone_event_payload");
    assert_source_absent(@embedFile("../discord/client.zig"), "fn clone_json_value");
}

test "DiscordClient.on accepts strongly typed event callbacks" {
    const Callback = struct {
        fn on_message(ctx: zcord.DiscordContext) void {
            _ = ctx.message() orelse return;
        }
    };

    const callback: zcord.EventCallback = Callback.on_message;
    _ = callback;
}

test "public types use in-place init contracts" {
    comptime {
        const sdk_init: *const fn (
            *zcord.DiscordClient,
            zcord.DiscordClient.init_params,
        ) anyerror!void = zcord.DiscordClient.init;
        const http_init: *const fn (
            *zcord.DiscordHttpClient,
            zcord.DiscordHttpClient.init_params,
        ) anyerror!void = zcord.DiscordHttpClient.init;
        const gateway_init: *const fn (
            *zcord.GatewayClient,
            std.mem.Allocator,
            []const u8,
        ) anyerror!void = zcord.GatewayClient.init;
        const users_init: *const fn (
            *zcord.UsersResource,
            std.mem.Allocator,
            *zcord.DiscordHttpClient,
        ) void = zcord.UsersResource.init;
        const channels_init: *const fn (
            *zcord.ChannelsResource,
            std.mem.Allocator,
            *zcord.DiscordHttpClient,
        ) void = zcord.ChannelsResource.init;
        const messages_init: *const fn (
            *zcord.MessagesResource,
            std.mem.Allocator,
            *zcord.DiscordHttpClient,
        ) void = zcord.MessagesResource.init;
        const slash_commands_init: *const fn (
            *zcord.SlashCommandsResource,
            std.mem.Allocator,
            *zcord.DiscordHttpClient,
        ) void = zcord.SlashCommandsResource.init;

        _ = sdk_init;
        _ = http_init;
        _ = gateway_init;
        _ = users_init;
        _ = channels_init;
        _ = messages_init;
        _ = slash_commands_init;
    }
}

test "public API exports Discord models" {
    try std.testing.expect(zcord.UsersResource.User == zcord.User);
    try std.testing.expect(zcord.ChannelsResource.Channel == zcord.Channel);
    try std.testing.expect(zcord.MessagesResource.Message == zcord.Message);
}

test "DiscordClient.init keeps stable http pointers for resources" {
    const allocator = std.testing.allocator;

    var request_client: zcord.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var sdk: zcord.DiscordClient = undefined;
    try sdk.init(.{
        .allocator = allocator,
        .client = &request_client,
        .base_url = "https://discord.com/api/v10",
        .token = "abc",
    });
    defer sdk.deinit();

    try std.testing.expectEqual(@intFromPtr(&sdk.http), @intFromPtr(sdk.users.client));
    try std.testing.expectEqual(@intFromPtr(&sdk.http), @intFromPtr(sdk.channels.client));
    try std.testing.expectEqual(@intFromPtr(&sdk.http), @intFromPtr(sdk.messages.client));
    try std.testing.expectEqual(@intFromPtr(&sdk.http), @intFromPtr(sdk.slash_commands.client));
    try std.testing.expectEqual(@intFromPtr(&request_client), @intFromPtr(sdk.client));
}

test "DiscordClient.deinit properly cleans up resources without owning transport" {
    const allocator = std.testing.allocator;

    var request_client: zcord.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var sdk: zcord.DiscordClient = undefined;
    try sdk.init(.{
        .allocator = allocator,
        .client = &request_client,
        .base_url = "https://discord.com/api/v10",
        .token = "abc",
    });
    sdk.deinit();

    // Ensure deinit doesn't crash - basic smoke test
    try std.testing.expect(true);
}

test "public API no longer exports generic transport layer" {
    try std.testing.expect(!@hasDecl(zcord, "HttpClient"));
    try std.testing.expect(!@hasDecl(zcord, "HttpTransport"));
    try std.testing.expect(!@hasDecl(zcord, "ZrqwestTransport"));
    try std.testing.expect(!@hasDecl(zcord.DiscordClient, "init_with_transport"));
    try std.testing.expect(!@hasDecl(zcord.DiscordClient, "init_with_zrqwest_client"));
    try std.testing.expect(!@hasDecl(zcord.DiscordClient, "init_owned"));
    try std.testing.expect(!@hasDecl(zcord.DiscordClient, "init_internal"));
    try std.testing.expect(!@hasDecl(zcord.UsersResource, "init_for_test"));
    try std.testing.expect(!@hasDecl(zcord.UsersResource, "send"));
    try std.testing.expect(!@hasDecl(zcord.UsersResource, "send_request"));
}

test "project source avoids erased callback and payload APIs" {
    assert_no_erased_types(@embedFile("../discord/client.zig"));
    assert_no_erased_types(@embedFile("../discord/gateway_client.zig"));
    assert_no_erased_types(@embedFile("../discord/http_client.zig"));
}

test "resource route encoding lives outside MessagesResource" {
    const routes = @import("../routes/mod.zig");

    comptime {
        if (!@hasDecl(routes, "PercentEncoder")) {
            @compileError("route percent encoding must live in routes.PercentEncoder");
        }
        if (!@hasDecl(routes.PercentEncoder, "encode")) {
            @compileError("routes.PercentEncoder must expose encode");
        }
    }

    assert_source_absent(@embedFile("../resources/messages.zig"), "fn percent_encode");
    assert_source_absent(@embedFile("../resources/messages.zig"), "std.ArrayList");
}

test "DiscordHttpClient delegates header policy" {
    const http_headers = @import("../discord/http_headers.zig");

    comptime {
        if (!@hasDecl(http_headers, "HeaderSet")) {
            @compileError("Discord HTTP header policy must live in HeaderSet");
        }
        if (!@hasDecl(http_headers.HeaderSet, "authorized_json")) {
            @compileError("HeaderSet must expose authorized_json");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn request_headers");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn json_request_headers");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn public_headers");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn json_public_headers");
}

test "DiscordHttpClient delegates request URL resolution" {
    const request_url = @import("../discord/request_url.zig");

    comptime {
        if (!@hasDecl(request_url, "RequestUrl")) {
            @compileError("Discord HTTP URL resolution must live in RequestUrl");
        }
        if (!@hasDecl(request_url.RequestUrl, "resolve")) {
            @compileError("RequestUrl must expose resolve");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn resolve_url");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "const resolve_url_error");
}

test "DiscordHttpClient delegates response body limit policy" {
    const response_body_guard = @import("../discord/response_body_guard.zig");

    comptime {
        if (!@hasDecl(response_body_guard, "ResponseBodyGuard")) {
            @compileError("Discord HTTP response body policy must live in ResponseBodyGuard");
        }
        if (!@hasDecl(response_body_guard.ResponseBodyGuard, "enforce")) {
            @compileError("ResponseBodyGuard must expose enforce");
        }
    }

    assert_source_absent(
        @embedFile("../discord/http_client.zig"),
        "fn enforce_response_body_bytes_max",
    );
}

test "DiscordHttpClient delegates json body ownership" {
    const json_body = @import("../discord/json_body.zig");

    comptime {
        if (!@hasDecl(json_body, "JsonBody")) {
            @compileError("Discord HTTP JSON body ownership must live in JsonBody");
        }
        if (!@hasDecl(json_body.JsonBody, "init")) {
            @compileError("JsonBody must expose init");
        }
        if (!@hasDecl(json_body.JsonBody, "deinit")) {
            @compileError("JsonBody must expose deinit");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "std.json.Stringify.valueAlloc");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "emit_null_optional_fields");
}

test "DiscordHttpClient delegates request context setup" {
    const http_request_context = @import("../discord/http_request_context.zig");

    comptime {
        if (!@hasDecl(http_request_context, "HttpRequestContext")) {
            @compileError("Discord HTTP request setup must live in HttpRequestContext");
        }
        if (!@hasDecl(http_request_context.HttpRequestContext, "init")) {
            @compileError("HttpRequestContext must expose init");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn init_headers");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn init_request_url");
}

test "DiscordHttpClient delegates authorization header ownership" {
    const authorization_header = @import("../discord/authorization_header.zig");

    comptime {
        if (!@hasDecl(authorization_header, "AuthorizationHeader")) {
            @compileError("Discord HTTP auth header ownership must live in AuthorizationHeader");
        }
        if (!@hasDecl(authorization_header.AuthorizationHeader, "init")) {
            @compileError("AuthorizationHeader must expose init");
        }
        if (!@hasDecl(authorization_header.AuthorizationHeader, "deinit")) {
            @compileError("AuthorizationHeader must expose deinit");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "fn authorization_header_value");
    assert_source_absent(@embedFile("../discord/http_client.zig"), "std.fmt.allocPrint");
}

test "DiscordHttpClient delegates user-agent header ownership" {
    const user_agent_header = @import("../discord/user_agent_header.zig");

    comptime {
        if (!@hasDecl(user_agent_header, "UserAgentHeader")) {
            @compileError("Discord HTTP user-agent ownership must live in UserAgentHeader");
        }
        if (!@hasDecl(user_agent_header.UserAgentHeader, "init")) {
            @compileError("UserAgentHeader must expose init");
        }
        if (!@hasDecl(user_agent_header.UserAgentHeader, "deinit")) {
            @compileError("UserAgentHeader must expose deinit");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "user_agent_header_value: []u8");
    assert_source_absent(
        @embedFile("../discord/http_client.zig"),
        "const user_agent_header_value = try allocator.dupe",
    );
}

test "DiscordHttpClient delegates base URL ownership" {
    const base_url = @import("../discord/base_url.zig");

    comptime {
        if (!@hasDecl(base_url, "BaseUrl")) {
            @compileError("Discord HTTP base URL ownership must live in BaseUrl");
        }
        if (!@hasDecl(base_url.BaseUrl, "init")) {
            @compileError("BaseUrl must expose init");
        }
        if (!@hasDecl(base_url.BaseUrl, "deinit")) {
            @compileError("BaseUrl must expose deinit");
        }
    }

    assert_source_absent(@embedFile("../discord/http_client.zig"), "base_url: []const u8");
    assert_source_absent(
        @embedFile("../discord/http_client.zig"),
        "const base_url_value = try allocator.dupe",
    );
}

test "DiscordClient delegates interaction payload parsing" {
    const interaction_data = @import("../discord/interaction_data.zig");

    comptime {
        if (!@hasDecl(interaction_data, "InteractionData")) {
            @compileError("Discord interaction parsing must live in InteractionData");
        }
        if (!@hasDecl(interaction_data.InteractionData, "option_value")) {
            @compileError("InteractionData must expose option_value");
        }
        if (!@hasDecl(interaction_data.InteractionData, "modal_field_value")) {
            @compileError("InteractionData must expose modal_field_value");
        }
    }

    assert_source_absent(@embedFile("../discord/client.zig"), "fn interaction_option_value");
    assert_source_absent(@embedFile("../discord/client.zig"), "fn modal_field_value");
    assert_source_absent(@embedFile("../discord/client.zig"), "fn json_string_value");
    assert_source_absent(@embedFile("../discord/client.zig"), "fn find_option_value_in_node");
}

test "GatewayClient delegates gateway protocol policy" {
    const gateway_protocol = @import("../discord/gateway_protocol.zig");

    comptime {
        if (!@hasDecl(gateway_protocol, "GatewayProtocol")) {
            @compileError("Discord Gateway protocol policy must live in GatewayProtocol");
        }
        if (!@hasDecl(gateway_protocol.GatewayProtocol, "Opcode")) {
            @compileError("GatewayProtocol must expose Opcode");
        }
        if (!@hasDecl(gateway_protocol.GatewayProtocol, "validate_token")) {
            @compileError("GatewayProtocol must expose validate_token");
        }
        if (!@hasDecl(gateway_protocol.GatewayProtocol, "validate_run_options")) {
            @compileError("GatewayProtocol must expose validate_run_options");
        }
    }

    assert_source_absent(@embedFile("../discord/gateway_client.zig"), "const Opcode = enum");
    assert_source_absent(
        @embedFile("../discord/gateway_client.zig"),
        "const GatewayPayload = struct",
    );
    assert_source_absent(@embedFile("../discord/gateway_client.zig"), "fn validate_token");
    assert_source_absent(@embedFile("../discord/gateway_client.zig"), "fn validate_run_options");
    assert_source_absent(@embedFile("../discord/gateway_client.zig"), "fn validate_gateway_text");
    assert_source_absent(@embedFile("../discord/gateway_client.zig"), "fn validate_event_name");
}

test "Embed models live in a dedicated module" {
    const models = @import("../models/mod.zig");
    const embed = @import("../models/embed.zig");

    comptime {
        if (!@hasDecl(embed, "Embed")) {
            @compileError("Embed model must live in models/embed.zig");
        }
        if (!@hasDecl(embed, "EmbedField")) {
            @compileError("EmbedField model must live in models/embed.zig");
        }
    }

    try std.testing.expect(models.Embed == embed.Embed);
    try std.testing.expect(models.EmbedField == embed.EmbedField);

    assert_source_absent(@embedFile("../models/types.zig"), "pub const Embed = struct");
    assert_source_absent(@embedFile("../models/types.zig"), "pub const EmbedField = struct");
}

test "Shared model groups live in dedicated modules" {
    const models = @import("../models/mod.zig");
    const snowflake = @import("../models/snowflake.zig");
    const emoji = @import("../models/emoji.zig");
    const component = @import("../models/component.zig");
    const message_reaction = @import("../models/message_reaction.zig");
    const application_command = @import("../models/application_command.zig");

    try std.testing.expect(models.Emoji == emoji.Emoji);
    try std.testing.expect(models.Button == component.Button);
    try std.testing.expect(models.ActionRow == component.ActionRow);
    try std.testing.expect(models.ButtonStyle == component.ButtonStyle);
    try std.testing.expect(models.MessageReaction == message_reaction.MessageReaction);
    try std.testing.expect(models.ApplicationCommand == application_command.ApplicationCommand);
    try std.testing.expect(models.Types.Snowflake == snowflake.Snowflake);

    assert_source_absent(@embedFile("../models/types.zig"), "pub const Emoji = struct");
    assert_source_absent(@embedFile("../models/types.zig"), "pub const Button = struct");
    assert_source_absent(@embedFile("../models/types.zig"), "pub const ActionRow = struct");
    assert_source_absent(
        @embedFile("../models/types.zig"),
        "pub const ApplicationCommand = struct",
    );
    assert_source_absent(
        @embedFile("../models/types.zig"),
        "pub const MessageReaction = struct",
    );
}

fn assert_no_erased_types(comptime source: []const u8) void {
    @setEvalBranchQuota(100_000);

    const erased_pointer = "any" ++ "opaque";
    const erased_payload = "any" ++ "type";

    if (comptime std.mem.indexOf(u8, source, erased_pointer) != null) {
        @compileError("source must use typed handlers");
    }
    if (comptime std.mem.indexOf(u8, source, erased_payload) != null) {
        @compileError("source must use explicit payload types");
    }
}

fn assert_source_absent(comptime source: []const u8, comptime needle: []const u8) void {
    @setEvalBranchQuota(100_000);
    if (comptime std.mem.indexOf(u8, source, needle) != null) {
        @compileError("source contains responsibility that should live in a dedicated module");
    }
}
