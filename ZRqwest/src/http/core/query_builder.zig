const std = @import("std");
const kv_codec = @import("kv_codec.zig");

pub const Error = error{OutOfMemory};

pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    writer: std.Io.Writer.Allocating,
    next_prefix: NextPrefix,
    fragment: []const u8,

    const NextPrefix = enum {
        none,
        question,
        ampersand,
    };

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) Error!QueryBuilder {
        var writer = std.Io.Writer.Allocating.initCapacity(allocator, base_url.len + 64) catch {
            return error.OutOfMemory;
        };
        errdefer writer.deinit();

        var base = base_url;
        var fragment: []const u8 = &.{};
        if (std.mem.indexOfScalar(u8, base_url, '#')) |fragment_start| {
            base = base_url[0..fragment_start];
            fragment = base_url[fragment_start..];
        }

        writer.writer.writeAll(base) catch return error.OutOfMemory;

        return .{
            .allocator = allocator,
            .writer = writer,
            .next_prefix = detect_next_prefix(base),
            .fragment = fragment,
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        self.writer.deinit();
        self.* = undefined;
    }

    pub fn add(self: *QueryBuilder, key: []const u8, value: anytype) Error!void {
        switch (@typeInfo(@TypeOf(value))) {
            .optional => {
                if (value) |inner| {
                    try self.add(key, inner);
                }
                return;
            },
            else => {},
        }

        self.begin_pair() catch return error.OutOfMemory;
        kv_codec.write_escaped(&self.writer.writer, key, .percent_20) catch return error.OutOfMemory;
        self.writer.writer.writeByte('=') catch return error.OutOfMemory;
        kv_codec.write_value(&self.writer.writer, value, .percent_20) catch return error.OutOfMemory;
    }

    pub fn add_struct(self: *QueryBuilder, query: anytype) Error!void {
        comptime kv_codec.assert_struct_payload(@TypeOf(query), "QueryBuilder.add_struct");

        const query_type = @TypeOf(query);
        const struct_info = @typeInfo(query_type).@"struct";
        inline for (struct_info.fields) |field| {
            const value = @field(query, field.name);
            switch (@typeInfo(field.type)) {
                .optional => {
                    if (value) |inner| {
                        try self.add(field.name, inner);
                    }
                },
                else => {
                    try self.add(field.name, value);
                },
            }
        }
    }

    pub fn finish(self: *QueryBuilder) Error![]u8 {
        if (self.fragment.len != 0) {
            self.writer.writer.writeAll(self.fragment) catch return error.OutOfMemory;
            self.fragment = &.{};
        }
        return self.writer.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn begin_pair(self: *QueryBuilder) std.Io.Writer.Error!void {
        switch (self.next_prefix) {
            .none => {},
            .question => try self.writer.writer.writeByte('?'),
            .ampersand => try self.writer.writer.writeByte('&'),
        }
        self.next_prefix = .ampersand;
    }

    fn detect_next_prefix(base: []const u8) NextPrefix {
        if (base.len == 0) return .question;

        const last = base[base.len - 1];
        if (last == '?' or last == '&') return .none;
        if (std.mem.indexOfScalar(u8, base, '?') != null) return .ampersand;
        return .question;
    }
};

pub fn build(allocator: std.mem.Allocator, base_url: []const u8, query: anytype) Error![]u8 {
    var builder = try QueryBuilder.init(allocator, base_url);
    defer builder.deinit();

    try builder.add_struct(query);
    return builder.finish();
}

test "build query with anonymous struct" {
    const allocator = std.testing.allocator;
    const url = try build(allocator, "https://test.com/api", .{
        .name = 1,
        .enabled = true,
    });
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://test.com/api?name=1&enabled=true", url);
}

test "build query with existing query and fragment" {
    const allocator = std.testing.allocator;
    const url = try build(allocator, "https://test.com/api?lang=pt#section", .{
        .name = "john doe",
        .page = 2,
    });
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://test.com/api?lang=pt&name=john%20doe&page=2#section",
        url,
    );
}

test "query builder incremental add" {
    const allocator = std.testing.allocator;
    var qb = try QueryBuilder.init(allocator, "https://test.com/api?");
    defer qb.deinit();

    try qb.add("name", "john");
    try qb.add("active", true);
    try qb.add("note", @as(?[]const u8, null));
    const url = try qb.finish();
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://test.com/api?name=john&active=true", url);
}
