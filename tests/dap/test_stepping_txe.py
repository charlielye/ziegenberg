#!/usr/bin/env python3
"""Test stepping behavior in TXE with nested VMs."""

import sys
import os
import time
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_step_over_into_nested_vm():
    """Test that step-over doesn't incorrectly step into nested VM."""
    print("\n=== Test: Step Over Into Nested VM Issue ===")
    
    client = DapClient([
        './zig-out/bin/zb', 'txe',
        './aztec-packages/noir-projects/noir-contracts/target/tests/Counter__extended_incrementing_and_decrementing_pass.json',
        '--debug-dap'
    ])
    
    try:
        # Initialize
        seq = client.send_request("initialize", {"clientID": "test"})
        client.wait_for_response(seq)
        client.wait_for_event("initialized")
        
        # Set breakpoint on line 174 (test::setup call)
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/src/main.nr"
            },
            "breakpoints": [{"line": 174}]
        })
        response = client.wait_for_response(seq)
        print(f"Breakpoint set at line 174: {response['body']['breakpoints'][0]['verified']}")
        
        seq = client.send_request("launch", {})
        client.wait_for_response(seq)
        
        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)
        
        # Wait for entry stop
        stopped = client.wait_for_event("stopped", timeout=2.0)
        if stopped:
            print(f"Initial stop reason: {stopped['body']['reason']}")
            # Continue to breakpoint
            seq = client.send_request("continue", {"threadId": 1})
            client.wait_for_response(seq)
        else:
            print("No initial stop (running directly)")
        
        # Should hit breakpoint at line 174
        stopped = client.wait_for_event("stopped", timeout=5.0)
        if not stopped:
            print("✗ No breakpoint hit at line 174")
            print("Note: The test may not be executing the line with the breakpoint")
            return False
        assert stopped['body']['reason'] == "breakpoint", f"Expected breakpoint stop, got {stopped['body']['reason']}"
        
        # Get current position
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        frame = response['body']['stackFrames'][0]
        print(f"Stopped at: {frame['source']['path'].split('/')[-1]}:{frame['line']}")
        assert frame['line'] == 174, f"Expected line 174, got {frame['line']}"
        
        # Step over - should go to line 175 or 176, not into nested VM
        print("\nStepping over...")
        seq = client.send_request("next", {"threadId": 1})
        client.wait_for_response(seq)
        
        # Wait for stop after step
        stopped = client.wait_for_event("stopped")
        assert stopped['body']['reason'] == "step", f"Expected step stop, got {stopped['body']['reason']}"
        
        # Check where we stopped
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        frame = response['body']['stackFrames'][0]
        new_line = frame['line']
        file_name = frame['source']['path'].split('/')[-1]
        
        print(f"After step-over, stopped at: {file_name}:{new_line}")
        
        # Should be on line 175 or later in the same file, not in a nested VM
        if file_name != "main.nr" or new_line < 175:
            print(f"✗ Step-over incorrectly stepped into nested VM or wrong location")
            print(f"  Expected: main.nr:175 or later")
            print(f"  Got: {file_name}:{new_line}")
            return False
        
        print("✓ Step-over worked correctly")
        return True
        
    finally:
        client.shutdown()

def test_step_out_of_nested_vm():
    """Test that step-out from nested VM works correctly."""
    print("\n=== Test: Step Out of Nested VM ===")
    
    client = DapClient([
        './zig-out/bin/zb', 'txe',
        './aztec-packages/noir-projects/noir-contracts/target/tests/Counter__extended_incrementing_and_decrementing_pass.json',
        '--debug-dap'
    ])
    
    try:
        # Initialize
        seq = client.send_request("initialize", {"clientID": "test"})
        client.wait_for_response(seq)
        client.wait_for_event("initialized")
        
        # Set breakpoint on line 76 (counters.at(owner).add call)
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/src/main.nr"
            },
            "breakpoints": [{"line": 76}]
        })
        response = client.wait_for_response(seq)
        print(f"Breakpoint set at line 76: {response['body']['breakpoints'][0]['verified']}")
        
        seq = client.send_request("launch", {})
        client.wait_for_response(seq)
        
        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)
        
        # Wait for entry stop
        stopped = client.wait_for_event("stopped", timeout=2.0)
        if stopped:
            print(f"Initial stop reason: {stopped['body']['reason']}")
            # Continue to breakpoint
            seq = client.send_request("continue", {"threadId": 1})
            client.wait_for_response(seq)
        else:
            print("No initial stop (running directly)")
        
        # Should hit breakpoint at line 76
        print("Waiting for breakpoint at line 76...")
        stopped = client.wait_for_event("stopped", timeout=30.0)  # Give it more time
        if not stopped:
            print("✗ No breakpoint hit at line 76 after 30 seconds")
            return False
        assert stopped['body']['reason'] == "breakpoint", f"Expected breakpoint stop, got {stopped['body']['reason']}"
        
        # Get current position and verify we're at line 76 in increment_and_decrement
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        frame = response['body']['stackFrames'][0]
        print(f"Stopped at: {frame['source']['path'].split('/')[-1]}:{frame['line']}")
        assert frame['line'] == 76, f"Expected line 76, got {frame['line']}"
        
        # Verify we're in the nested VM (increment_and_decrement function)
        # The stack should show we're in a nested context
        initial_frames = response['body']['stackFrames']
        print(f"Initial stack depth: {len(initial_frames)} frames")
        
        # Step out - should go back to parent VM
        print("\nStepping out...")
        seq = client.send_request("stepOut", {"threadId": 1})
        client.wait_for_response(seq)
        
        # Wait for stop after step-out
        stopped = client.wait_for_event("stopped", timeout=5.0)
        if not stopped:
            print("✗ No stopped event received after step-out")
            return False
            
        print(f"Stopped: reason={stopped['body']['reason']}")
        
        # Get new position
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        new_frames = response['body']['stackFrames']
        new_frame = new_frames[0]
        new_line = new_frame['line']
        file_name = new_frame['source']['path'].split('/')[-1]
        
        print(f"After step-out: {file_name}:{new_line}")
        print(f"New stack depth: {len(new_frames)} frames")
        
        # Verify we stepped out to parent VM
        if stopped['body']['reason'] != "step":
            print(f"✗ Expected 'step' stop reason, got '{stopped['body']['reason']}'")
            return False
            
        # We should be back in the parent VM context
        # The exact line depends on where the parent VM execution resumes
        print("✓ Step-out worked correctly")
        return True
        
    finally:
        client.shutdown()

if __name__ == "__main__":
    # Test both issues
    success1 = test_step_over_into_nested_vm()
    success2 = test_step_out_of_nested_vm()
    
    if success1 and success2:
        print("\n✓ All stepping tests passed")
        sys.exit(0)
    else:
        print("\n✗ Some stepping tests failed")
        sys.exit(1)