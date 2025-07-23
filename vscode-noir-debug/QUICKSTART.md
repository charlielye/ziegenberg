# Quick Start Guide

## Building the Extension

1. **First time setup:**
   ```bash
   cd vscode-noir-debug
   npm install
   npm install -g vsce  # Only needed once
   ```

2. **Create the VSIX package:**
   ```bash
   npm run package
   # or
   make package
   ```

   This creates `noir-debug-0.0.1.vsix` in the current directory.

## Installing the Extension

### Option 1: Command Line
```bash
code --install-extension noir-debug-0.0.1.vsix
```

### Option 2: VSCode UI
1. Open VSCode
2. Go to Extensions (Ctrl+Shift+X)
3. Click the "..." menu at the top of the Extensions sidebar
4. Select "Install from VSIX..."
5. Browse to and select `noir-debug-0.0.1.vsix`

### Option 3: Development Mode
For development, you can also:
1. Copy the entire `vscode-noir-debug` folder to `~/.vscode/extensions/`
2. Restart VSCode

## Verifying Installation

1. Go to Extensions view in VSCode
2. Search for "Noir Debug"
3. You should see the extension listed

## First Debug Session

1. Open a Noir project in VSCode
2. Create `.vscode/launch.json`:
   ```json
   {
     "version": "0.2.0",
     "configurations": [
       {
         "type": "noir",
         "request": "launch",
         "name": "Debug Noir Test",
         "artifactPath": "${workspaceFolder}/path/to/your/test.json",
         "zbPath": "${workspaceFolder}/../ziegenberg/zig-out/bin/zb",
         "cwd": "${workspaceFolder}"
       }
     ]
   }
   ```
3. Press F5 to start debugging

The debugger will pause at the first line of execution. Use the debug controls to step through your code.