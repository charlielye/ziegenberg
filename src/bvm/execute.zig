const std = @import("std");
const deserializeOpcodes = @import("io.zig").deserializeOpcodes;
const BrilligOpcode = @import("io.zig").BrilligOpcode;
const BrilligVm = @import("brillig_vm.zig").BrilligVm;
const BitSize = @import("io.zig").BitSize;
const io = @import("io.zig");
const Bn254Fr = @import("../bn254/fr.zig").Fr;
const fieldOps = @import("../blackbox/field.zig");
const blackbox = @import("../blackbox/blackbox.zig");
const rdtsc = @import("../timer/rdtsc.zig").rdtsc;
const Memory = @import("./memory.zig").Memory;
const ForeignCallDispatcher = @import("../bvm/foreign_call/dispatcher.zig").Dispatcher;
const debug_info = @import("./debug_info.zig");
const debug_context = @import("./debug_context.zig");
const DebugContext = debug_context.DebugContext;
const DebugMode = debug_context.DebugMode;

pub const ExecuteOptions = struct {
    file_path: ?[]const u8 = null,
    calldata_path: ?[]const u8 = null,
    show_stats: bool = false,
    show_trace: bool = false,
    debug_mode: bool = false,
};

pub fn execute(options: ExecuteOptions) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const opcodes = try io.load(allocator, options.file_path);
    std.debug.print("Deserialized {} opcodes.\n", .{opcodes.len});

    var calldata: []u256 = &[_]u256{};
    if (options.calldata_path) |path| {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const calldata_bytes = try f.readToEndAllocOptions(allocator, std.math.maxInt(usize), null, 32, null);
        calldata = std.mem.bytesAsSlice(u256, calldata_bytes);
        for (0..calldata.len) |i| {
            calldata[i] = @byteSwap(calldata[i]);
        }
    }
    std.debug.print("Calldata consists of {} elements.\n", .{calldata.len});

    var fc_handler = try ForeignCallDispatcher.init(allocator);
    defer fc_handler.deinit();

    var t = try std.time.Timer.start();
    std.debug.print("Initing...\n", .{});
    var brillig_vm = try BrilligVm.init(allocator, calldata, &fc_handler);
    defer brillig_vm.deinit();

    // Create debug context if debug mode is enabled
    var debug_ctx_storage: ?DebugContext = null;
    defer if (debug_ctx_storage) |*ctx| ctx.deinit();

    var debug_ctx_ptr: ?*DebugContext = null;
    if (options.debug_mode or options.show_trace) {
        const mode: DebugMode = if (options.debug_mode) .step_by_line else .trace;
        debug_ctx_storage = DebugContext.init(allocator, mode);
        debug_ctx_ptr = &debug_ctx_storage.?;

        // Note: In a full implementation, we would load debug symbols here
        // For now, we'll need the artifact path to be provided
        std.debug.print("Debug mode enabled: {}\n", .{mode});
    }

    std.debug.print("Init time: {}us\n", .{t.read() / 1000});

    std.debug.print("Executing...\n", .{});
    const result = brillig_vm.executeVm(opcodes, .{
        .sample_rate = if (options.show_stats) 1000 else 0,
        .debug_ctx = debug_ctx_ptr,
    });
    if (options.show_stats) brillig_vm.dumpStats();
    return result;
}
