# ZCord

A modern, high-performance Discord bot library for Zig.

## Overview

ZCord is a Zig library for building fast, efficient Discord bots. Designed with simplicity and
performance in mind, ZCord provides an ergonomic API for interacting with the Discord API while
leveraging Zig's safety features and low-level control.

## Features

- **Gateway Bot API**: Register typed callbacks with `discord.on`
- **REST Resources**: Users, channels, messages, reactions, and slash commands
- **Type Safe**: Discord payloads are parsed into explicit Zig model types
- **Explicit Ownership**: Results own parsed JSON/error bodies and expose `deinit`
- **Bounded Routes**: Route builders write into caller-provided buffers
- **Borrowed Transport**: You own the `zrqwest.RequestClient` lifecycle
- **Typed Gateway Callbacks**: Ready, event, message, reaction, slash, component, and modal events

## Source Layout

```text
src/
  discord/    core SDK, config, HTTP client, and result ownership
  models/     Discord JSON DTOs such as User, Channel, and Message
  resources/  REST resource APIs grouped by Discord object
  routes/     bounded route builders and route-param validation
  internal/   helpers that are not part of the public API
  testing/    architecture and public-contract tests
```

## Quick Start: Minimal Bot

Most bots start with the Gateway, not with a REST request. The Gateway keeps a WebSocket open and
calls your functions when Discord sends events.

```zig
const std = @import("std");
const zcord = @import("ZCord");

const Bot = struct {
    pub fn on_ready(ctx: zcord.DiscordContext) void {
        const ready = ctx.ready() orelse return;
        std.debug.print("logged in as {s}\n", .{ready.user.username});
    }

    pub fn on_message(ctx: zcord.DiscordContext) void {
        const message = ctx.message() orelse return;

        if (std.mem.eql(u8, message.content, "!ping")) {
            ctx.reply("pong") catch return;
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var request_client: zcord.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var discord: zcord.DiscordClient = undefined;
    try discord.init(.{
        .allocator = allocator,
        .client = &request_client,
        .token = "your-bot-token",
    });
    defer discord.deinit();

    discord.on(Bot.on_ready, .OnReady);
    discord.on(Bot.on_message, .OnMessage);

    try discord.run_gateway(.{
        .intents = zcord.GatewayIntents.message_events,
    });
}
```

When this is running, send `!ping` in a channel where the bot can read messages. The bot replies
with `pong`.

Message content requires the Message Content privileged intent to be enabled for your bot in the
Discord Developer Portal.

## How `discord.on` Works

`discord.on(callback, event)` registers one function for one Gateway event. Every callback receives
a `zcord.DiscordContext`. The context lets you read the typed event payload and reply when the
event supports replies.

```zig
discord.on(Bot.on_ready, .OnReady);
discord.on(Bot.on_event, .OnEvent);
discord.on(Bot.on_message, .OnMessage);
discord.on(Bot.on_reaction, .OnReaction);
discord.on(Bot.on_channel, .OnChannel);
discord.on(Bot.on_voice, .OnVoice);
discord.on(Bot.on_slash_command, .OnSlashCommand);
discord.on(Bot.on_component, .OnComponent);
discord.on(Bot.on_modal_submit, .OnModalSubmit);
```

The callback signature is always:

```zig
pub fn callback_name(ctx: zcord.DiscordContext) void {
    // Read ctx and do work.
}
```

The SDK runs callbacks on its callback runtime, so a slow command should not block the Gateway read
loop. Still keep callback work bounded and handle errors explicitly.

### OnReady

Runs once after Discord accepts the Gateway session. Use it for logs or startup state.

```zig
pub fn on_ready(ctx: zcord.DiscordContext) void {
    const ready = ctx.ready() orelse return;
    std.debug.print("ready: {s} ({s})\n", .{ ready.user.username, ready.user.id });
}
```

### OnEvent

Runs for every raw Gateway dispatch event before the typed callback. Use it for logs, metrics, or
debugging event flow.

```zig
pub fn on_event(ctx: zcord.DiscordContext) void {
    const event = switch (ctx.payload) {
        .OnEvent => |value| value,
        else => return,
    };

    std.debug.print("event: {s}\n", .{event.name});
}
```

### OnMessage

Runs when a message is created. Use `ctx.message()` to read it, then `ctx.reply()` or
`ctx.send_rich()` to answer.

```zig
pub fn on_message(ctx: zcord.DiscordContext) void {
    const message = ctx.message() orelse return;

    if (std.mem.eql(u8, message.content, "!ping")) {
        ctx.reply("pong") catch |err| {
            std.debug.print("reply failed: {s}\n", .{@errorName(err)});
        };
    }
}
```

### OnReaction

Runs when a reaction is added or removed. Check `event.action` to know which happened.

```zig
pub fn on_reaction(ctx: zcord.DiscordContext) void {
    const reaction = ctx.reaction() orelse return;

    std.debug.print("reaction {s} on message {s}\n", .{
        @tagName(reaction.action),
        reaction.message_id,
    });
}
```

### OnChannel

Runs for channel create, update, delete, and pins update events.

```zig
pub fn on_channel(ctx: zcord.DiscordContext) void {
    const event = ctx.channel() orelse return;

    if (event.channel_id()) |channel_id| {
        std.debug.print("channel {s}: {s}\n", .{
            @tagName(event.action),
            channel_id,
        });
    }
}
```

### OnVoice

Runs for voice state and voice server events. Use this for join/leave/mute style bot logic.

```zig
pub fn on_voice(ctx: zcord.DiscordContext) void {
    const event = ctx.voice() orelse return;

    if (event.guild_id()) |guild_id| {
        std.debug.print("voice {s} in guild {s}\n", .{
            @tagName(event.action),
            guild_id,
        });
    }
}
```

### OnSlashCommand

Runs when a slash command interaction arrives. Slash commands must be registered before users can
call them; see `examples/main.zig` for a complete `/zcord` registration.

```zig
pub fn on_slash_command(ctx: zcord.DiscordContext) void {
    const command = ctx.slash_command() orelse return;

    if (std.mem.eql(u8, command.name, "ping")) {
        ctx.interaction_reply(.{
            .content = "pong from slash command",
        }) catch return;
    }
}
```

Slash command options are available through typed helpers:

```zig
const text = ctx.option_string("text") orelse "(empty)";
const count = ctx.option_integer("count") orelse 0;
const enabled = ctx.option_boolean("enabled") orelse false;
const user_id = ctx.option_user_id("user");
```

### OnComponent

Runs when a user clicks a button or uses another message component. Use `custom_id` to route the
button.

```zig
pub fn on_component(ctx: zcord.DiscordContext) void {
    const component = ctx.component() orelse return;

    if (std.mem.eql(u8, component.custom_id, "open_modal")) {
        show_feedback_modal(ctx);
        return;
    }

    ctx.interaction_reply(.{
        .content = "button clicked",
        .flags = 64, // Ephemeral message.
    }) catch return;
}
```

### OnModalSubmit

Runs when a modal is submitted. Read text inputs with `ctx.modal_field(custom_id)`.

```zig
pub fn on_modal_submit(ctx: zcord.DiscordContext) void {
    const modal = ctx.modal_submit() orelse return;
    if (!std.mem.eql(u8, modal.custom_id, "feedback_modal")) return;

    const feedback = ctx.modal_field("feedback") orelse "(empty)";
    var buffer: [256]u8 = undefined;
    const response = std.fmt.bufPrint(
        buffer[0..],
        "feedback received: {s}",
        .{feedback},
    ) catch "feedback received";

    ctx.interaction_reply(.{
        .content = response,
        .flags = 64,
    }) catch return;
}
```

Modal creation can happen from a component or slash command interaction:

```zig
fn show_feedback_modal(ctx: zcord.DiscordContext) void {
    const Modals = zcord.SlashCommandsResource.Modals;

    const input = Modals.with_required(
        Modals.text_input("feedback", "Feedback", .paragraph),
        true,
    );
    const inputs = [_]zcord.SlashCommandsResource.TextInput{input};
    const rows = [_]zcord.SlashCommandsResource.TextInputRow{
        Modals.row(inputs[0..]),
    };

    ctx.show_modal(.{
        .custom_id = "feedback_modal",
        .title = "Send feedback",
        .components = rows[0..],
    }) catch return;
}
```

## Gateway Intents

Pass the intents your bot needs to `run_gateway`.

```zig
try discord.run_gateway(.{
    .intents = zcord.GatewayIntents.message_events |
        zcord.GatewayIntents.voice_events |
        zcord.GatewayIntents.channel_events,
});
```

Common choices:

- `zcord.GatewayIntents.message_events`: messages and reactions
- `zcord.GatewayIntents.channel_events`: channel lifecycle events
- `zcord.GatewayIntents.voice_events`: voice state/server events

## Optional: REST Request

REST resources are still useful for setup tasks, message creation, command registration, and
fetching Discord objects. This example only checks the current bot user:

```zig
const std = @import("std");
const zcord = @import("ZCord");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var request_client: zcord.RequestClient = undefined;
    try request_client.init(allocator);
    defer request_client.deinit();

    var discord: zcord.DiscordClient = undefined;
    try discord.init(.{
        .allocator = allocator,
        .client = &request_client,
        .token = "your-bot-token",
    });
    defer discord.deinit();

    var result = try discord.users.get_current_user();
    defer result.deinit();

    if (result.data()) |user| {
        std.debug.print("logged in as {s}\n", .{user.username});
    }
}
```

## Local Sample

Create a `.env` at the repository root with at least:

```text
TOKEN=your-discord-bot-token
```

Add these values to exercise the channel and application command samples:

```text
CHANNEL_ID=your-test-channel-id
GUILD_ID=your-test-guild-id
APPLICATION_ID=your-discord-application-id
```

Then run:

```bash
zig build sample
```

The sample runs the test flow directly from those values. With `CHANNEL_ID`, it sends a temporary
message with an embed, fetches it, edits it, adds/removes a reaction, replies to it, then deletes
the temporary messages.

It also creates a persistent `ZCord interactive sample` panel with a button for modal testing. Use
that panel only while the sample Gateway is running.

With `GUILD_ID`, it creates or updates the stable `/zcord` guild command for interactive testing.
The command demonstrates typed options: string choices, integer range, number range, boolean,
user, channel, role, mentionable, and attachment. It also exposes message options such as
`ephemeral`, `embed`, `buttons`, `image_url`, `thumbnail_url`, and `link_url`.

After the REST checks, the sample opens the Gateway. Stop it with `Ctrl+C`.
Plain `!zcord` and `!zcord rich` both send a rich message with buttons; the modal opens from the
button because Discord modals must be sent as interaction responses.

The sample registers all currently supported callback groups: ready, raw event, message, reaction,
channel, voice, slash command, component, and modal submit. With Gateway enabled, send
`!zcord ping` or `!zcord rich` in the test channel. The rich message contains buttons and a modal,
exercising component and modal callbacks.

## Installation

### Prerequisites

- Zig 0.16.0 or later
- A Discord Bot Token (create one at
  [Discord Developer Portal](https://discord.com/developers/applications))

### Adding ZCord to Your Project

1. Add ZCord to your `build.zig.zon` dependencies:

```zig
.dependencies = .{
    .ZCord = .{
        .url = "https://github.com/QuantumOrbit-Soft/ZCord/archive/main.tar.gz",
        .hash = "<computed-hash>",
    },
},
```

To get the hash, run:
```bash
zig fetch https://github.com/QuantumOrbit-Soft/ZCord/archive/main.tar.gz
```

This will output the hash that you should replace `<computed-hash>` with.

2. Then in your `build.zig`, add:

```zig
const ZCord = b.dependency("ZCord", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ZCord", ZCord.module("ZCord"));
```

3. Now you can import ZCord in your code:

```zig
const ZCord = @import("ZCord");
```

### Building Your Project

After adding the dependency, build your project with:

```bash
zig build -Doptimize=ReleaseSafe
```

For development builds with debug symbols:

```bash
zig build
```

### Requirements

- Zig compiler version 0.16.0 or later
- Internet connection for initial dependency fetch
- Discord Bot Token (get yours at https://discord.com/developers/applications)

### Updating ZCord

To update to the latest version of ZCord:

1. Remove the old hash from `build.zig.zon`
2. Run the fetch command again to get the new hash:

```bash
zig fetch --save=ZCord https://github.com/QuantumOrbit-Soft/ZCord/archive/main.tar.gz
```

3. This will automatically update both the URL and hash in your `build.zig.zon`

### Troubleshooting

**Hash mismatch errors**: If you get a hash mismatch, delete the hash field from `build.zig.zon`
and run `zig fetch` again to compute a new hash.

**Module not found**: Ensure you've added the dependency in both `build.zig.zon` and `build.zig`.
