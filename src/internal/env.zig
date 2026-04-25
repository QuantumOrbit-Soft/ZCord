const std = @import("std");

pub const file_bytes_max: u32 = 64 * 1024;

allocator: std.mem.Allocator,
map: std.process.Environ.Map,

pub const load_text_error = std.mem.Allocator.Error || parse_error;
pub const load_file_error = std.Io.Dir.ReadFileAllocError || load_text_error;
pub const get_required_error = error{MissingEnvironmentVariable};
pub const parse_error = error{ InvalidEnvironmentLine, MissingEnvironmentKey };

pub const Env = @This();
const Self = @This();

pub fn init(self: *Self, allocator: std.mem.Allocator) void {
    self.* = .{
        .allocator = allocator,
        .map = std.process.Environ.Map.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.map.deinit();
    self.* = undefined;
}

pub fn load_file(self: *Self, path: []const u8) load_file_error!void {
    std.debug.assert(path.len > 0);

    try self.load_dir_file(std.Io.Dir.cwd(), std.Options.debug_io, path);
}

test "Env.load_file parses simple dotenv file" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = ".env",
        .data =
        \\DISCORD_TOKEN=abc123
        \\API_BASE=https://discord.com/api/v10
        \\DEBUG=true
        ,
    });

    var env: Env = undefined;
    env.init(std.testing.allocator);
    defer env.deinit();

    try env.load_dir_file(temp_dir.dir, std.testing.io, ".env");

    try std.testing.expectEqualStrings(
        "abc123",
        env.get_required("DISCORD_TOKEN") catch unreachable,
    );
    try std.testing.expectEqualStrings(
        "https://discord.com/api/v10",
        env.get_required("API_BASE") catch unreachable,
    );
    try std.testing.expectEqualStrings("true", env.get("DEBUG") orelse unreachable);
}

test "Env.load_file ignores comments and trims whitespace" {
    var env: Env = undefined;
    env.init(std.testing.allocator);
    defer env.deinit();

    try env.load_text(
        \\# comment
        \\ DISCORD_TOKEN = abc123 
        \\EMPTY_VALUE=
        \\QUOTED = "hello"
        \\SINGLE = 'world'
    );

    try std.testing.expectEqualStrings(
        "abc123",
        env.get_required("DISCORD_TOKEN") catch unreachable,
    );
    try std.testing.expectEqualStrings("", env.get("EMPTY_VALUE") orelse unreachable);
    try std.testing.expectEqualStrings("hello", env.get("QUOTED") orelse unreachable);
    try std.testing.expectEqualStrings("world", env.get("SINGLE") orelse unreachable);
}

test "Env.load_text rejects invalid dotenv line" {
    var env: Env = undefined;
    env.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(
        error.InvalidEnvironmentLine,
        env.load_text("DISCORD_TOKEN\n"),
    );
}

test "Env.get_required returns missing error" {
    var env: Env = undefined;
    env.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(
        error.MissingEnvironmentVariable,
        env.get_required("DISCORD_TOKEN"),
    );
    try std.testing.expect(!env.has("DISCORD_TOKEN"));
}

pub fn load_text(self: *Self, text: []const u8) load_text_error!void {
    std.debug.assert(text.len <= file_bytes_max);

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line_with_optional_cr| {
        const line = trim_space_and_cr(line_with_optional_cr);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        try self.parse_line(line);
    }
}

pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
    return self.map.get(name);
}

pub fn has(self: *const Self, name: []const u8) bool {
    return self.map.contains(name);
}

pub fn get_required(self: *const Self, name: []const u8) get_required_error![]const u8 {
    return self.get(name) orelse error.MissingEnvironmentVariable;
}

fn load_dir_file(self: *Self, dir: std.Io.Dir, io: std.Io, path: []const u8) load_file_error!void {
    const file_bytes = try dir.readFileAlloc(io, path, self.allocator, .limited(file_bytes_max));
    defer self.allocator.free(file_bytes);

    try self.load_text(file_bytes);
}

fn parse_line(self: *Self, line: []const u8) load_text_error!void {
    const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse {
        return error.InvalidEnvironmentLine;
    };

    const key = std.mem.trim(u8, line[0..separator_index], &std.ascii.whitespace);
    if (key.len == 0) {
        return error.MissingEnvironmentKey;
    }

    const raw_value = std.mem.trim(u8, line[separator_index + 1 ..], &std.ascii.whitespace);
    const value = strip_matching_quotes(raw_value);
    try self.map.put(key, value);
}

fn strip_matching_quotes(value: []const u8) []const u8 {
    if (value.len < 2) return value;

    const first = value[0];
    const last = value[value.len - 1];
    if (first == '"' and last == '"') return value[1 .. value.len - 1];
    if (first == '\'' and last == '\'') return value[1 .. value.len - 1];
    return value;
}

fn trim_space_and_cr(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, &[_]u8{ ' ', '\t', '\r' });
}
