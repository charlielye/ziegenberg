const std = @import("std");
const avmExecute = @import("./avm/execute.zig").execute;
const avmDisassemble = @import("./avm/disassemble.zig").disassemble;
const bvmExecute = @import("./brillig_vm/execute.zig").execute;
const bvmDisassemble = @import("./brillig_vm/disassemble.zig").disassemble;
const App = @import("yazap").App;
const Arg = @import("yazap").Arg;
const ArgMatches = @import("yazap").ArgMatches;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = App.init(allocator, "zb-bvm", "Aztec Brillig VM cli tool.");
    defer app.deinit();

    var root = app.rootCommand();

    {
        var avm_cmd = app.createCommand("avm", "Aztec VM commands.");

        var run_cmd = app.createCommand("run", "Run the given bytecode with the given calldata.");
        try run_cmd.addArg(Arg.positional("bytecode_path", null, null));
        try run_cmd.addArg(Arg.singleValueOption("calldata_path", 'c', "Path to file containing calldata."));
        try run_cmd.addArg(Arg.booleanOption("stats", 's', "Display execution stats after run."));
        try run_cmd.addArg(Arg.booleanOption("trace", 't', "Display execution trace during run."));
        // run_cmd.setProperty(.help_on_empty_args);

        var dis_cmd = app.createCommand("dis", "Disassemble the given bytecode.");
        try dis_cmd.addArg(Arg.positional("bytecode_path", null, null));

        try avm_cmd.addSubcommand(run_cmd);
        try avm_cmd.addSubcommand(dis_cmd);
        try root.addSubcommand(avm_cmd);
    }

    {
        var bvm_cmd = app.createCommand("bvm", "Brillig VM commands.");

        var run_cmd = app.createCommand("run", "Run the given bytecode with the given calldata.");
        try run_cmd.addArg(Arg.positional("bytecode_path", null, null));
        try run_cmd.addArg(Arg.singleValueOption("calldata_path", 'c', "Path to file containing calldata."));
        try run_cmd.addArg(Arg.booleanOption("stats", 's', "Display execution stats after run."));
        try run_cmd.addArg(Arg.booleanOption("trace", 't', "Display execution trace during run."));
        run_cmd.setProperty(.help_on_empty_args);

        var dis_cmd = app.createCommand("dis", "Disassemble the given bytecode.");
        try dis_cmd.addArg(Arg.positional("bytecode_path", null, null));
        try dis_cmd.addArg(Arg.booleanOption("binary", 'b', "Output the pure brillig as binary."));

        try bvm_cmd.addSubcommand(run_cmd);
        try bvm_cmd.addSubcommand(dis_cmd);
        try root.addSubcommand(bvm_cmd);
    }

    const matches = try app.parseProcess();

    if (matches.subcommandMatches("avm")) |avm_matches| {
        if (!avm_matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }
        try handleAvm(avm_matches);
        return;
    }

    if (matches.subcommandMatches("bvm")) |bvm_matches| {
        if (!bvm_matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }
        try handleBvm(bvm_matches);
        return;
    }

    try app.displayHelp();
}

fn handleAvm(matches: ArgMatches) !void {
    if (matches.subcommandMatches("run")) |cmd_matches| {
        const bytecode_path = cmd_matches.getSingleValue("bytecode_path");
        const calldata_path = cmd_matches.getSingleValue("calldata_path");
        avmExecute(.{
            .file_path = bytecode_path,
            .calldata_path = calldata_path,
            .show_stats = cmd_matches.containsArg("stats"),
            .show_trace = cmd_matches.containsArg("trace"),
        }) catch |err| {
            std.debug.print("{}\n", .{err});
            // Returning 2 on traps, allows us to distinguish between zb failing and the bytecode execution failing.
            // Returning 3 on unimplemented us allows us to distinguish between bugs and work to do.
            std.posix.exit(switch (err) {
                error.Unimplemented => 3,
                error.Trapped => 2,
                else => 1,
            });
        };
        return;
    }

    if (matches.subcommandMatches("dis")) |cmd_matches| {
        const bytecode_path = cmd_matches.getSingleValue("bytecode_path") orelse null;
        try avmDisassemble(bytecode_path);
        return;
    }
}

fn handleBvm(matches: ArgMatches) !void {
    if (matches.subcommandMatches("run")) |cmd_matches| {
        const bytecode_path = cmd_matches.getSingleValue("bytecode_path");
        const calldata_path = cmd_matches.getSingleValue("calldata_path");
        bvmExecute(.{
            .file_path = bytecode_path,
            .calldata_path = calldata_path,
            .show_stats = cmd_matches.containsArg("stats"),
            .show_trace = cmd_matches.containsArg("trace"),
        }) catch |err| {
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
        try bvmDisassemble(bytecode_path, cmd_matches.containsArg("binary"));
        return;
    }

    // try matches.displayHelp();
}
