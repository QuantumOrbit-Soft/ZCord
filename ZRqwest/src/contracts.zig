const std = @import("std");

pub const TransportRequest = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
};

pub const TransportResponse = struct {
    status_code: u16,
    body: []const u8,
};

pub const TransportContract = struct {
    pub fn assert(comptime T: type) void {
        assert_method(T, "send", false, &.{TransportRequest}, anyerror!TransportResponse);
    }
};

pub const CacheContract = struct {
    pub fn assert(comptime T: type) void {
        assert_method(T, "get", true, &.{[]const u8}, ?[]const u8);
        assert_method(T, "put", false, &.{ []const u8, []const u8 }, anyerror!void);
        assert_method(T, "remove", false, &.{[]const u8}, bool);
    }
};

pub fn assert_method(
    comptime T: type,
    comptime decl_name: []const u8,
    comptime receiver_is_const: bool,
    comptime arg_types: []const type,
    comptime return_type: type,
) void {
    if (!@hasDecl(T, decl_name)) {
        @compileError(@typeName(T) ++ " precisa implementar '" ++ decl_name ++ "'");
    }

    const method_type = declaration_fn_type(T, decl_name);
    const info = function_info(method_type);
    const expected_param_count = arg_types.len + 1;
    if (info.params.len != expected_param_count) {
        @compileError(
            "Metodo '" ++ decl_name ++ "' em '" ++ @typeName(T) ++
                "' precisa ter " ++ std.fmt.comptimePrint("{d}", .{expected_param_count}) ++ " parametros",
        );
    }

    const receiver_type = info.params[0].type orelse @compileError("Receiver invalido");
    const receiver_ptr = pointer_info(receiver_type, "Primeiro parametro precisa ser ponteiro");
    if (receiver_ptr.child != T) {
        @compileError("Primeiro parametro de '" ++ decl_name ++ "' precisa ser *T ou *const T");
    }

    if (receiver_ptr.is_const != receiver_is_const) {
        const expected = if (receiver_is_const) "*const T" else "*T";
        @compileError("Metodo '" ++ decl_name ++ "' precisa usar receiver " ++ expected);
    }

    inline for (arg_types, 0..) |ArgType, index| {
        if (info.params[index + 1].type != ArgType) {
            @compileError(
                "Parametro " ++ std.fmt.comptimePrint("{d}", .{index + 1}) ++ " de '" ++ decl_name ++
                    "' em '" ++ @typeName(T) ++ "' nao bate com o contrato",
            );
        }
    }

    if (info.return_type != return_type) {
        @compileError("Metodo '" ++ decl_name ++ "' em '" ++ @typeName(T) ++ "' tem retorno invalido");
    }
}

fn declaration_fn_type(comptime Container: type, comptime decl_name: []const u8) type {
    const decl_value = @field(Container, decl_name);
    const decl_type = @TypeOf(decl_value);
    return switch (@typeInfo(decl_type)) {
        .@"fn" => decl_type,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => pointer.child,
            else => @compileError("Declaracao '" ++ decl_name ++ "' precisa ser funcao"),
        },
        else => @compileError("Declaracao '" ++ decl_name ++ "' precisa ser funcao"),
    };
}

fn function_info(comptime F: type) std.builtin.Type.Fn {
    return switch (@typeInfo(F)) {
        .@"fn" => |info| info,
        else => @compileError("Esperado tipo de funcao"),
    };
}

fn pointer_info(comptime Pointer: type, comptime message: []const u8) std.builtin.Type.Pointer {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info,
        else => @compileError(message),
    };
}

test "TransportContract accepts matching implementation" {
    const Transport = struct {
        const Self = @This();

        pub fn send(_: *Self, request: TransportRequest) anyerror!TransportResponse {
            _ = request;
            return .{ .status_code = 200, .body = "ok" };
        }
    };

    comptime TransportContract.assert(Transport);
    try std.testing.expect(true);
}

test "CacheContract accepts matching implementation" {
    const Cache = struct {
        const Self = @This();

        pub fn get(_: *const Self, _: []const u8) ?[]const u8 {
            return null;
        }

        pub fn put(_: *Self, _: []const u8, _: []const u8) anyerror!void {}

        pub fn remove(_: *Self, _: []const u8) bool {
            return false;
        }
    };

    comptime CacheContract.assert(Cache);
    try std.testing.expect(true);
}
