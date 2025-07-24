#!/usr/bin/env python3

import subprocess
import json
import time
import sys
import threading

def create_dap_message(obj):
    """Create a DAP protocol message with Content-Length header."""
    json_str = json.dumps(obj)
    content_length = len(json_str.encode('utf-8'))
    return f"Content-Length: {content_length}\r\n\r\n{json_str}"

def read_dap_response(stdout):
    """Read a DAP response from stdout."""
    # Read Content-Length header
    header = stdout.readline().decode('utf-8')
    if not header.startswith('Content-Length:'):
        return None
    
    content_length = int(header.split(':')[1].strip())
    
    # Read empty line
    stdout.readline()
    
    # Read JSON body
    json_body = stdout.read(content_length).decode('utf-8')
    return json.loads(json_body)

def monitor_output(process):
    """Monitor stderr for debug output."""
    for line in process.stderr:
        print(f"[DEBUG] {line.decode('utf-8').rstrip()}")

def test_entry_line():
    """Test what line we're at when we first stop."""
    print("=== Testing Entry Line ===\n")
    
    # Start the debugger process
    cmd = [
        './zig-out/bin/zb', 'cvm', 'run',
        '--artifact_path', './simple_test/target/simple_test.json',
        '--calldata_path', './simple_test/Prover.toml',
        '--debug-dap'
    ]
    
    process = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    
    # Start stderr monitor thread
    stderr_thread = threading.Thread(target=monitor_output, args=(process,))
    stderr_thread.daemon = True
    stderr_thread.start()
    
    seq = 1
    
    def send_request(command, arguments=None):
        nonlocal seq
        request = {
            "seq": seq,
            "type": "request",
            "command": command
        }
        if arguments:
            request["arguments"] = arguments
        
        msg = create_dap_message(request)
        process.stdin.write(msg.encode('utf-8'))
        process.stdin.flush()
        seq += 1
        time.sleep(0.1)  # Give it time to process
    
    try:
        # Initialize
        send_request("initialize", {
            "clientID": "test",
            "clientName": "Test Client",
            "adapterID": "ziegenberg",
            "linesStartAt1": True,
            "columnsStartAt1": True
        })
        
        # Wait for initialize response
        response = read_dap_response(process.stdout)
        
        # Wait for initialized event
        event = read_dap_response(process.stdout)
        
        # Launch and configuration
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        
        # Wait for stopped event (entry)
        event = read_dap_response(process.stdout)
        print(f"Stopped at: {event.get('body', {}).get('reason', '')}")
        
        # Get stack trace to see where we are
        send_request("stackTrace", {"threadId": 1})
        response = read_dap_response(process.stdout)
        if response and 'body' in response and 'stackFrames' in response['body']:
            frame = response['body']['stackFrames'][0]
            line = frame.get('line')
            source = frame.get('source', {}).get('name', 'unknown')
            print(f"\nEntry point is at line {line} in {source}")
            print("\nThis explains why we don't hit the breakpoint at line 6 -")
            print("we're already past it when the program starts!")
        
        # Disconnect
        send_request("disconnect", {})
        time.sleep(0.5)
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        # Ensure process is terminated
        process.terminate()
        process.wait()
    
    print("\n=== Test Complete ===")

if __name__ == "__main__":
    test_entry_line()