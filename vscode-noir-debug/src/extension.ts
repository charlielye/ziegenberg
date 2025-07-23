import * as vscode from 'vscode';

export function activate(context: vscode.ExtensionContext) {
    // Register a factory for Noir debug adapters
    const factory = new NoirDebugAdapterDescriptorFactory();
    context.subscriptions.push(
        vscode.debug.registerDebugAdapterDescriptorFactory('noir', factory)
    );
}

export function deactivate() {}

class NoirDebugAdapterDescriptorFactory implements vscode.DebugAdapterDescriptorFactory {
    createDebugAdapterDescriptor(
        session: vscode.DebugSession,
        executable: vscode.DebugAdapterExecutable | undefined
    ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
        // Use the debug adapter script
        const command = 'node';
        const args = [__dirname + '/debugAdapter.js'];
        return new vscode.DebugAdapterExecutable(command, args);
    }
}