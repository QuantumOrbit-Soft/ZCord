//! Constants and configuration values.
//! API endpoints, limits, and magic numbers.

pub const Limits = @import("limits.zig");
pub const ApiVersion = @import("version.zig").ApiVersion;

// Discord API base URLs
pub const DISCORD_API_BASE = "https://discord.com/api";
pub const GATEWAY_VERSION = "10";
pub const API_VERSION = "10";
