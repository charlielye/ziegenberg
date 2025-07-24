#!/usr/bin/env node

const net = require('net');
const fs = require('fs');
const path = require('path');

// DAP protocol messages
let sequenceNumber = 1;

function createMessage(obj) {
    const json = JSON.stringify(obj);
    const length = Buffer.byteLength(json, 'utf8');
    return `Content-Length: ${length}\r\n\r\n${json}`;
}

function sendRequest(client, command, args = {}) {
    const request = {
        seq: sequenceNumber++,
        type: 'request',
        command: command,
        arguments: args
    };
    client.write(createMessage(request));
    console.log(`>> Sent ${command} request`);
}

async function waitForResponse(client, expectedSeq) {
    return new Promise((resolve) => {
        const handler = (data) => {
            const lines = data.toString().split('\r\n');
            for (let i = 0; i < lines.length; i++) {
                if (lines[i].startsWith('Content-Length:')) {
                    const length = parseInt(lines[i].split(':')[1].trim());
                    const bodyStart = i + 2;
                    if (bodyStart < lines.length) {
                        const json = lines.slice(bodyStart).join('\r\n');
                        try {
                            const msg = JSON.parse(json);
                            console.log(`<< Received ${msg.type}: ${msg.command || msg.event || ''}`);
                            if (msg.type === 'response' && msg.request_seq === expectedSeq - 1) {
                                client.removeListener('data', handler);
                                resolve(msg);
                            }
                        } catch (e) {
                            // Partial message, continue
                        }
                    }
                }
            }
        };
        client.on('data', handler);
    });
}

// Test case details
const testArtifact = './aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/target/tests/Counter__extended_incrementing_and_decrementing_pass.json';

// Start the debugger process
const spawn = require('child_process').spawn;
const debuggerProcess = spawn('./zig-out/bin/zb', ['cvm', 'run', '--artifact_path', testArtifact, '--debug_dap']);

debuggerProcess.stderr.on('data', (data) => {
    console.error(`Debugger stderr: ${data}`);
});

// Give the process time to start
setTimeout(async () => {
    const client = net.createConnection({ port: 12345 }, async () => {
        console.log('Connected to DAP debugger');
        
        try {
            // Initialize
            sendRequest(client, 'initialize', {
                clientID: 'test-dap',
                clientName: 'Test DAP Client',
                adapterID: 'ziegenberg',
                pathFormat: 'path',
                linesStartAt1: true,
                columnsStartAt1: true
            });
            await waitForResponse(client, sequenceNumber);
            
            // Set breakpoints at lines 10, 15, and 20 of the counter contract
            // Note: In real usage, you'd need to find the actual source file path
            sendRequest(client, 'setBreakpoints', {
                source: {
                    path: '/mnt/user-data/charlie/ziegenberg/aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/src/main.nr'
                },
                breakpoints: [
                    { line: 10 },
                    { line: 15 },
                    { line: 20 },
                    { line: 25 }
                ]
            });
            const breakpointResponse = await waitForResponse(client, sequenceNumber);
            console.log('Breakpoints set:', JSON.stringify(breakpointResponse.body.breakpoints, null, 2));
            
            // Launch
            sendRequest(client, 'launch', {});
            await waitForResponse(client, sequenceNumber);
            
            // Configure done
            sendRequest(client, 'configurationDone', {});
            await waitForResponse(client, sequenceNumber);
            
            // Continue execution
            console.log('\n=== Continuing execution ===');
            sendRequest(client, 'continue', {});
            
            // Listen for stopped events
            client.on('data', (data) => {
                const lines = data.toString().split('\r\n');
                for (let i = 0; i < lines.length; i++) {
                    if (lines[i].startsWith('Content-Length:')) {
                        const bodyStart = i + 2;
                        if (bodyStart < lines.length) {
                            const json = lines.slice(bodyStart).join('\r\n');
                            try {
                                const msg = JSON.parse(json);
                                if (msg.type === 'event' && msg.event === 'stopped') {
                                    console.log(`\n!!! Stopped at breakpoint: ${msg.body.reason}`);
                                    
                                    // Get stack trace
                                    sendRequest(client, 'stackTrace', { threadId: 1 });
                                    
                                    // Continue after a pause
                                    setTimeout(() => {
                                        console.log('Continuing...');
                                        sendRequest(client, 'continue', {});
                                    }, 1000);
                                }
                            } catch (e) {
                                // Ignore
                            }
                        }
                    }
                }
            });
            
            // Disconnect after 30 seconds
            setTimeout(() => {
                console.log('\nDisconnecting...');
                sendRequest(client, 'disconnect', {});
                setTimeout(() => {
                    client.end();
                    debuggerProcess.kill();
                    process.exit(0);
                }, 1000);
            }, 30000);
            
        } catch (error) {
            console.error('Error:', error);
            client.end();
            debuggerProcess.kill();
        }
    });
    
    client.on('error', (err) => {
        console.error('Connection error:', err);
        debuggerProcess.kill();
    });
}, 2000);