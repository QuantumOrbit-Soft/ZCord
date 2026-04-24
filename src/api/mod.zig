//! REST API module for Discord endpoints.
//! Provides type-safe wrappers for Discord REST API operations.

pub const ApiClient = @import("client.zig").ApiClient;
pub const Routes = @import("routes.zig");

// Re-export endpoint modules
pub const endpoints = @import("endpoints/mod.zig");
pub const Users = endpoints.users;
pub const Guilds = endpoints.guilds;
pub const Channels = endpoints.channels;
pub const Messages = endpoints.messages;
