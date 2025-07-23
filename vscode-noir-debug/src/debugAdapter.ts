import { spawn, ChildProcess } from 'child_process';

interface DAPMessage {
    seq?: number;
    type: 'request' | 'response' | 'event';
    command?: string;
    request_seq?: number;
    success?: boolean;
    event?: string;
    body?: any;
    arguments?: any;  // For requests
}

class NoirDebugAdapter {
    private zbProcess: ChildProcess | null = null;
    private seq = 1;
    private buffer = Buffer.alloc(0);
    private contentLength = -1;
    private isShuttingDown = false;

    constructor() {
        // Don't set any encoding - we want raw buffers
        // process.stdin.setEncoding(null);
        
        // Handle stdin data
        process.stdin.on('data', (chunk: Buffer | string) => {
            this.handleStdinData(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
        });

        process.stdin.on('end', () => {
            this.shutdown();
        });
    }

    private handleStdinData(chunk: Buffer) {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        
        while (true) {
            if (this.contentLength === -1) {
                // Look for Content-Length header
                const headerEnd = this.buffer.indexOf('\r\n\r\n');
                if (headerEnd === -1) break;

                const header = this.buffer.toString('utf8', 0, headerEnd);
                const match = header.match(/Content-Length: (\d+)/);
                if (!match) {
                    console.error('Invalid header:', header);
                    break;
                }

                this.contentLength = parseInt(match[1]);
                this.buffer = this.buffer.slice(headerEnd + 4);
            }

            if (this.buffer.length >= this.contentLength) {
                // We have a complete message
                const messageBuffer = this.buffer.slice(0, this.contentLength);
                this.buffer = this.buffer.slice(this.contentLength);
                this.contentLength = -1;

                try {
                    const message = JSON.parse(messageBuffer.toString('utf8')) as DAPMessage;
                    this.processMessage(message);
                } catch (e) {
                    console.error('Failed to parse message:', e);
                }
            } else {
                // Wait for more data
                break;
            }
        }
    }

    private processMessage(message: DAPMessage) {
        if (message.type === 'request') {
            switch (message.command) {
                case 'initialize':
                    this.handleInitialize(message);
                    break;
                case 'launch':
                    this.handleLaunch(message);
                    break;
                case 'disconnect':
                    this.handleDisconnect(message);
                    break;
                default:
                    // Forward to zb process if running
                    if (this.zbProcess && this.zbProcess.stdin) {
                        this.sendToZb(message);
                    } else {
                        this.sendErrorResponse(message, 'Debug session not started');
                    }
            }
        }
    }

    private handleInitialize(request: DAPMessage) {
        // No zb process yet, handle initialization ourselves
        // Send response immediately
        this.sendResponse(request, {
            supportsConfigurationDoneRequest: true,
            supportsFunctionBreakpoints: false,
            supportsConditionalBreakpoints: false,
            supportsEvaluateForHovers: false,
            supportsStepBack: false,
            supportsSetVariable: false,
            supportsRestartFrame: false,
            supportsTerminateRequest: true
        });

        // Send initialized event
        this.sendEvent('initialized', {});
    }

    private handleLaunch(request: DAPMessage) {
        const args = request.arguments || request.body || {};
        const artifactPath = args.artifactPath;
        const zbPath = args.zbPath || 'zb';
        const cwd = args.cwd || process.cwd();

        if (!artifactPath) {
            this.sendErrorResponse(request, 'artifactPath is required');
            return;
        }


        // Spawn zb process
        this.zbProcess = spawn(zbPath, ['txe', artifactPath, '--debug-dap'], {
            stdio: ['pipe', 'pipe', 'pipe'],
            cwd: cwd
        });

        this.zbProcess.on('error', (err) => {
            console.error('Failed to start zb:', err);
            this.sendErrorResponse(request, `Failed to start zb: ${err.message}`);
        });

        this.zbProcess.on('exit', (code) => {
            if (!this.isShuttingDown) {
                this.sendEvent('output', {
                    category: 'console',
                    output: `\nDebug session ended with code ${code}\n`
                });
                this.sendEvent('terminated', {});
            }
            this.zbProcess = null;
        });

        // Handle zb stdout (DAP messages)
        let zbBuffer = Buffer.alloc(0);
        let zbContentLength = -1;

        this.zbProcess.stdout?.on('data', (chunk: Buffer) => {
            zbBuffer = Buffer.concat([zbBuffer, chunk]);
            
            while (true) {
                if (zbContentLength === -1) {
                    const headerEnd = zbBuffer.indexOf('\r\n\r\n');
                    if (headerEnd === -1) break;

                    const header = zbBuffer.toString('utf8', 0, headerEnd);
                    const match = header.match(/Content-Length: (\d+)/);
                    if (!match) break;

                    zbContentLength = parseInt(match[1]);
                    zbBuffer = zbBuffer.slice(headerEnd + 4);
                }

                if (zbBuffer.length >= zbContentLength) {
                    const messageBuffer = zbBuffer.slice(0, zbContentLength);
                    zbBuffer = zbBuffer.slice(zbContentLength);
                    zbContentLength = -1;

                    try {
                        const message = JSON.parse(messageBuffer.toString('utf8')) as DAPMessage;
                        
                        // Filter out initialize response and initialized event from zb
                        // since we already sent these
                        if ((message.type === 'response' && message.command === 'initialize') ||
                            (message.type === 'event' && message.event === 'initialized')) {
                            // Don't forward these
                        } else {
                            // Forward complete message to VSCode
                            const header = `Content-Length: ${messageBuffer.length}\r\n\r\n`;
                            process.stdout.write(header);
                            process.stdout.write(messageBuffer);
                        }
                    } catch (e) {
                        // If we can't parse, just forward it
                        const header = `Content-Length: ${messageBuffer.length}\r\n\r\n`;
                        process.stdout.write(header);
                        process.stdout.write(messageBuffer);
                    }
                } else {
                    break;
                }
            }
        });

        // Handle zb stderr (debug output)
        this.zbProcess.stderr?.on('data', (data: Buffer) => {
            const text = data.toString('utf8');
            const lines = text.split('\n');
            for (const line of lines) {
                if (line.trim()) {
                    this.sendEvent('output', {
                        category: 'console',
                        output: line + '\n'
                    });
                }
            }
        });

        // Send launch response
        this.sendResponse(request, {});

        // Send initialize request to zb
        this.sendToZb({
            seq: this.seq++,
            type: 'request',
            command: 'initialize',
            arguments: {
                adapterID: 'noir',
                linesStartAt1: true,
                columnsStartAt1: true
            }
        });
    }

    private handleDisconnect(request: DAPMessage) {
        this.isShuttingDown = true;
        
        if (this.zbProcess) {
            // Don't forward disconnect to zb - just kill the process
            this.zbProcess.kill();
            this.zbProcess = null;
        }
        this.sendResponse(request, {});
        
        // Ensure we shut down cleanly
        setTimeout(() => {
            process.exit(0);
        }, 100);
    }

    private sendToZb(message: DAPMessage) {
        if (this.zbProcess && this.zbProcess.stdin) {
            const json = JSON.stringify(message);
            const header = `Content-Length: ${Buffer.byteLength(json)}\r\n\r\n`;
            this.zbProcess.stdin.write(header);
            this.zbProcess.stdin.write(json);
        }
    }

    private sendResponse(request: DAPMessage, body: any) {
        const response: DAPMessage = {
            seq: this.seq++,
            type: 'response',
            request_seq: request.seq,
            success: true,
            command: request.command,
            body: body
        };
        this.sendMessage(response);
    }

    private sendErrorResponse(request: DAPMessage, message: string) {
        const response: DAPMessage = {
            seq: this.seq++,
            type: 'response',
            request_seq: request.seq,
            success: false,
            command: request.command,
            body: { error: { message } }
        };
        this.sendMessage(response);
    }

    private sendEvent(event: string, body: any) {
        const message: DAPMessage = {
            seq: this.seq++,
            type: 'event',
            event: event,
            body: body
        };
        this.sendMessage(message);
    }

    private sendMessage(message: DAPMessage) {
        if (this.isShuttingDown) {
            return; // Don't send messages during shutdown
        }
        const json = JSON.stringify(message);
        const header = `Content-Length: ${Buffer.byteLength(json)}\r\n\r\n`;
        process.stdout.write(header);
        process.stdout.write(json);
    }

    private shutdown() {
        if (this.zbProcess) {
            this.zbProcess.kill();
        }
        process.exit(0);
    }
}

// Start the debug adapter
new NoirDebugAdapter();