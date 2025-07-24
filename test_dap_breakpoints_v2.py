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
    """Test breakpoint functionality with line adjustment."""
    print("=== Testing DAP Breakpoint Line Adjustment ===")
    
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
        
        # Launch first to ensure debug info is loaded
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        print(f"<< Received: {response['type']} - launch")
        
        # Configuration done
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        print(f"<< Received: {response['type']} - configurationDone")
        
        # Wait for initial stopped event
        event = read_dap_response(process.stdout)
        print(f"<< Received: {event['type']} - {event.get('event')}")
        
        # Now set breakpoints AFTER debug info is available
        print("\n=== Setting breakpoints on comment lines ===")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # Comment: "// Line 5: First computation"
                {"line": 8},   # Comment: "// Line 8: Double the result"
                {"line": 11},  # Comment: "// Line 11: Add 10"
                {"line": 14},  # Comment: "// Line 14: Final computation"
                {"line": 17},  # Comment: "// Line 17: Return"
                {"line": 1},   # Comment at top of file
                {"line": 3},   # Empty line
                {"line": 22},  # Comment in main function
                {"line": 100}, # Non-existent line
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        if response and 'body' in response and 'breakpoints' in response['body']:
            print("\nBreakpoint verification results:")
            for i, bp in enumerate(response['body']['breakpoints']):
                requested_line = [5, 8, 11, 14, 17, 1, 3, 22, 100][i]
                actual_line = bp.get('line', '?')
                verified = '✓' if bp.get('verified') else '✗'
                msg = bp.get('message', '')
                
                if msg:
                    print(f"  - Requested line {requested_line} -> Line {actual_line}: {verified} ({msg})")
                else:
                    print(f"  - Requested line {requested_line} -> Line {actual_line}: {verified}")
        
        # Now test breakpoints on actual code lines
        print("\n=== Setting breakpoints on code lines ===")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 6},   # let mut result = x + y;
                {"line": 9},   # result = result * 2;
                {"line": 12},  # result = result + 10;
                {"line": 15},  # result = result - 5;
                {"line": 18},  # result (return statement)
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        if response and 'body' in response and 'breakpoints' in response['body']:
            print("\nBreakpoint verification results:")
            for i, bp in enumerate(response['body']['breakpoints']):
                requested_line = [6, 9, 12, 15, 18][i]
                actual_line = bp.get('line', '?')
                verified = '✓' if bp.get('verified') else '✗'
                msg = bp.get('message', '')
                
                print(f"  - Line {requested_line}: {verified} {msg}")
        
        # Continue execution and see where we stop
        print("\n=== Continuing execution ===")
        send_request("continue", {"threadId": 1})
        response = read_dap_response(process.stdout)
        
        # Wait for stopped events
        stopped_count = 0
        max_stops = 5
        
        while stopped_count < max_stops:
            event = read_dap_response(process.stdout)
            if not event:
                break
                
            if event.get('type') == 'event' and event.get('event') == 'stopped':
                reason = event.get('body', {}).get('reason', 'unknown')
                print(f"\n!!! Stopped: {reason}")
                stopped_count += 1
                
                # Get stack trace to see where we stopped
                send_request("stackTrace", {"threadId": 1})
                response = read_dap_response(process.stdout)
                if response and 'body' in response and 'stackFrames' in response['body']:
                    for frame in response['body']['stackFrames'][:1]:  # Just show top frame
                        print(f"    At line {frame.get('line')}")
                
                # Continue
                if stopped_count < max_stops:
                    send_request("continue", {"threadId": 1})
                    response = read_dap_response(process.stdout)
        
        # Disconnect
        print("\n=== Disconnecting ===")
        send_request("disconnect", {})
        
        # Give it time to clean up
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
    test_breakpoints()