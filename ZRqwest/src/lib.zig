const http = @import("http/lib.zig");
const contracts_mod = @import("contracts.zig");

pub const RequestClient = http.RequestClient;
pub const RequestArg = http.RequestArg;
pub const HeadersArg = http.HeadersArg;
pub const JsonPrinter = http.JsonPrinter;
pub const WebSocketClient = http.WebSocketClient;
pub const PayloadKind = http.PayloadKind;
pub const RedirectPolicy = http.RedirectPolicy;
pub const async_task = http.async_task;
pub const return_of = http.return_of;
pub const Response = http.Response;
pub const JsonPrintStyle = http.JsonPrintStyle;
pub const JsonPrintOptions = http.JsonPrintOptions;
pub const WebSocketOpcode = http.WebSocketOpcode;
pub const WebSocketMessage = http.WebSocketMessage;
pub const WebSocketMessageKind = http.WebSocketMessageKind;
pub const WebSocketConnectArg = http.WebSocketConnectArg;
pub const WebSocketHeadersArg = http.WebSocketHeadersArg;
pub const WebSocketSendArg = http.WebSocketSendArg;
pub const WebSocketCloseSender = http.WebSocketCloseSender;
pub const QueryBuilder = http.QueryBuilder;
pub const ScratchError = http.ScratchError;
pub const QueryError = http.QueryError;
pub const WebSocketQueryError = http.WebSocketQueryError;
pub const WebSocketPayloadError = http.WebSocketPayloadError;
pub const StreamReader = http.StreamReader;
pub const multipart = http.multipart;
pub const MultipartPart = http.MultipartPart;
pub const CookieJar = http.CookieJar;
pub const ClientBuilder = http.ClientBuilder;
pub const RequestBuilder = http.RequestBuilder;
pub const request_builder = http.request_builder;
pub const TransportContract = contracts_mod.TransportContract;
pub const CacheContract = contracts_mod.CacheContract;
pub const TransportRequest = contracts_mod.TransportRequest;
pub const TransportResponse = contracts_mod.TransportResponse;

test {
    _ = @import("http/lib.zig");
    _ = @import("contracts.zig");
}
