const std = @import("std");

buffer: []u8,
cursor: usize,

pub const Error = error{
    OutputBufferTooSmall,
};

pub const PercentEncoder = @This();

pub fn init(target: *PercentEncoder, buffer: []u8) void {
    target.* = .{
        .buffer = buffer,
        .cursor = 0,
    };
}

pub fn encode(self: *PercentEncoder, value: []const u8) Error![]const u8 {
    self.cursor = 0;

    for (value) |byte| {
        if (is_unreserved(byte)) {
            try self.append_byte(byte);
        } else {
            try self.append_byte('%');
            try self.append_byte(hex_upper((byte >> 4) & 0x0F));
            try self.append_byte(hex_upper(byte & 0x0F));
        }
    }

    return self.finish();
}

fn append_byte(self: *PercentEncoder, byte: u8) Error!void {
    std.debug.assert(self.cursor <= self.buffer.len);

    if (self.cursor < self.buffer.len) {} else return error.OutputBufferTooSmall;

    self.buffer[self.cursor] = byte;
    self.cursor += 1;
}

fn finish(self: *const PercentEncoder) []const u8 {
    std.debug.assert(self.cursor <= self.buffer.len);
    return self.buffer[0..self.cursor];
}

fn is_unreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z',
        'a'...'z',
        '0'...'9',
        '-',
        '_',
        '.',
        '~',
        => true,
        else => false,
    };
}

fn hex_upper(nibble: u8) u8 {
    std.debug.assert(nibble < 16);

    if (nibble < 10) return '0' + nibble;
    return 'A' + (nibble - 10);
}

test "PercentEncoder keeps unreserved route bytes unchanged" {
    var buffer: [64]u8 = undefined;
    var encoder: PercentEncoder = undefined;
    encoder.init(buffer[0..]);

    const encoded = try encoder.encode("abcXYZ-_.~012");

    try std.testing.expectEqualStrings("abcXYZ-_.~012", encoded);
}

test "PercentEncoder encodes emoji and custom emoji separators" {
    var buffer: [64]u8 = undefined;
    var encoder: PercentEncoder = undefined;
    encoder.init(buffer[0..]);

    const encoded = try encoder.encode("zig:👍");

    try std.testing.expectEqualStrings("zig%3A%F0%9F%91%8D", encoded);
}

test "PercentEncoder rejects output that exceeds caller buffer" {
    var buffer: [2]u8 = undefined;
    var encoder: PercentEncoder = undefined;
    encoder.init(buffer[0..]);

    try std.testing.expectError(error.OutputBufferTooSmall, encoder.encode("👍"));
}
