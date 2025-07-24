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

def test_breakpoints():
    """Test breakpoint functionality."""
    print("=== Testing DAP Breakpoint Support ===")
    
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
        print(f">> Sent {command} request (seq={seq})")
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
        print(f"<< Received: {response['type']} - {response.get('command', response.get('event', ''))}")
        
        # Wait for initialized event
        event = read_dap_response(process.stdout)
        print(f"<< Received: {event['type']} - {event.get('event', '')}")
        
        # Set breakpoints on lines with debug_log statements
        print("\n=== Setting breakpoints ===")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # Comment line - should move to line 6
                {"line": 6},   # let mut result = x + y
                {"line": 8},   # Comment line - should move to line 9  
                {"line": 9},   # result = result * 2
                {"line": 11},  # Comment line - should move to line 12
                {"line": 12},  # result = result + 10
                {"line": 14},  # Comment line - should move to line 15
                {"line": 15},  # result = result - 5
                {"line": 17},  # Comment line - should move to line 18
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        if response and 'body' in response and 'breakpoints' in response['body']:
            print("Breakpoints verified:")
            for bp in response['body']['breakpoints']:
                status = '✓' if bp.get('verified') else '✗'
                msg = f" - {bp.get('message')}" if bp.get('message') else ""
                print(f"  - Line {bp.get('line')}: {status}{msg}")
        
        # Launch
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        print(f"<< Received: {response['type']} - launch")
        
        # Configuration done
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        print(f"<< Received: {response['type']} - configurationDone")
        
        # Wait for stopped event
        print("\n=== Waiting for stopped events ===")
        stopped_count = 0
        max_stops = 5  # Don't wait forever
        
        while stopped_count < max_stops:
            event = read_dap_response(process.stdout)
            if not event:
                break
                
            if event.get('type') == 'event' and event.get('event') == 'stopped':
                reason = event.get('body', {}).get('reason', 'unknown')
                print(f"\n!!! Stopped: {reason}")
                stopped_count += 1
                
                # Get stack trace
                send_request("stackTrace", {"threadId": 1})
                response = read_dap_response(process.stdout)
                if response and 'body' in response and 'stackFrames' in response['body']:
                    print("Stack trace:")
                    for frame in response['body']['stackFrames']:
                        print(f"  - {frame.get('name')} at line {frame.get('line')}")
                
                # Continue execution
                if reason in ['breakpoint', 'entry']:
                    print("Continuing from " + reason + "...")
                    send_request("continue", {"threadId": 1})
                    response = read_dap_response(process.stdout)
                else:
                    break
        
        # Disconnect
        print("\n=== Disconnecting ===")
        send_request("disconnect", {})
        
        # Give it time to clean up
        time.sleep(0.5)
        
    except Exception as e:
        print(f"Error: {e}")
    finally:
        # Ensure process is terminated
        process.terminate()
        process.wait()
    
    print("\n=== Test Complete ===")

if __name__ == "__main__":
    test_breakpoints()