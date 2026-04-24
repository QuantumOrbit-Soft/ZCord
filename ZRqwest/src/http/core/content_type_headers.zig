const std = @import("std");

pub const json = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
};

pub const form = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
};
