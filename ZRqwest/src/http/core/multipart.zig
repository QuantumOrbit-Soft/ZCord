const std = @import("std");

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: []const u8 = "application/octet-stream",
    data: []const u8,
};

pub fn generate_boundary(buf: *[32]u8) []const u8 {
    var rand_bytes: [16]u8 = undefined;
    std.Options.debug_io.random(&rand_bytes);
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xf];
    }
    return buf[0..32];
}

pub fn build(
    allocator: std.mem.Allocator,
    parts: []const Part,
    boundary: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;

    for (parts) |part| {
        try w.print("--{s}\r\n", .{boundary});
        if (part.filename) |fname| {
            try w.print(
                "Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n",
                .{ part.name, fname },
            );
        } else {
            try w.print(
                "Content-Disposition: form-data; name=\"{s}\"\r\n",
                .{part.name},
            );
        }
        try w.print("Content-Type: {s}\r\n\r\n", .{part.content_type});
        try w.writeAll(part.data);
        try w.writeAll("\r\n");
    }

    try w.print("--{s}--\r\n", .{boundary});
    return out.toOwnedSlice();
}

test "build: single text part" {
    const allocator = std.testing.allocator;
    const boundary = "testboundary1234";
    const body = try build(allocator, &.{
        .{ .name = "message", .content_type = "text/plain", .data = "hello world" },
    }, boundary);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "--testboundary1234\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--testboundary1234--\r\n") != null);
}

test "build: multiple parts with filename" {
    const allocator = std.testing.allocator;
    const boundary = "boundary999";
    const body = try build(allocator, &.{
        .{ .name = "field1", .content_type = "text/plain", .data = "value1" },
        .{
            .name = "file",
            .filename = "photo.png",
            .content_type = "image/png",
            .data = "\x89PNG",
        },
    }, boundary);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"field1\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, body, "name=\"file\"; filename=\"photo.png\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\x89PNG") != null);
    try std.testing.expect(std.mem.count(u8, body, "--boundary999") == 3);
}

test "generate_boundary: produces 32-byte hex string" {
    var buf: [32]u8 = undefined;
    const b = generate_boundary(&buf);
    try std.testing.expectEqual(@as(usize, 32), b.len);
    for (b) |c| {
        try std.testing.expect(
            (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'),
        );
    }
}
