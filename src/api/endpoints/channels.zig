//! Channel API endpoints.

const Api = @import("../mod.zig");
const Models = @import("models");

pub const Channels = struct {
    pub fn getChannel(api: *Api.ApiClient, channel_id: u64) !Models.Channel {
        _ = api;
        _ = channel_id;
        return error.NotImplemented;
    }

    pub fn getChannelMessages(api: *Api.ApiClient, channel_id: u64) ![]Models.Message {
        _ = api;
        _ = channel_id;
        return error.NotImplemented;
    }
};
