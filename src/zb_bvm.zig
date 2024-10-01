const std = @import("std");
const execute = @import("./brillig_vm/execute.zig").execute;
const disassemble = @import("./brillig_vm/disassemble.zig").disassemble;
const App = @import("yazap").App;
const Arg = @import("yazap").Arg;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = App.init(allocator, "zb-bvm", "Aztec Brillig VM cli tool.");
    defer app.deinit();

    var run_cmd = app.createCommand("run", "Run the given bytecode with the given calldata.");
    try run_cmd.addArg(Arg.positional("bytecode_path", null, null));
    try run_cmd.addArg(Arg.singleValueOption("calldata_path", 'c', "Path to file containing calldata."));
    try run_cmd.addArg(Arg.booleanOption("stats", 's', "Display execution stats after run."));
    run_cmd.setProperty(.help_on_empty_args);

    var dis_cmd = app.createCommand("dis", "Disassemble the given bytecode.");
    try dis_cmd.addArg(Arg.positional("bytecode_path", null, null));
    // dis_cmd.setProperty(.help_on_empty_args);

    var root = app.rootCommand();
    try root.addSubcommand(run_cmd);
    try root.addSubcommand(dis_cmd);

    const matches = try app.parseProcess();

    if (matches.subcommandMatches("run")) |cmd_matches| {
        const bytecode_path = cmd_matches.getSingleValue("bytecode_path").?;
        const calldata_path = cmd_matches.getSingleValue("calldata_path");
        execute(bytecode_path, calldata_path, cmd_matches.containsArg("stats")) catch |err| {
            std.debug.print("{}\n", .{err});
            // Returning 2 on traps, allows us to distinguish between zb failing and the bytecode execution failing.
            if (err == error.Trapped) {
                std.posix.exit(2);
            } else {
                std.posix.exit(1);
            }
        };
        return;
    }

    if (matches.subcommandMatches("dis")) |cmd_matches| {
        const bytecode_path = cmd_matches.getSingleValue("bytecode_path") orelse null;
        try disassemble(bytecode_path);
        return;
    }

    try app.displayHelp();
}
