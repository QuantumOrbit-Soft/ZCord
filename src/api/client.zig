//! REST API client.
//! Handles HTTP requests to Discord REST API.

const std = @import("std");
const http = std.http;
const Errors = @import("errors");

pub const ApiClient = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    client: http.Client,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, token: []const u8) !ApiClient {
        return ApiClient{
            .allocator = allocator,
            .token = token,
            .client = http.Client{ .allocator = allocator },
            .base_url = "https://discord.com/api/v10",
        };
    }

    pub fn deinit(self: *ApiClient) void {
        self.client.deinit();
    }

    pub fn request(self: *ApiClient, method: http.Method, endpoint: []const u8, body: ?[]const u8) ![]u8 {
        _ = self;
        _ = method;
        _ = endpoint;
        _ = body;
        return Errors.Error.Unknown{ .message = "ApiClient.request not implemented" };
    }
};
