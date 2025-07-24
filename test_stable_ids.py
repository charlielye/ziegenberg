#!/usr/bin/env python3

import subprocess
import json
import time
import sys

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

def test_stable_ids():
    """Test that breakpoint IDs remain stable."""
    print("=== Testing Stable Breakpoint IDs ===\n")
    
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
        time.sleep(0.1)
    
    try:
        # Initialize
        send_request("initialize", {
            "clientID": "test",
            "clientName": "Test Client",
            "adapterID": "ziegenberg",
            "linesStartAt1": True,
            "columnsStartAt1": True
        })
        
        # Read responses
        response = read_dap_response(process.stdout)
        event = read_dap_response(process.stdout)
        
        # Set breakpoints on lines 5 and 8
        print("Setting breakpoints on lines 5 and 8")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},
                {"line": 8},
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        print("\nInitial response:")
        if response and 'body' in response and 'breakpoints' in response['body']:
            for bp in response['body']['breakpoints']:
                print(f"  Line {bp.get('line')}: ID={bp.get('id')}")
        
        # Launch and configuration
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        
        # Collect events
        print("\n=== Breakpoint Events ===")
        events = []
        start_time = time.time()
        while time.time() - start_time < 2.0:
            msg = read_dap_response(process.stdout)
            if msg and msg.get('type') == 'event' and msg.get('event') == 'breakpoint':
                body = msg.get('body', {})
                bp = body.get('breakpoint', {})
                print(f"\nBreakpoint event:")
                print(f"  ID={bp.get('id')}")
                print(f"  Line {bp.get('line')}")
                print(f"  Message: {bp.get('message', 'none')}")
                events.append(msg)
            elif msg:
                # Skip other messages
                pass
        
        print(f"\n=== Summary ===")
        print(f"Received {len(events)} breakpoint events")
        print("\nExpected behavior:")
        print("- Line 5 (ID=5000) should move to line 6")
        print("- Line 8 (ID=8000) should move to line 9")
        print("- Both IDs should remain stable")
        
        # Disconnect
        send_request("disconnect", {})
        time.sleep(0.5)
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        process.terminate()
        process.wait()
    
    print("\n=== Test Complete ===")

if __name__ == "__main__":
    test_stable_ids()