const std = @import("std");

pub const CookieJar = struct {
    cookies: std.StringHashMap([]u8),
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    version: u64 = 1,

    pub const HeaderBuild = struct {
        changed: bool,
        version: u64,
        header_value: ?[]u8,
    };

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .cookies = std.StringHashMap([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CookieJar) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cookies.deinit();
    }

    pub fn set(self: *CookieJar, name: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        if (self.cookies.fetchRemove(owned_name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.cookies.put(owned_name, owned_value);
        self.version +%= 1;
    }

    pub fn get(self: *CookieJar, name: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        return self.cookies.get(name);
    }

    pub fn clear(self: *CookieJar) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.cookies.count() == 0) return;

        var it = self.cookies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cookies.clearRetainingCapacity();
        self.version +%= 1;
    }

    pub fn build_header(self: *CookieJar, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.cookies.count() == 0) return null;

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        const w = &out.writer;

        var it = self.cookies.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeAll("; ");
            try w.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        return try out.toOwnedSlice();
    }

    pub fn build_header_if_version_changed(
        self: *CookieJar,
        allocator: std.mem.Allocator,
        known_version: u64,
    ) !HeaderBuild {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (known_version == self.version) {
            return .{
                .changed = false,
                .version = self.version,
                .header_value = null,
            };
        }

        if (self.cookies.count() == 0) {
            return .{
                .changed = true,
                .version = self.version,
                .header_value = null,
            };
        }

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        const writer = &out.writer;

        var it = self.cookies.iterator();
        var is_first_cookie = true;
        while (it.next()) |entry| {
            if (!is_first_cookie) try writer.writeAll("; ");

            try writer.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            is_first_cookie = false;
        }

        return .{
            .changed = true,
            .version = self.version,
            .header_value = try out.toOwnedSlice(),
        };
    }

    pub fn update_from_set_cookie(self: *CookieJar, set_cookie: []const u8) !void {
        const first = std.mem.sliceTo(set_cookie, ';');
        const trimmed = std.mem.trim(u8, first, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
        const name = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (name.len == 0) return;
        try self.set(name, value);
    }
};

test "CookieJar: set and get" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    try jar.set("session", "abc123");
    try std.testing.expectEqualStrings("abc123", jar.get("session").?);
    try std.testing.expect(jar.get("other") == null);
}

test "CookieJar: build_header empty returns null" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    const h = try jar.build_header(allocator);
    try std.testing.expect(h == null);
}

test "CookieJar: build_header single cookie" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    try jar.set("tok", "xyz");
    const h = (try jar.build_header(allocator)).?;
    defer allocator.free(h);
    try std.testing.expectEqualStrings("tok=xyz", h);
}

test "CookieJar: update_from_set_cookie simple" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    try jar.update_from_set_cookie("user=bob; Path=/; HttpOnly");
    try std.testing.expectEqualStrings("bob", jar.get("user").?);
}

test "CookieJar: update_from_set_cookie no attributes" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    try jar.update_from_set_cookie("token=secret");
    try std.testing.expectEqualStrings("secret", jar.get("token").?);
}

test "CookieJar: clear removes all" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    try jar.set("a", "1");
    try jar.set("b", "2");
    jar.clear();
    try std.testing.expect(jar.get("a") == null);
    try std.testing.expect(jar.get("b") == null);
}

test "CookieJar: build_header_if_version_changed tracks mutations" {
    const allocator = std.testing.allocator;
    var jar = CookieJar.init(allocator);
    defer jar.deinit();

    const unchanged_empty = try jar.build_header_if_version_changed(allocator, 1);
    try std.testing.expect(!unchanged_empty.changed);
    try std.testing.expectEqual(@as(u64, 1), unchanged_empty.version);
    try std.testing.expect(unchanged_empty.header_value == null);

    try jar.set("token", "abc");
    const changed = try jar.build_header_if_version_changed(allocator, 1);
    defer if (changed.header_value) |value| allocator.free(value);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.version != 1);
    try std.testing.expectEqualStrings("token=abc", changed.header_value.?);

    const unchanged = try jar.build_header_if_version_changed(allocator, changed.version);
    try std.testing.expect(!unchanged.changed);
    try std.testing.expectEqual(changed.version, unchanged.version);
    try std.testing.expect(unchanged.header_value == null);
}
