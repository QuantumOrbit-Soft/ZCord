const std = @import("std");
const zrqwest = @import("zrqwest");

bytes_max: u32,

pub const Error = error{
    ResponseBodyTooLarge,
};

pub const ResponseBodyGuard = @This();

pub fn init(target: *ResponseBodyGuard, bytes_max: u32) void {
    std.debug.assert(0 < bytes_max);

    target.* = .{
        .bytes_max = bytes_max,
    };
}

pub fn enforce(
    self: *const ResponseBodyGuard,
    response: zrqwest.Response,
) Error!zrqwest.Response {
    var owned_response = response;
    const bytes_max: usize = self.bytes_max;
    if (owned_response.body.len <= bytes_max) {
        return owned_response;
    }

    owned_response.deinit();
    return error.ResponseBodyTooLarge;
}

test "ResponseBodyGuard rejects response body above configured size" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "abc");

    var guard: ResponseBodyGuard = undefined;
    guard.init(2);

    try std.testing.expectError(
        error.ResponseBodyTooLarge,
        guard.enforce(.{
            .allocator = allocator,
            .status = .ok,
            .body = body,
        }),
    );
}

test "ResponseBodyGuard accepts response body up to configured size" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "abc");

    var guard: ResponseBodyGuard = undefined;
    guard.init(3);

    var response = try guard.enforce(.{
        .allocator = allocator,
        .status = .ok,
        .body = body,
    });
    defer response.deinit();

    try std.testing.expectEqualStrings("abc", response.body);
}
