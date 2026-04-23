# ZCord

A modern, high-performance Discord bot library for Zig.

## Overview

ZCord is a Zig library for building fast, efficient Discord bots. Designed with simplicity and performance in mind, ZCord provides an ergonomic API for interacting with the Discord API while leveraging Zig's safety features and low-level control.

## Features

- **High Performance**: Built with Zig's zero-cost abstractions and efficient memory management
- **Simple API**: Intuitive and ergonomic design focused on developer experience
- **Type Safe**: Leverage Zig's compile-time guarantees to catch errors early
- **Event-Driven**: Clean event system for handling Discord events
- **Gateway & REST**: Full support for Discord Gateway and REST API
- **Zero Dependencies**: Minimal footprint with no external runtime dependencies

## Installation

### Prerequisites

- Zig 0.16.0 or later
- A Discord Bot Token (create one at [Discord Developer Portal](https://discord.com/developers/applications))

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

**Hash mismatch errors**: If you get a hash mismatch, delete the hash field from `build.zig.zon` and run `zig fetch` again to compute a new hash.

**Module not found**: Ensure you've added the dependency in both `build.zig.zon` and `build.zig`.
