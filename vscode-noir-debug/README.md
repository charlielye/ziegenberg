# Noir VSCode Debugger

This is a minimal VSCode extension that enables step-by-step debugging of Noir code using the Ziegenberg execution engine.

## Features

- Step-by-step debugging through Noir source code
- Source location display with line highlighting
- Basic execution control (Continue, Step Over, Step Into)
- Stack trace display

## Setup

1. Build the Ziegenberg project:
   ```bash
   zig build build-exe -freference-trace
   ```

2. Build the VSCode extension:
   ```bash
   cd vscode-noir-debug
   npm install
   npm run compile

   # Install vsce globally if not already installed
   npm install -g vsce

   # Create the VSIX package
   npm run package
   ```

   This will create a `noir-debug-0.0.1.vsix` file.

3. Install the extension in VSCode:
   - Open VSCode
   - Go to Extensions view (Ctrl+Shift+X)
   - Click "..." menu and select "Install from VSIX..."
   - Or copy the extension folder to `~/.vscode/extensions/`

## Usage

1. Create a launch configuration in your Noir project's `.vscode/launch.json`:
   ```json
   {
     "version": "0.2.0",
     "configurations": [
       {
         "type": "noir",
         "request": "launch",
         "name": "Debug Noir Contract",
         "artifactPath": "${workspaceFolder}/target/contract.json",
         "zbPath": "/path/to/zb"
       }
     ]
   }
   ```

2. Set breakpoints in your Noir source files (currently breakpoints are not implemented, debugger always starts paused)

3. Press F5 to start debugging

## Current Limitations

- No breakpoint support (always starts paused at first line)
- No variable inspection
- No watch expressions
- Single-threaded debugging only
- Step Into behaves the same as Step Over

## Architecture

The debugger uses the Debug Adapter Protocol (DAP) to communicate between VSCode and the Ziegenberg execution engine:

1. VSCode Extension (`src/extension.ts`) - Registers the debug adapter
2. Debug Adapter (`src/debugAdapter.ts`) - Spawns zb process and translates DAP messages
3. Ziegenberg DAP Server (`src/debugger/dap.zig`) - Implements DAP protocol in the execution engine
4. Debug Context (`src/bvm/debug_context.zig`) - Controls execution and sends debug events
