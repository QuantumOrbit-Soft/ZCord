//! Gateway client for WebSocket connection.

const std = @import("std");
const websocket = @import("websocket.zig");

pub const GatewayClient = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    session_id: ?[]const u8 = null,
    websocket: *websocket.WebSocket,

    pub fn init(allocator: std.mem.Allocator, token: []const u8) !GatewayClient {
        return GatewayClient{
            .allocator = allocator,
            .token = token,
            .websocket = try websocket.WebSocket.init(allocator),
        };
    }

    pub fn deinit(self: *GatewayClient) void {
        if (self.session_id) |id| {
            self.allocator.free(id);
        }
        self.websocket.deinit();
    }

    pub fn connect(self: *GatewayClient) !void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn disconnect(self: *GatewayClient) void {
        _ = self;
    }

    pub fn send(self: *GatewayClient, payload: []const u8) !void {
        _ = self;
        _ = payload;
        return error.NotImplemented;
    }
};
