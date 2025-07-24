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

def test_breakpoint_ids():
    """Test breakpoint IDs in initial response and events."""
    print("=== Testing Breakpoint IDs ===\n")
    
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
        return seq - 1
    
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
        
        # Set breakpoints on comment lines
        print("=== Setting breakpoints ===")
        print("Requesting breakpoints on lines 5 and 8 (comment lines)")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # First breakpoint
                {"line": 8},   # Second breakpoint
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        print("\nInitial setBreakpoints response:")
        if response and 'body' in response and 'breakpoints' in response['body']:
            for bp in response['body']['breakpoints']:
                print(f"  ID={bp.get('id')}, Line={bp.get('line')}, Verified={bp.get('verified')}")
        
        # Launch and configuration
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        
        # Read all events
        print("\n=== Monitoring events after launch ===")
        events = []
        time.sleep(0.5)
        
        while True:
            msg = read_dap_response(process.stdout)
            if not msg:
                break
            
            if msg.get('type') == 'event':
                event_type = msg.get('event')
                if event_type == 'breakpoint':
                    body = msg.get('body', {})
                    bp = body.get('breakpoint', {})
                    print(f"\nBreakpoint event:")
                    print(f"  Reason: {body.get('reason')}")
                    print(f"  ID={bp.get('id')}, Line={bp.get('line')}")
                    print(f"  Message: {bp.get('message', 'none')}")
                    events.append(msg)
                elif event_type == 'stopped':
                    print(f"\nStopped event: {msg.get('body', {}).get('reason')}")
        
        print(f"\n=== Summary ===")
        print(f"Total breakpoint events received: {len(events)}")
        
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
    test_breakpoint_ids()