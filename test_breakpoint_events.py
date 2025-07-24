#!/usr/bin/env python3

import subprocess
import json
import time
import sys
import threading
import queue

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

def test_breakpoint_events():
    """Test that breakpoint events are sent when VM starts."""
    print("=== Testing Breakpoint Events ===\n")
    
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
    events = queue.Queue()
    stop_monitor = False
    
    def monitor_events():
        """Monitor all DAP messages in a separate thread."""
        while not stop_monitor:
            try:
                msg = read_dap_response(process.stdout)
                if msg:
                    events.put(msg)
            except:
                pass
    
    # Start event monitor thread
    event_thread = threading.Thread(target=monitor_events)
    event_thread.daemon = True
    event_thread.start()
    
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
        time.sleep(0.1)
    
    def get_next_message(timeout=1.0):
        """Get next message from queue."""
        try:
            return events.get(timeout=timeout)
        except queue.Empty:
            return None
    
    try:
        # Initialize
        send_request("initialize", {
            "clientID": "test",
            "clientName": "Test Client",
            "adapterID": "ziegenberg",
            "linesStartAt1": True,
            "columnsStartAt1": True,
            "supportsVariableType": True,
            "supportsVariablePaging": True,
            "supportsRunInTerminalRequest": True,
            "locale": "en-US"
        })
        
        # Read responses
        msg = get_next_message()
        print(f"<< {msg['type']}: {msg.get('command', msg.get('event', ''))}")
        
        msg = get_next_message()
        print(f"<< {msg['type']}: {msg.get('event', '')}")
        
        # Set breakpoints on comment lines
        print("\n=== Setting breakpoints on comment lines ===")
        send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # Comment
                {"line": 8},   # Comment
            ]
        })
        
        msg = get_next_message()
        print(f"<< setBreakpoints response")
        
        # Launch - this should trigger VM creation and breakpoint validation
        print("\n=== Launching (this creates the VM) ===")
        send_request("launch", {})
        
        # Wait for launch response
        msg = get_next_message()
        print(f"<< {msg['type']}: launch")
        
        # Send configuration done to complete initialization
        send_request("configurationDone", {})
        
        # Collect all messages for a bit
        print("\n=== Monitoring for breakpoint events ===")
        time.sleep(1.0)
        
        breakpoint_events = []
        while True:
            msg = get_next_message(timeout=0.1)
            if not msg:
                break
            
            msg_type = msg.get('type')
            if msg_type == 'event':
                event = msg.get('event')
                print(f"<< event: {event}")
                
                if event == 'breakpoint':
                    body = msg.get('body', {})
                    reason = body.get('reason', '')
                    bp = body.get('breakpoint', {})
                    line = bp.get('line', '?')
                    message = bp.get('message', '')
                    print(f"   Breakpoint event: {reason} - Line {line}")
                    if message:
                        print(f"   Message: {message}")
                    breakpoint_events.append(msg)
            else:
                print(f"<< {msg_type}: {msg.get('command', msg.get('event', ''))}")
        
        print(f"\n=== Summary ===")
        print(f"Received {len(breakpoint_events)} breakpoint events")
        
        if len(breakpoint_events) > 0:
            print("\n✓ SUCCESS: Breakpoint events are being sent!")
            for event in breakpoint_events:
                bp = event['body']['breakpoint']
                print(f"  - Line {bp.get('line')}: {bp.get('message', 'verified')}")
        else:
            print("\n✗ No breakpoint events received")
            print("  VSCode might not see the adjusted breakpoints until a new breakpoint is set")
        
        # Cleanup
        send_request("disconnect", {})
        stop_monitor = True
        time.sleep(0.5)
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        stop_monitor = True
        process.terminate()
        process.wait()
    
    print("\n=== Test Complete ===")

if __name__ == "__main__":
    test_breakpoint_events()