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
    """Final test of breakpoint line adjustment feature."""
    print("=== Testing Breakpoint Line Adjustment Feature ===\n")
    print("This test verifies that breakpoints set on comment lines")
    print("are automatically moved to the next line with opcodes.\n")
    
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
        print(f">> {command}")
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
        
        # Wait for responses
        response = read_dap_response(process.stdout)
        event = read_dap_response(process.stdout)
        
        # Set breakpoints on comment and empty lines
        print("\n=== Setting breakpoints before program starts ===")
        print("Requesting breakpoints on:")
        print("  - Line 8 (comment line)")
        print("  - Line 11 (comment line)")  
        print("  - Line 14 (comment line)")
        
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 8},   # Comment: should move to line 9
                {"line": 11},  # Comment: should move to line 12
                {"line": 14},  # Comment: should move to line 15
            ]
        })
        
        # Read setBreakpoints response
        response = read_dap_response(process.stdout)
        
        # Launch and configuration
        send_request("launch", {})
        response = read_dap_response(process.stdout)
        
        send_request("configurationDone", {})
        response = read_dap_response(process.stdout)
        
        # Wait for stopped event (entry)
        event = read_dap_response(process.stdout)
        print(f"\n<< Stopped at entry (line 6)")
        
        # Continue and track where we stop
        print("\n=== Running program and tracking breakpoint hits ===")
        breakpoint_hits = []
        
        for i in range(3):  # Expect 3 breakpoint hits
            send_request("continue", {"threadId": 1})
            response = read_dap_response(process.stdout)
            
            # Wait for stopped event
            timeout = 0
            while timeout < 50:  # 5 second timeout
                event = read_dap_response(process.stdout)
                if event and event.get('type') == 'event' and event.get('event') == 'stopped':
                    # Get stack trace to see actual line
                    send_request("stackTrace", {"threadId": 1})
                    response = read_dap_response(process.stdout)
                    if response and 'body' in response and 'stackFrames' in response['body']:
                        frame = response['body']['stackFrames'][0]
                        line = frame.get('line')
                        breakpoint_hits.append(line)
                        print(f"<< Stopped at line {line}")
                    break
                elif event:
                    print(f"<< Got unexpected message: {event.get('type')} - {event.get('command', event.get('event', ''))}")
                time.sleep(0.1)
                timeout += 1
        
        # Final results
        print("\n=== Results ===")
        print("Breakpoints were requested on comment lines: 8, 11, 14")
        print(f"Program actually stopped at code lines: {breakpoint_hits}")
        
        expected = [9, 12, 15]
        if breakpoint_hits == expected:
            print("\n✓ SUCCESS: Breakpoint line adjustment is working correctly!")
            print("  Comment lines were automatically adjusted to the next code lines.")
        else:
            print("\n✗ FAILED: Unexpected breakpoint behavior")
        
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