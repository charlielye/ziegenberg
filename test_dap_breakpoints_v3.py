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
    """Test breakpoint functionality with event monitoring."""
    print("=== Testing DAP Breakpoint Events ===")
    
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
    events_thread = None
    stop_events = False
    
    def monitor_events():
        """Monitor for events in a separate thread."""
        while not stop_events:
            try:
                msg = read_dap_response(process.stdout)
                if msg and msg.get('type') == 'event':
                    event_type = msg.get('event')
                    print(f"\n[EVENT] {event_type}")
                    if event_type == 'breakpoint':
                        body = msg.get('body', {})
                        reason = body.get('reason', 'unknown')
                        bps = body.get('breakpoints', [])
                        print(f"  Reason: {reason}")
                        for bp in bps:
                            line = bp.get('line', '?')
                            msg_text = bp.get('message', '')
                            print(f"  - Line {line}: {msg_text if msg_text else 'verified'}")
                    elif event_type == 'stopped':
                        body = msg.get('body', {})
                        reason = body.get('reason', 'unknown')
                        print(f"  Reason: {reason}")
            except:
                pass
            time.sleep(0.01)
    
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
        print(f"\n>> Sent {command} request (seq={seq})")
        seq += 1
        time.sleep(0.1)  # Give it time to process
        
        # Read response
        response = read_dap_response(process.stdout)
        if response:
            success = response.get('success', False)
            status = 'SUCCESS' if success else 'FAILED'
            print(f"<< Response: {status}")
            return response
        return None
    
    try:
        # Initialize
        print("\n=== Initialization ===")
        resp = send_request("initialize", {
            "clientID": "test",
            "clientName": "Test Client",
            "adapterID": "ziegenberg",
            "linesStartAt1": True,
            "columnsStartAt1": True
        })
        
        # Wait for initialized event
        event = read_dap_response(process.stdout)
        print(f"<< Event: {event.get('event')}")
        
        # Start event monitoring thread after initialization
        events_thread = threading.Thread(target=monitor_events)
        events_thread.daemon = True
        events_thread.start()
        
        # Set breakpoints on comment lines BEFORE launching
        print("\n=== Setting breakpoints (before launch) ===")
        resp = send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # Comment line
                {"line": 8},   # Comment line
                {"line": 11},  # Comment line
            ]
        })
        
        if resp and 'body' in resp:
            print("Initial breakpoint response:")
            for bp in resp['body'].get('breakpoints', []):
                print(f"  - Line {bp.get('line')}: verified={bp.get('verified')}")
        
        # Launch - this should trigger breakpoint validation
        print("\n=== Launching ===")
        send_request("launch", {})
        
        # Give time for any breakpoint events
        time.sleep(0.2)
        
        # Configuration done
        send_request("configurationDone", {})
        
        # Let it run for a bit to catch events
        time.sleep(1)
        
        # Continue from entry
        send_request("continue", {"threadId": 1})
        
        # Wait a bit for breakpoint hits
        time.sleep(1)
        
        # Disconnect
        print("\n=== Disconnecting ===")
        send_request("disconnect", {})
        
        # Stop event monitoring
        stop_events = True
        
        # Give it time to clean up
        time.sleep(0.5)
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        stop_events = True
        # Ensure process is terminated
        process.terminate()
        process.wait()
    
    print("\n=== Test Complete ===")

if __name__ == "__main__":
    test_breakpoints()