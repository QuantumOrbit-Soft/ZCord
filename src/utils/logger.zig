//! Logging utilities.
//! Structured logging for ZCord.

const std = @import("std");

pub const LogLevel = enum {
    Debug,
    Info,
    Warn,
    Error,
};

pub fn log(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    const prefix = switch (level) {
        .Debug => "[DEBUG]",
        .Info => "[INFO]",
        .Warn => "[WARN]",
        .Error => "[ERROR]",
    };

    std.debug.print(prefix ++ " " ++ fmt ++ "\n", args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.Debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.Info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.Warn, fmt, args);
}

pub fn log_error(comptime fmt: []const u8, args: anytype) void {
    log(.Error, fmt, args);
}
