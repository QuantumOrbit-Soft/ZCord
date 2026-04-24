const std = @import("std");

pub const SpaceEncoding = enum {
    plus,
    percent_20,
};

pub fn assert_struct_payload(comptime T: type, comptime fn_name: []const u8) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError(fn_name ++ " expects a struct payload (anonymous or named)");
    }
}

pub fn write_pairs_from_struct(
    writer: *std.Io.Writer,
    payload: anytype,
    wrote_any_pair: *bool,
    space_encoding: SpaceEncoding,
) std.Io.Writer.Error!void {
    const payload_type = @TypeOf(payload);
    const struct_info = @typeInfo(payload_type).@"struct";

    inline for (struct_info.fields) |field| {
        const value = @field(payload, field.name);
        switch (@typeInfo(field.type)) {
            .optional => {
                if (value) |inner| {
                    try write_pair(writer, field.name, inner, wrote_any_pair, space_encoding);
                }
            },
            else => {
                try write_pair(writer, field.name, value, wrote_any_pair, space_encoding);
            },
        }
    }
}

fn write_pair(
    writer: *std.Io.Writer,
    key: []const u8,
    value: anytype,
    wrote_any_pair: *bool,
    space_encoding: SpaceEncoding,
) std.Io.Writer.Error!void {
    if (wrote_any_pair.*) {
        try writer.writeByte('&');
    } else {
        wrote_any_pair.* = true;
    }

    try write_escaped(writer, key, space_encoding);
    try writer.writeByte('=');
    try write_value(writer, value, space_encoding);
}

pub fn write_value(
    writer: *std.Io.Writer,
    value: anytype,
    space_encoding: SpaceEncoding,
) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => {
            try write_escaped(writer, if (value) "true" else "false", space_encoding);
        },
        .int => {
            var number_buffer: [256]u8 = undefined;
            const number_text = std.fmt.bufPrint(&number_buffer, "{d}", .{value}) catch unreachable;
            try write_escaped(writer, number_text, space_encoding);
        },
        .comptime_int => {
            var number_buffer: [256]u8 = undefined;
            const number_text = std.fmt.bufPrint(&number_buffer, "{d}", .{value}) catch unreachable;
            try write_escaped(writer, number_text, space_encoding);
        },
        .float => {
            var number_buffer: [256]u8 = undefined;
            const number_text = std.fmt.bufPrint(&number_buffer, "{d}", .{value}) catch unreachable;
            try write_escaped(writer, number_text, space_encoding);
        },
        .comptime_float => {
            var number_buffer: [256]u8 = undefined;
            const number_text = std.fmt.bufPrint(&number_buffer, "{d}", .{value}) catch unreachable;
            try write_escaped(writer, number_text, space_encoding);
        },
        .@"enum" => {
            try write_escaped(writer, @tagName(value), space_encoding);
        },
        .array => |array_info| {
            if (array_info.child != u8) {
                @compileError(
                    "Only scalar and string-like fields are supported. Invalid field type: " ++
                        @typeName(T),
                );
            }
            try write_escaped(writer, value[0..], space_encoding);
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try write_escaped(writer, value, space_encoding);
                return;
            }

            if (pointer_info.size == .one and comptime is_byte_array(pointer_info.child)) {
                try write_escaped(writer, value.*[0..], space_encoding);
                return;
            }
            @compileError(
                "Only []const u8 is supported for string-like pointer fields. " ++
                    "Invalid field type: " ++
                    @typeName(T),
            );
        },
        .optional => if (value) |inner| try write_value(writer, inner, space_encoding),
        else => {
            @compileError(
                "Only bool, number, enum and string-like fields are supported. " ++
                    "Invalid field type: " ++
                    @typeName(T),
            );
        },
    }
}

pub fn write_escaped(
    writer: *std.Io.Writer,
    input: []const u8,
    space_encoding: SpaceEncoding,
) std.Io.Writer.Error!void {
    for (input) |byte| {
        if (byte == ' ') {
            switch (space_encoding) {
                .plus => try writer.writeByte('+'),
                .percent_20 => try writer.writeAll("%20"),
            }
            continue;
        }

        if (is_unescaped(byte)) {
            try writer.writeByte(byte);
            continue;
        }

        try writer.writeByte('%');
        try writer.writeByte(hex_upper((byte >> 4) & 0x0f));
        try writer.writeByte(hex_upper(byte & 0x0f));
    }
}

fn is_byte_array(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |array_info| array_info.child == u8,
        else => false,
    };
}

fn is_unescaped(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

fn hex_upper(value: u8) u8 {
    return "0123456789ABCDEF"[value];
}
