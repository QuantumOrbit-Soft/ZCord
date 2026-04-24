const std = @import("std");

pub const WebSocket = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*WebSocket {
        const websocket = try allocator.create(WebSocket);
        websocket.* = .{ .allocator = allocator };
        return websocket;
    }

    pub fn deinit(self: *WebSocket) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
