const Env = @import("internal").Env;

env: *const Env,

const SampleConfig = @This();

const token_key = "TOKEN";
const discord_token_key = "DISCORD_TOKEN";
const channel_id_key = "CHANNEL_ID";
const application_id_key = "APPLICATION_ID";
const guild_id_key = "GUILD_ID";

pub fn init(self: *SampleConfig, env: *const Env) void {
    self.* = .{ .env = env };
}

pub fn token(self: SampleConfig) error{MissingEnvironmentVariable}![]const u8 {
    return self.env.get(token_key) orelse self.env.get_required(discord_token_key);
}

pub fn channel_id(self: SampleConfig) ?[]const u8 {
    return self.env.get(channel_id_key);
}

pub fn application_id(self: SampleConfig) ?[]const u8 {
    return self.env.get(application_id_key);
}

pub fn guild_id(self: SampleConfig) ?[]const u8 {
    return self.env.get(guild_id_key);
}
