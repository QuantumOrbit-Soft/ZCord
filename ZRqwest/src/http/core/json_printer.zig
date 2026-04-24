const std = @import("std");
const builtin = @import("builtin");

pub const Style = enum {
    compact,
    pretty,
};

pub const Options = struct {
    style: Style = .pretty,
    append_newline: bool = true,
};

pub fn to_owned_slice(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    options: Options,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const formatted = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = switch (options.style) {
            .compact => .minified,
            .pretty => .indent_2,
        },
    });

    if (!options.append_newline) return formatted;

    const result = try allocator.alloc(u8, formatted.len + 1);
    @memcpy(result[0..formatted.len], formatted);
    result[formatted.len] = '\n';
    allocator.free(formatted);
    return result;
}

pub fn write_to_alloc(
    writer: anytype,
    allocator: std.mem.Allocator,
    json_text: []const u8,
    options: Options,
) !void {
    const formatted = try to_owned_slice(allocator, json_text, options);
    defer allocator.free(formatted);
    try writer.writeAll(formatted);
}

pub fn write_to(writer: anytype, json_text: []const u8, options: Options) !void {
    try write_to_alloc(writer, std.heap.page_allocator, json_text, options);
}

pub fn print_stdout_alloc(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    options: Options,
) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Options.debug_io, &stdout_buffer);
    try write_to_alloc(&stdout_writer.interface, allocator, json_text, options);
    try stdout_writer.interface.flush();
}

pub fn print_stdout(json_text: []const u8, options: Options) !void {
    try print_stdout_alloc(std.heap.page_allocator, json_text, options);
}

pub fn print_stderr_alloc(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    options: Options,
) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
    try write_to_alloc(&stderr_writer.interface, allocator, json_text, options);
    try stderr_writer.interface.flush();
}

pub fn print_stderr(json_text: []const u8, options: Options) !void {
    try print_stderr_alloc(std.heap.page_allocator, json_text, options);
}

pub fn json_print_alloc(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    options: Options,
) !void {
    try print_stdout_alloc(allocator, json_text, options);
}

pub fn json_print(json_text: []const u8, options: Options) !void {
    try print_stdout(json_text, options);
}

test "to_owned_slice pretty and compact" {
    const allocator = std.testing.allocator;
    const raw = "{\"ok\":true,\"count\":2}";

    const pretty = try to_owned_slice(allocator, raw, .{
        .style = .pretty,
        .append_newline = false,
    });
    defer allocator.free(pretty);
    try std.testing.expect(std.mem.indexOfScalar(u8, pretty, '\n') != null);
    try std.testing.expect(std.mem.startsWith(u8, pretty, "{"));

    const compact = try to_owned_slice(allocator, raw, .{
        .style = .compact,
        .append_newline = false,
    });
    defer allocator.free(compact);
    try std.testing.expectEqualStrings("{\"ok\":true,\"count\":2}", compact);
}

test "write_to writes JSON to custom writer" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try write_to_alloc(&out.writer, allocator, "{\"name\":\"john\"}", .{
        .style = .pretty,
        .append_newline = false,
    });

    const text = try out.toOwnedSlice();
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') != null);
}

test "printer outputs to stderr without std.debug" {
    const allocator = std.testing.allocator;
    if (!should_show_test_outputs(allocator)) return;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.writeAll("\n[json-printer example]\n");
    try print_stderr_alloc(allocator, "{\"event\":\"test\",\"ok\":true}", .{
        .style = .pretty,
        .append_newline = true,
    });
    try stderr.flush();
}

fn should_show_test_outputs(allocator: std.mem.Allocator) bool {
    _ = allocator;
    if (!builtin.link_libc) return false;
    const value_z = std.c.getenv("SHOW_TEST_OUTPUTS") orelse return false;
    const value = std.mem.sliceTo(value_z, 0);

    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}
