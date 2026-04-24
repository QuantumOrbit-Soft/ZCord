//! JSON utility functions.
//! Helper functions for JSON serialization/deserialization.

const std = @import("std");

pub fn parse(comptime T: type, json_text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, std.testing.allocator, json_text, .{
        .ignore_unknown_fields = true,
    });
}

pub fn stringify(value: anytype, allocator: std.mem.Allocator) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}

pub fn get_field(comptime T: type, json_value: std.json.Value, field_name: []const u8) !T {
    _ = json_value;
    _ = field_name;
    return error.NotImplemented;
}
