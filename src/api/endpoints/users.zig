//! User API endpoints.

const Api = @import("../mod.zig");
const Models = @import("models");

pub const Users = struct {
    pub fn getUser(api: *Api.ApiClient, user_id: u64) !Models.User {
        _ = api;
        _ = user_id;
        return error.NotImplemented;
    }

    pub fn getCurrentUser(api: *Api.ApiClient) !Models.User {
        _ = api;
        return error.NotImplemented;
    }

    pub fn getCurrentUserGuilds(api: *Api.ApiClient) ![]Models.Guild {
        _ = api;
        return error.NotImplemented;
    }
};
