const std = @import("std");

pub const callback_thread_count_default: u16 = 4;
pub const callback_thread_count_max: u16 = 32;
pub const callback_queue_capacity_default: u16 = 256;
pub const callback_queue_capacity_max: u16 = 4096;

pub const CallbackTask = struct {
    run: *const fn (*CallbackTask) void,
    destroy: *const fn (*CallbackTask) void,
};

const CallbackQueue = std.Io.Queue(*CallbackTask);

allocator: std.mem.Allocator = undefined,
threaded: std.Io.Threaded = undefined,
io: std.Io = undefined,
queue: CallbackQueue = undefined,
queue_storage: []*CallbackTask = &.{},
workers: []std.Thread = &.{},
accepting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
initialized: bool = false,

pub const CallbackRuntime = @This();
const Runtime = @This();

pub fn init(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    thread_count: u16,
    queue_capacity: u16,
) !void {
    try validate_options(thread_count, queue_capacity);

    const queue_storage = try allocator.alloc(*CallbackTask, queue_capacity);
    errdefer allocator.free(queue_storage);

    const workers = try allocator.alloc(std.Thread, thread_count);
    errdefer allocator.free(workers);

    runtime.* = .{
        .allocator = allocator,
        .threaded = std.Io.Threaded.init(allocator, .{
            .async_limit = .limited(thread_count),
            .concurrent_limit = .limited(thread_count),
        }),
        .io = undefined,
        .queue = CallbackQueue.init(queue_storage),
        .queue_storage = queue_storage,
        .workers = workers,
        .accepting = std.atomic.Value(bool).init(true),
        .initialized = true,
    };
    runtime.io = runtime.threaded.io();

    var started: u16 = 0;
    errdefer runtime.stop_started_workers(started);
    while (started < thread_count) : (started += 1) {
        runtime.workers[started] = try std.Thread.spawn(.{}, worker, .{runtime});
    }
}

pub fn deinit(runtime: *Runtime) void {
    if (runtime.initialized) {} else return;

    runtime.accepting.store(false, .release);
    runtime.queue.close(runtime.io);
    for (runtime.workers) |thread| {
        thread.join();
    }

    runtime.threaded.deinit();
    runtime.allocator.free(runtime.workers);
    runtime.allocator.free(runtime.queue_storage);
    runtime.* = .{};
}

pub fn enqueue(runtime: *Runtime, task: *CallbackTask) bool {
    if (runtime.accepting.load(.acquire)) {} else return false;

    const queued = runtime.queue.put(runtime.io, &.{task}, 0) catch return false;
    return queued == 1;
}

fn worker(runtime: *Runtime) void {
    while (true) {
        const task = runtime.queue.getOneUncancelable(runtime.io) catch |err| switch (err) {
            error.Closed => return,
        };
        task.run(task);
        task.destroy(task);
    }
}

fn stop_started_workers(runtime: *Runtime, started: u16) void {
    runtime.accepting.store(false, .release);
    runtime.queue.close(runtime.io);
    for (runtime.workers[0..started]) |thread| {
        thread.join();
    }
    runtime.threaded.deinit();
}

fn validate_options(thread_count: u16, queue_capacity: u16) !void {
    if (0 < thread_count) {} else return error.InvalidCallbackThreadCount;
    if (thread_count <= callback_thread_count_max) {} else {
        return error.CallbackThreadCountTooLarge;
    }
    if (0 < queue_capacity) {} else return error.InvalidCallbackQueueCapacity;
    if (queue_capacity <= callback_queue_capacity_max) {} else {
        return error.CallbackQueueCapacityTooLarge;
    }
}

test "CallbackRuntime validates bounded options" {
    try std.testing.expectError(error.InvalidCallbackThreadCount, validate_options(0, 1));
    try std.testing.expectError(error.InvalidCallbackQueueCapacity, validate_options(1, 0));
    try std.testing.expectError(
        error.CallbackThreadCountTooLarge,
        validate_options(callback_thread_count_max + 1, 1),
    );
    try std.testing.expectError(
        error.CallbackQueueCapacityTooLarge,
        validate_options(1, callback_queue_capacity_max + 1),
    );
}
