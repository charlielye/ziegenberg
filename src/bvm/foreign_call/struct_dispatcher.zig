const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const foreign_call = @import("./foreign_call.zig");
const ForeignCallParam = @import("./param.zig").ForeignCallParam;
const F = @import("../../bn254/fr.zig").Fr;
const io = @import("../io.zig");

/// Dispatch function for foreign calls.
/// Uses comptime meta foo to marshal data in and out of vm memory, and call functions with the same name on self.
/// Handler functions arguments and return types must match the layout as described by the foreign call.
/// The given allocator is used for transient data and is freed by the caller.
pub fn structDispatcher(
    target: anytype,
    allocator: std.mem.Allocator,
    mem: *Memory,
    fc: *const io.ForeignCall,
    params: []ForeignCallParam,
) !bool {
    // Transient memory required only for this call.
    // var arena = std.heap.ArenaAllocator.init(allocator);
    // defer arena.deinit();

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
                // For functions with optional parameters, each optional is represented as 2 values
                var expected_param_count: usize = 0;
                inline for (field_info.@"fn".params[1..]) |param_info| {
                    if (@typeInfo(param_info.type.?) == .optional) {
                        expected_param_count += 2; // Optional params are [is_some, value]
                    } else {
                        expected_param_count += 1;
                    }
                }

                if (params.len != expected_param_count) {
                    std.debug.print("Parameter count mismatch for {s}: Received {} expected {}.\n", .{
                        decl.name,
                        params.len,
                        expected_param_count,
                    });
                    return error.ForeignCallParameterCountMismatch;
                }
                // First arg should be this Txe struct.
                args[0] = target;

                // Marshal each parameter
                var param_idx: usize = 0;
                inline for (1..args.len) |i| {
                    const param_type = field_info.@"fn".params[i].type.?;
                    if (@typeInfo(param_type) == .optional) {
                        // Optional parameter - create array from two consecutive params
                        var opt_array = [_]ForeignCallParam{
                            params[param_idx], // is_some
                            params[param_idx + 1], // value
                        };
                        const opt_param = ForeignCallParam{ .Array = &opt_array };
                        std.debug.print("Marshal into {s} arg {} (optional): {any}\n", .{ decl.name, i, opt_param });
                        foreign_call.marshalInput(&args[i], allocator, opt_param) catch |err| {
                            std.debug.print("Failed to marshal into {s} arg {}: {any}\n", .{ decl.name, i, opt_param });
                            return err;
                        };
                        param_idx += 2;
                    } else {
                        std.debug.print("Marshal into {s} arg {}: {any}\n", .{ decl.name, i, params[param_idx] });
                        // Marshal the ForeignCallParam into the argument type.
                        foreign_call.marshalInput(&args[i], allocator, params[param_idx]) catch |err| {
                            std.debug.print("Failed to marshal into {s} arg {}: {any}\n", .{ decl.name, i, params[param_idx] });
                            return err;
                        };
                        param_idx += 1;
                    }
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
