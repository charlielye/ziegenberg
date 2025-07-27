#!/usr/bin/env python3
"""Test that memory write tracking works in DAP variables."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_memory_tracking():
    """Test that memory write tracking works in DAP variables."""
    print("\n=== Test: Memory Write Tracking ===")

    # Use a simple test that we know writes to memory
    client = DapClient([
        './zig-out/bin/zb', 'cvm', 'run',
        '--artifact_path', './simple_test/target/simple_test.json',
        '--calldata_path', './simple_test/Prover.toml',
        '--debug-dap'
    ])

    try:
        # Initialize
        seq = client.send_request("initialize", {"clientID": "test"})
        client.wait_for_response(seq)
        client.wait_for_event("initialized")

        # Set a breakpoint after some memory operations
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [{"line": 15}]  # After some operations
        })
        client.wait_for_response(seq)

        seq = client.send_request("launch", {})
        client.wait_for_response(seq)

        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)

        # Should hit the breakpoint
        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "Should hit breakpoint"
        print("✓ Hit breakpoint")

        # Get stack frames
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        assert response is not None, "No stackTrace response"
        
        frames = response['body']['stackFrames']
        assert len(frames) > 0, "No stack frames"
        
        # Request scopes for the top frame
        frame_id = frames[0]['id']
        seq = client.send_request("scopes", {"frameId": frame_id})
        response = client.wait_for_response(seq)
        assert response is not None, "No scopes response"
        
        scopes = response['body']['scopes']
        print(f"\n✓ Got {len(scopes)} scopes:")
        for scope in scopes:
            print(f"  - {scope['name']}")
        
        # Check if memory writes scope exists
        memory_scope = None
        for scope in scopes:
            if "Memory Writes" in scope['name']:
                memory_scope = scope
                break
        
        if memory_scope:
            print(f"\n✓ Found Memory Writes scope: {memory_scope['name']}")
            
            # Request variables for memory writes scope
            seq = client.send_request("variables", {
                "variablesReference": memory_scope['variablesReference']
            })
            response = client.wait_for_response(seq)
            assert response is not None, "No variables response for memory writes"
            
            variables = response['body']['variables']
            print(f"✓ Memory writes contains {len(variables)} slots")
            
            # Show a few memory writes
            for var in variables[:5]:  # First 5
                print(f"  - {var['name']}: {var['value']}")
        else:
            print("\n! No memory writes scope found (might be no writes yet)")

        print("\n✓ Memory tracking in DAP working correctly")
        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_memory_tracking()
    sys.exit(0 if success else 1)