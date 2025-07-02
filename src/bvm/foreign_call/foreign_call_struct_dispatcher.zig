const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");

/// Dispatch function for foreign calls.
/// Uses comptime meta foo to marshal data in and out of vm memory, and call functions with the same name on self.
/// Handler functions arguments and return types must match the layout as described by the foreign call.
pub fn foreignCallStructDispatcher(
    target: anytype,
    allocator: std.mem.Allocator,
    mem: *Memory,
    fc: *const io.ForeignCall,
    params: []foreign_call.ForeignCallParam,
) !bool {
    // Transient memory required only for this call.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Get the type information of the target struct.
    const info = @typeInfo(@TypeOf(target.*)).@"struct";

    // Compile time loop over each declaration in the Txe struct.
    // Filtering for relevant functions at compile-time, we dispatch at runtime to function with matching name.
    inline for (info.decls) |decl| {
        // Skip any special functions.
        if (comptime (std.mem.eql(u8, decl.name, "init") or
            std.mem.eql(u8, decl.name, "deinit") or
            std.mem.eql(u8, decl.name, "handleForeignCall")))
        {
            continue;
        }
        // Get the declaration by name from the type, not the instance
        const field = @field(@TypeOf(target.*), decl.name);
        // Get the type, and type info of the field.
        const field_type = @TypeOf(field);
        const field_info = @typeInfo(field_type);
        // Compile time check:
        // - This field is a function.
        // - With at least one arg (self).
        if (field_info == .@"fn" and field_info.@"fn".params.len >= 1) {
            // Runtime check for matching function name.
            if (std.mem.eql(u8, decl.name, fc.function)) {
                // There is a function name matching the call on ourself.
                // Get a tuple to hold the values of the argument types for the function.
                const Args = std.meta.ArgsTuple(@TypeOf(field));
                var args: Args = undefined;
                // Check that the number of parameters matches the number of arguments in the foreign call.
                std.debug.assert(args.len == params.len + 1);
                // First arg should be this Txe struct.
                args[0] = target;
                inline for (1..args.len) |i| {
                    std.debug.print("Marshal into {s} arg {}: {any}\n", .{ decl.name, i, params[i - 1] });
                    // Marshal the ForeignCallParam into the argument type.
                    foreign_call.marshalInput(&args[i], arena.allocator(), params[i - 1]) catch |err| {
                        std.debug.print("Failed to marshal into {s} arg {}: {any}\n", .{ decl.name, i, params[i - 1] });
                        return err;
                    };
                }
                // Make the function call.
                std.debug.print("Making foreign call to: {s}\n", .{decl.name});
                const r = try @call(.auto, field, args);
                // Marshall the result back into the VM memory.
                _ = foreign_call.marshalOutput(&r, mem, fc.destinations, fc.destination_value_types);
                // std.debug.assert(written == fc.destinations.len);
                return true;
            }
        }
    }

    return false;
}
