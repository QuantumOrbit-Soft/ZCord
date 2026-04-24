//! Guild API endpoints.

const Api = @import("../mod.zig");
const Models = @import("models");

pub const Guilds = struct {
    pub fn getGuild(api: *Api.ApiClient, guild_id: u64) !Models.Guild {
        _ = api;
        _ = guild_id;
        return error.NotImplemented;
    }

    pub fn getGuildChannels(api: *Api.ApiClient, guild_id: u64) ![]Models.Channel {
        _ = api;
        _ = guild_id;
        return error.NotImplemented;
    }
};
