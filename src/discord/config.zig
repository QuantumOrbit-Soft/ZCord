const std = @import("std");

pub const default_base_url = "https://discord.com/api/v10";

base_url: []const u8 = default_base_url,
token: []const u8,
token_prefix: []const u8 = "Bot",
user_agent: []const u8 = "ZCord/0.1",
response_body_bytes_max: u32 = 1024 * 1024,

pub const validate_error = error{
    MissingBaseUrl,
    MissingToken,
    InvalidBaseUrl,
    InvalidResponseBodyBytesMax,
};

pub const DiscordConfig = @This();
const Self = @This();

pub fn validate(self: Self) validate_error!void {
    const normalized_cfg = self.normalized();

    const base_url_trimmed = normalized_cfg.base_url;
    if (0 < base_url_trimmed.len) {} else return error.MissingBaseUrl;

    const token_trimmed = normalized_cfg.token;
    if (0 < token_trimmed.len) {} else return error.MissingToken;

    const has_http_scheme = std.mem.startsWith(u8, base_url_trimmed, "http://");
    const has_https_scheme = std.mem.startsWith(u8, base_url_trimmed, "https://");
    if (has_http_scheme or has_https_scheme) {} else return error.InvalidBaseUrl;

    const scheme_len: usize = if (has_https_scheme) "https://".len else "http://".len;
    if (scheme_len < base_url_trimmed.len) {} else return error.InvalidBaseUrl;

    const host_start = base_url_trimmed[scheme_len..];
    switch (host_start[0]) {
        '/' => return error.InvalidBaseUrl,
        else => {},
    }

    if (0 < normalized_cfg.response_body_bytes_max) {} else {
        return error.InvalidResponseBodyBytesMax;
    }
}

pub fn normalized(self: Self) Self {
    var config_normalized = self;
    config_normalized.base_url = std.mem.trim(u8, self.base_url, &std.ascii.whitespace);
    config_normalized.token = std.mem.trim(u8, self.token, &std.ascii.whitespace);
    config_normalized.token_prefix = std.mem.trim(u8, self.token_prefix, &std.ascii.whitespace);
    config_normalized.user_agent = std.mem.trim(u8, self.user_agent, &std.ascii.whitespace);
    return config_normalized;
}
