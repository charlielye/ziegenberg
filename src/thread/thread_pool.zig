const std = @import("std");
const poseidon2Hash = @import("../poseidon2/poseidon2.zig").hash;
const Fr = @import("../bn254/fr.zig").Fr;
const Atomic = std.atomic.Value;

pub const ThreadPool = @import("./kprotty/thread_pool.zig");

var a: Fr = undefined;
var b: Fr = undefined;
var c: Fr = undefined;
var counter: Atomic(u64) = Atomic(u64).init(0);

fn taskCallback(task: *ThreadPool.Task) void {
    _ = task; // We are not using the task itself here
    c = poseidon2Hash(&[_]Fr{ a, b });
    _ = counter.fetchAdd(1, .monotonic);
}

test "thread pool bench" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    var pool = ThreadPool.init(.{ .max_threads = 64 });
    defer pool.deinit();

    a = Fr.random();
    b = Fr.random();

    const tasks = try allocator.alloc(ThreadPool.Task, 1_000_000);

    for (tasks) |*task| {
        task.* = ThreadPool.Task{ .callback = taskCallback };
    }

    // Create a Batch and add all tasks to it
    var batch = ThreadPool.Batch{};
    for (tasks) |*task| {
        batch.push(ThreadPool.Batch.from(task));
    }

    // Schedule the entire batch in one go
    var t = try std.time.Timer.start();
    pool.schedule(batch);

    while (counter.load(.monotonic) != 1000000) {}

    // Output the final counter value
    std.debug.print("Final counter value: {} {}us\n", .{ counter.load(.monotonic), t.read() / 1000 });
    std.debug.print("{x}\n", .{c});

    pool.shutdown();
}
