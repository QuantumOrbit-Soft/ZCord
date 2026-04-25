# ZCord

A modern, high-performance Discord bot library for Zig.

## Overview

ZCord is a Zig library for building fast, efficient Discord bots. Designed with simplicity and
performance in mind, ZCord provides an ergonomic API for interacting with the Discord API while
leveraging Zig's safety features and low-level control.

## Features

- **REST-first API**: Resources for users, channels, messages, and slash commands
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

## Basic Usage

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

The sample registers `on_ready`, `on_event`, `on_message`, `on_reaction`, `on_slash_command`,
`on_component`, and `on_modal_submit` callbacks. The reaction callback receives both add and
remove events through `MessageReactionEvent.action`. Message content requires the Message Content
privileged intent to be enabled for your bot in the Discord Developer Portal.

Gateway callbacks are registered by event:

```zig
discord.on(SampleBot.on_message, .OnMessage);
discord.on(SampleBot.on_reaction, .OnReaction);
discord.on(SampleBot.on_slash_command, .OnSlashCommand);
discord.on(SampleBot.on_component, .OnComponent);
discord.on(SampleBot.on_modal_submit, .OnModalSubmit);

try discord.run_gateway(.{
    .intents = zcord.GatewayIntents.message_events,
});
```

With Gateway enabled, send `!zcord ping` or `!zcord rich` in the test channel. The rich message
contains a button that opens a modal, exercising component and modal callbacks.

Slash command handlers can reply or open modals through the context:

```zig
pub fn on_slash_command(ctx: zcord.DiscordContext) void {
    const event = ctx.slash_command() orelse return;
    if (std.mem.eql(u8, event.name, "ping")) {
        ctx.interaction_reply(.{ .content = "pong" }) catch return;
    }
}
```

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
