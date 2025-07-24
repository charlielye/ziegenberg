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
    """Test that breakpoints set on comment lines work correctly."""
    print("=== Testing Breakpoint Line Validation ===\n")
    
    # Source file structure:
    # Line 5: comment "// Line 5: First computation"
    # Line 6: code "let mut result = x + y;"
    # Line 8: comment "// Line 8: Double the result"
    # Line 9: code "result = result * 2;"
    
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
        
        # Set breakpoints on COMMENT LINES before launch
        print("\n=== Setting breakpoints on comment lines (before VM exists) ===")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # Comment: should move to line 6
                {"line": 8},   # Comment: should move to line 9
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        print("\nBreakpoints accepted (VM not loaded yet):")
        if response and 'body' in response and 'breakpoints' in response['body']:
            for bp in response['body']['breakpoints']:
                print(f"  - Line {bp.get('line')}: verified={bp.get('verified')}")
        
        # Launch and configuration
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        
        # Wait for stopped event (entry)
        event = read_dap_response(process.stdout)
        print(f"\n<< Event: {event.get('event')} - {event.get('body', {}).get('reason', '')}")
        
        # Continue and see where we stop
        print("\n=== Running program to test breakpoints ===")
        send_request("continue", {"threadId": 1})
        response = read_dap_response(process.stdout)
        
        # We should stop at line 6 (not 5) and line 9 (not 8)
        breakpoint_hits = []
        for i in range(2):  # Expect 2 breakpoint hits
            event = read_dap_response(process.stdout)
            if event and event.get('type') == 'event' and event.get('event') == 'stopped':
                reason = event.get('body', {}).get('reason', '')
                print(f"\n!!! Stopped: {reason}")
                
                # Get stack trace to see actual line
                send_request("stackTrace", {"threadId": 1})
                response = read_dap_response(process.stdout)
                if response and 'body' in response and 'stackFrames' in response['body']:
                    frame = response['body']['stackFrames'][0]
                    line = frame.get('line')
                    breakpoint_hits.append(line)
                    print(f"    Stopped at line: {line}")
                
                # Continue
                send_request("continue", {"threadId": 1})
                response = read_dap_response(process.stdout)
        
        # Verify results
        print("\n=== Test Results ===")
        print(f"Breakpoints were set on comment lines 5 and 8")
        print(f"Program actually stopped at lines: {breakpoint_hits}")
        
        expected = [6, 9]  # Where we expect to stop
        if breakpoint_hits == expected:
            print("✓ SUCCESS: Breakpoints were automatically moved to code lines!")
        else:
            print("✗ FAILED: Breakpoints did not move to expected lines")
        
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
    test_breakpoints()