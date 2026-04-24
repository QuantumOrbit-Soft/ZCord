//! Error handling module.
//! Defines all error types used in ZCord.

pub const Error = @import("error.zig").Error;
pub const ApiError = Error.ApiError;
pub const GatewayError = Error.GatewayError;
pub const ValidationError = Error.ValidationError;

/// Generic result type
pub fn Result(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: Error,
    };
}
