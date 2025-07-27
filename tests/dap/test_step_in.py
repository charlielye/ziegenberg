#!/usr/bin/env python3
"""Test step in operation."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_step_in():
    """Test step in operation."""
    print("\n=== Test: Step In ===")

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

        # Test step in
        print("\nTesting step in...")
        seq = client.send_request("stepIn", {"threadId": 1})
        response = client.wait_for_response(seq)
        assert response is not None, "No stepIn response"

        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "No stopped event after step in"
        assert stopped['body']['reason'] == 'step', "Wrong stop reason"
        print("✓ Step in successful")

        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_step_in()
    sys.exit(0 if success else 1)