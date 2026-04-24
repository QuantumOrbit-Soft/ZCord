const std = @import("std");

pub const RequestClient = @import("core/request.zig");
pub const JsonPrinter = @import("core/json_printer.zig");
pub const WebSocketClient = @import("core/websocket.zig");
pub const RequestArg = RequestClient.RequestArg;
pub const HeadersArg = RequestClient.HeadersArg;
pub const PayloadKind = RequestClient.PayloadKind;
pub const RedirectPolicy = RequestClient.RedirectPolicy;
pub const async_task = RequestClient.async_task;
pub const return_of = RequestClient.return_of;
pub const Response = RequestClient.Response;
pub const JsonPrintStyle = JsonPrinter.Style;
pub const JsonPrintOptions = JsonPrinter.Options;
pub const WebSocketOpcode = WebSocketClient.Opcode;
pub const WebSocketMessage = WebSocketClient.Message;
pub const WebSocketMessageKind = WebSocketClient.MessageKind;
pub const WebSocketConnectArg = WebSocketClient.ConnectArg;
pub const WebSocketHeadersArg = WebSocketClient.HeadersArg;
pub const WebSocketSendArg = WebSocketClient.SendArg;
pub const WebSocketCloseSender = WebSocketClient.CloseSender;
pub const QueryBuilder = RequestClient.QueryBuilder;
pub const ScratchError = RequestClient.ScratchError;
pub const QueryError = RequestClient.QueryError;
pub const StreamReader = RequestClient.StreamReader;
pub const multipart = @import("core/multipart.zig");
pub const MultipartPart = multipart.Part;
pub const CookieJar = @import("core/cookie_jar.zig").CookieJar;
pub const WebSocketQueryError = WebSocketClient.QueryError;
pub const WebSocketPayloadError = WebSocketClient.PayloadError;
pub const ClientBuilder = @import("core/client_builder.zig").ClientBuilder;
pub const RequestBuilder = @import("core/request_builder.zig").RequestBuilder;

pub fn request_builder(
    client: *RequestClient,
    method: std.http.Method,
    url: []const u8,
) RequestBuilder {
    return RequestBuilder.init(client, method, url);
}

test "api surface cobre metodos principais" {
    comptime {
        _ = RequestClient.init;
        _ = RequestClient.new;
        _ = RequestClient.init_default;
        _ = RequestClient.deinit;

        _ = RequestClient.get;
        _ = RequestClient.post;
        _ = RequestClient.put;
        _ = RequestClient.patch;
        _ = RequestClient.delete;
        _ = RequestArg;
        _ = HeadersArg;
        _ = RequestClient.send_now;
        _ = RequestClient.return_of;
        _ = JsonPrinter.to_owned_slice;
        _ = JsonPrinter.write_to;
        _ = JsonPrinter.json_print;
        _ = JsonPrinter.print_stdout;

        _ = RequestClient.scratch_json;
        _ = RequestClient.scratch_post_form;
        _ = RequestClient.build_query;
        _ = RequestClient.stream;
        _ = RequestClient.stream_to;
        _ = RequestClient.enable_cookies;
        _ = RequestClient.disable_cookies;
        _ = RequestClient.set_default_request_options;
        _ = RequestClient.default_request_options;

        _ = WebSocketClient.init;
        _ = WebSocketClient.deinit;
        _ = WebSocketClient.connect;
        _ = WebSocketClient.send;
        _ = WebSocketClient.send_json;
        _ = WebSocketClient.read;
        _ = WebSocketClient.disconnect;
        _ = WebSocketClient.is_connected;
        _ = WebSocketClient.subprotocol;

        _ = ClientBuilder.init;
        _ = ClientBuilder.build;
        _ = RequestBuilder.init;
        _ = RequestBuilder.send;
        _ = RequestBuilder.send_json;
    }

    try std.testing.expect(true);
}

test "top-level exports exist" {
    comptime {
        _ = RequestClient;
        _ = RequestArg;
        _ = HeadersArg;
        _ = PayloadKind;
        _ = RedirectPolicy;
        _ = async_task;
        _ = return_of;
        _ = Response;
        _ = JsonPrinter;
        _ = JsonPrintStyle;
        _ = JsonPrintOptions;
        _ = WebSocketClient;
        _ = WebSocketOpcode;
        _ = WebSocketMessage;
        _ = WebSocketMessageKind;
        _ = WebSocketConnectArg;
        _ = WebSocketHeadersArg;
        _ = WebSocketSendArg;
        _ = WebSocketCloseSender;
        _ = QueryBuilder;
        _ = ScratchError;
        _ = QueryError;
        _ = WebSocketQueryError;
        _ = WebSocketPayloadError;
        _ = StreamReader;
        _ = multipart;
        _ = MultipartPart;
        _ = CookieJar;
        _ = ClientBuilder;
        _ = RequestBuilder;
    }

    try std.testing.expect(true);
}

test "module helper request_builder exists" {
    comptime {
        _ = request_builder;
    }

    try std.testing.expect(true);
}
