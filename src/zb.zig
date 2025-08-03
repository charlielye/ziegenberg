const std = @import("std");
const avmExecute = @import("./avm/execute.zig").execute;
const avmDisassemble = @import("./avm/disassemble.zig").disassemble;
// const bvmExecute = @import("./bvm/execute.zig").execute;
// const bvmDisassemble = @import("./bvm/disassemble.zig").disassemble;
const cvmExecute = @import("./cvm/execute.zig").execute;
const cvmDisassemble = @import("./cvm/disassemble.zig").disassemble;
const mt = @import("./merkle_tree/package.zig");
const ThreadPool = @import("./thread/thread_pool.zig").ThreadPool;
const F = @import("./bn254/fr.zig").Fr;
const App = @import("yazap").App;
const Arg = @import("yazap").Arg;
const ArgMatches = @import("yazap").ArgMatches;
const Txe = @import("./txe/package.zig").Txe;
const debug = @import("./debug/package.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = App.init(allocator, "zb", "Ziegenberg/AXE - an Aztec eXecution Engine.");
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

        try avm_cmd.addSubcommands(&.{ run_cmd, dis_cmd });
        try root.addSubcommand(avm_cmd);
    }

    {
        var txe_cmd = app.createCommand("txe", "Run the given artifact within the Txe.");
        try txe_cmd.addArg(Arg.positional("artifact_path", "Path to file containing nargo json contract artifact.", null));
        try txe_cmd.addArg(Arg.singleValueOption("calldata_path", 'c', "Path to toml containing calldata (default: Prover.toml)."));
        try txe_cmd.addArg(Arg.booleanOption("stats", 's', "Display execution stats after run."));
        try txe_cmd.addArg(Arg.booleanOption("trace", 't', "Display execution trace during run."));
        try txe_cmd.addArg(Arg.booleanOption("debug", 'd', "Launch interactive debugger."));
        try txe_cmd.addArg(Arg.booleanOption("debug-dap", null, "Enable DAP debugging mode for VSCode."));
        txe_cmd.setProperty(.help_on_empty_args);

        try root.addSubcommand(txe_cmd);
    }
    
    {
        var debug_cmd = app.createCommand("debug", "Debug client for connecting to a DAP server.");
        debug_cmd.setProperty(.help_on_empty_args);
        try root.addSubcommand(debug_cmd);
    }

    {
        var cvm_cmd = app.createCommand("cvm", "Circuit VM commands.");

        var run_cmd = app.createCommand("run", "Run the given bytecode with the given calldata.");
        try run_cmd.addArg(Arg.positional("project_path", null, null));
        try run_cmd.addArg(Arg.singleValueOption("artifact_path", 'a', "Path to file containing nargo json artifact."));
        try run_cmd.addArg(Arg.singleValueOption("witness_path", 'w', "Path to to write output witness data."));
        try run_cmd.addArg(Arg.singleValueOption("bytecode_path", 'b', "Path to file containing raw bytecode."));
        try run_cmd.addArg(Arg.singleValueOption("calldata_path", 'c', "Path to toml file containing calldata."));
        try run_cmd.addArg(Arg.booleanOption("stats", 's', "Display execution stats after run."));
        try run_cmd.addArg(Arg.booleanOption("trace", 't', "Display execution trace during run."));
        try run_cmd.addArg(Arg.booleanOption("debug", 'd', "Step through execution by source line."));
        try run_cmd.addArg(Arg.booleanOption("debug-dap", null, "Enable DAP debugging mode for VSCode."));
        try run_cmd.addArg(Arg.booleanOption("binary", 'b', "Output the witness as binary."));
        // run_cmd.setProperty(.help_on_empty_args);

        var dis_cmd = app.createCommand("dis", "Disassemble the given bytecode.");
        try dis_cmd.addArg(Arg.positional("bytecode_path", null, null));

        try cvm_cmd.addSubcommands(&.{ run_cmd, dis_cmd });
        try root.addSubcommand(cvm_cmd);
    }

    {
        var mt_cmd = app.createCommand("mt", "Merkle tree commands.");
        const root_cmd = app.createCommand("root", "Compute and print the root from stdin leaves.");
        // try root_cmd.addArg(Arg.positional("depth", null, null));
        // var append_cmd = app.createCommand("append", "Append leaves on stdin to the tree.");

        try mt_cmd.addSubcommands(&.{root_cmd});
        try root.addSubcommand(mt_cmd);
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

    if (matches.subcommandMatches("txe")) |txe_matches| {
        if (!txe_matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }
        try handleTxe(txe_matches);
        return;
    }
    
    if (matches.subcommandMatches("debug")) |_| {
        try handleDebug();
        return;
    }

    if (matches.subcommandMatches("cvm")) |cvm_matches| {
        if (!cvm_matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }
        try handleCvm(cvm_matches);
        return;
    }

    if (matches.subcommandMatches("mt")) |mt_matches| {
        if (!mt_matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }
        try handleMt(mt_matches);
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

fn handleTxe(cmd_matches: ArgMatches) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // Check if debug mode is requested
    if (cmd_matches.containsArg("debug")) {
        // Create pipes for bidirectional communication
        const to_child = try std.posix.pipe();
        const from_child = try std.posix.pipe();
        
        const pid = try std.posix.fork();
        if (pid == 0) {
            // Child process: Run the program with DAP server
            // Redirect stdin/stdout to pipes
            try std.posix.dup2(to_child[0], std.posix.STDIN_FILENO);
            try std.posix.dup2(from_child[1], std.posix.STDOUT_FILENO);
            
            // Redirect stderr to /dev/null to avoid polluting the terminal
            const dev_null = try std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
            try std.posix.dup2(dev_null, std.posix.STDERR_FILENO);
            std.posix.close(dev_null);
            
            // Close unused pipe ends
            std.posix.close(to_child[1]);
            std.posix.close(from_child[0]);
            
            // Run TXE with DAP mode enabled
            const txe = try Txe.init(allocator, "data/contracts", true);
            defer txe.deinit();

            txe.execute(cmd_matches.getSingleValue("artifact_path").?, .{
                .calldata_path = cmd_matches.getSingleValue("calldata_path"),
                .show_stats = cmd_matches.containsArg("stats"),
                .show_trace = cmd_matches.containsArg("trace"),
            }) catch |err| {
                std.debug.print("{}\n", .{err});
                std.posix.exit(switch (err) {
                    error.Trapped => 2,
                    else => 1,
                });
            };
            
            // Exit child process
            std.posix.exit(0);
        } else {
            // Parent process: Become the debug CLI
            // Close unused pipe ends
            std.posix.close(to_child[0]);
            std.posix.close(from_child[1]);
            
            // Create readers/writers from the pipes
            const from_child_file = std.fs.File{ .handle = from_child[0] };
            const to_child_file = std.fs.File{ .handle = to_child[1] };
            const reader = from_child_file.reader();
            const writer = to_child_file.writer();
            
            // Run the debug client
            var cli = debug.DebugCli.init(allocator, reader, writer);
            defer cli.deinit();
            
            try cli.run();
            
            // Kill the child process if it's still running
            _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            
            // Wait for child to exit with a timeout
            const wait_result = std.posix.waitpid(pid, std.posix.W.NOHANG);
            if (wait_result.pid == 0) {
                // Child hasn't exited yet, force kill
                _ = std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                _ = std.posix.waitpid(pid, 0);
            }
            
            // Close pipes
            std.posix.close(to_child[1]);
            std.posix.close(from_child[0]);
            
            return;
        }
    }

    // Normal execution (no debug mode)
    const txe = try Txe.init(allocator, "data/contracts", cmd_matches.containsArg("debug-dap"));
    defer txe.deinit();

    txe.execute(cmd_matches.getSingleValue("artifact_path").?, .{
        .calldata_path = cmd_matches.getSingleValue("calldata_path"),
        .show_stats = cmd_matches.containsArg("stats"),
        .show_trace = cmd_matches.containsArg("trace"),
    }) catch |err| {
        std.debug.print("{}\n", .{err});
        // Returning 2 on traps, allows us to distinguish between zb failing and the bytecode execution failing.
        std.posix.exit(switch (err) {
            error.Trapped => 2,
            else => 1,
        });
    };
}

fn handleCvm(matches: ArgMatches) !void {
    if (matches.subcommandMatches("run")) |cmd_matches| {
        cvmExecute(.{
            .project_path = cmd_matches.getSingleValue("project_path"),
            .artifact_path = cmd_matches.getSingleValue("artifact_path"),
            .witness_path = cmd_matches.getSingleValue("witness_path"),
            .bytecode_path = cmd_matches.getSingleValue("bytecode_path"),
            .calldata_path = cmd_matches.getSingleValue("calldata_path"),
            .show_stats = cmd_matches.containsArg("stats"),
            .show_trace = cmd_matches.containsArg("trace"),
            .debug_mode = cmd_matches.containsArg("debug"),
            .debug_dap = cmd_matches.containsArg("debug-dap"),
            .binary = cmd_matches.containsArg("binary"),
        }) catch |err| {
            // std.debug.print("Exiting due to error: {}\n", .{err});
            // Returning 2 on traps, allows us to distinguish between zb failing and the bytecode execution failing.
            switch (err) {
                // error.Unimplemented => std.posix.exit(3),
                error.Trapped => std.posix.exit(2),
                else => return err,
            }
        };
        return;
    }

    if (matches.subcommandMatches("dis")) |cmd_matches| {
        const bytecode_path = cmd_matches.getSingleValue("bytecode_path") orelse null;
        try cvmDisassemble(bytecode_path);
        return;
    }
}

fn handleDebug() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    
    // Debug client that connects to stdin/stdout (for use with external DAP server)
    var cli = debug.DebugCli.init(
        allocator,
        std.io.getStdIn().reader(),
        std.io.getStdOut().writer(),
    );
    defer cli.deinit();
    
    try cli.run();
}

fn handleMt(matches: ArgMatches) !void {
    if (matches.subcommandMatches("root")) |_| {
        const threads = @min(try std.Thread.getCpuCount(), 64);
        var pool = ThreadPool.init(.{ .max_threads = threads });
        defer {
            pool.shutdown();
            pool.deinit();
        }
        var tree = try mt.MerkleTreeMem(40, mt.poseidon2).init(std.heap.page_allocator, &pool);
        const stdin = std.io.getStdIn();
        const bytes = try stdin.readToEndAllocOptions(std.heap.page_allocator, std.math.maxInt(usize), null, 32, null);
        const leaves = std.mem.bytesAsSlice(F, bytes);
        for (leaves) |*leaf| leaf.to_montgomery();
        try tree.append(leaves);
        try std.io.getStdOut().writer().print("{x}\n", .{tree.root()});
    }
}
