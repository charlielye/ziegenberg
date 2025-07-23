const { spawn } = require('child_process');
const path = require('path');

// Spawn the debug adapter
const adapter = spawn('node', [path.join(__dirname, 'out/debugAdapter.js')], {
    stdio: ['pipe', 'pipe', 'inherit']
});

let buffer = Buffer.alloc(0);
let contentLength = -1;

adapter.stdout.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    
    while (true) {
        if (contentLength === -1) {
            const headerEnd = buffer.indexOf('\r\n\r\n');
            if (headerEnd === -1) break;
            
            const header = buffer.toString('utf8', 0, headerEnd);
            const match = header.match(/Content-Length: (\d+)/);
            if (!match) break;
            
            contentLength = parseInt(match[1]);
            buffer = buffer.slice(headerEnd + 4);
        }
        
        if (buffer.length >= contentLength) {
            const message = buffer.slice(0, contentLength).toString('utf8');
            buffer = buffer.slice(contentLength);
            contentLength = -1;
            
            console.log('RECEIVED:', JSON.parse(message));
        } else {
            break;
        }
    }
});

function sendMessage(message) {
    const json = JSON.stringify(message);
    const header = `Content-Length: ${Buffer.byteLength(json)}\r\n\r\n`;
    adapter.stdin.write(header + json);
    console.log('SENT:', message);
}

// Test sequence
setTimeout(() => {
    sendMessage({
        seq: 1,
        type: 'request',
        command: 'initialize',
        arguments: {
            adapterID: 'noir',
            linesStartAt1: true,
            columnsStartAt1: true
        }
    });
}, 100);

setTimeout(() => {
    const artifactPath = process.argv[2] || './test.json';
    const zbPath = process.argv[3] || 'zb';
    const cwd = process.argv[4] || process.cwd();
    console.log('Launch args:', { artifactPath, zbPath, cwd });
    sendMessage({
        seq: 2,
        type: 'request',
        command: 'launch',
        arguments: {
            artifactPath: artifactPath,
            zbPath: zbPath,
            cwd: cwd
        }
    });
}, 500);

setTimeout(() => {
    sendMessage({
        seq: 3,
        type: 'request',
        command: 'configurationDone'
    });
}, 800);

setTimeout(() => {
    sendMessage({
        seq: 4,
        type: 'request',
        command: 'threads'
    });
}, 1000);

setTimeout(() => {
    sendMessage({
        seq: 5,
        type: 'request',
        command: 'continue',
        arguments: { threadId: 1 }
    });
}, 1500);

setTimeout(() => {
    sendMessage({
        seq: 6,
        type: 'request',
        command: 'disconnect'
    });
    setTimeout(() => process.exit(0), 1000);
}, 5000);