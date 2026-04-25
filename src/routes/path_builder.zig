const std = @import("std");

buffer: []u8,
cursor: usize,

pub const Error = error{
    PathBufferTooSmall,
};

pub const PathBuilder = @This();

pub fn init(target: *PathBuilder, buffer: []u8) void {
    target.* = .{
        .buffer = buffer,
        .cursor = 0,
    };
}

pub fn append(self: *PathBuilder, part: []const u8) Error!void {
    std.debug.assert(self.cursor <= self.buffer.len);

    const remaining_len = self.buffer.len - self.cursor;
    if (part.len <= remaining_len) {} else return error.PathBufferTooSmall;

    const next_cursor = self.cursor + part.len;
    std.mem.copyForwards(u8, self.buffer[self.cursor..next_cursor], part);
    self.cursor = next_cursor;
}

pub fn append_many(self: *PathBuilder, parts: []const []const u8) Error!void {
    for (parts) |part| {
        try self.append(part);
    }
}

pub fn finish(self: *const PathBuilder) []const u8 {
    std.debug.assert(self.cursor <= self.buffer.len);
    return self.buffer[0..self.cursor];
}

pub fn build(buffer: []u8, parts: []const []const u8) Error![]const u8 {
    var builder: PathBuilder = undefined;
    builder.init(buffer);
    try builder.append_many(parts);
    return builder.finish();
}

test "PathBuilder initializes in place and appends parts" {
    var path_buffer: [64]u8 = undefined;
    var builder: PathBuilder = undefined;

    builder.init(path_buffer[0..]);
    try builder.append("/channels/");
    try builder.append("123");

    try std.testing.expectEqualStrings("/channels/123", builder.finish());
}

test "PathBuilder builds paths without allocation" {
    var path_buffer: [64]u8 = undefined;
    const path = try PathBuilder.build(path_buffer[0..], &.{ "/a/", "1", "/b" });

    try std.testing.expectEqualStrings("/a/1/b", path);
}

test "PathBuilder rejects insufficient buffers" {
    var path_buffer: [4]u8 = undefined;

    try std.testing.expectError(
        error.PathBufferTooSmall,
        PathBuilder.build(path_buffer[0..], &.{ "/too", "/long" }),
    );
}
