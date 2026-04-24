//! Message API endpoints.

const Api = @import("../mod.zig");
const Models = @import("models");

pub const Messages = struct {
    pub fn getMessage(api: *Api.ApiClient, channel_id: u64, message_id: u64) !Models.Message {
        _ = api;
        _ = channel_id;
        _ = message_id;
        return error.NotImplemented;
    }

    pub fn sendMessage(api: *Api.ApiClient, channel_id: u64, content: []const u8) !Models.Message {
        _ = api;
        _ = channel_id;
        _ = content;
        return error.NotImplemented;
    }
};
