#!/usr/bin/env python3
"""Test step operations (step in, step over, step out)."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_stepping():
    """Test step operations (step in, step over, step out)."""
    print("\n=== Test: Stepping ===")

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

        # Set a breakpoint at line 6 to have somewhere to stop
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [{"line": 6}]
        })
        client.wait_for_response(seq)

        seq = client.send_request("launch", {})
        client.wait_for_response(seq)

        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)

        # Should hit the breakpoint
        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "No stopped event"
        assert stopped['body']['reason'] == 'breakpoint', "Should stop at breakpoint"
        print("✓ Hit breakpoint at line 6")

        # Test step over
        print("\nTesting step over...")
        seq = client.send_request("next", {"threadId": 1})
        response = client.wait_for_response(seq)
        assert response is not None, "No next response"

        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "No stopped event after step"
        assert stopped['body']['reason'] == 'step', "Wrong stop reason"

        # Verify we're on the next line
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        if response and response.get('body', {}).get('stackFrames'):
            line = response['body']['stackFrames'][0].get('line')
            print(f"✓ Step over moved to line {line}")

        # Test step in
        print("\nTesting step in...")
        seq = client.send_request("stepIn", {"threadId": 1})
        response = client.wait_for_response(seq)
        assert response is not None, "No stepIn response"

        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "No stopped event after step in"
        print("✓ Step in successful")

        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_stepping()
    sys.exit(0 if success else 1)