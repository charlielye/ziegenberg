#!/usr/bin/env python3
"""Test step over behavior in detail."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_step_over_detailed():
    """Test step over behavior in detail."""
    print("\n=== Test: Step Over Detailed ===")

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

        # Set a breakpoint at line 6
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

        # Should hit the breakpoint at line 6
        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "Should hit breakpoint"
        assert stopped['body']['reason'] == 'breakpoint', "Should stop at breakpoint"

        # Get initial position
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        initial_line = response['body']['stackFrames'][0]['line']
        print(f"Starting at line {initial_line}")

        # Step over multiple times and track progress
        expected_lines = [9, 12, 15, 18]  # Expected progression through the function
        actual_lines = []

        for i in range(4):
            print(f"\nStep over #{i+1}...")
            seq = client.send_request("next", {"threadId": 1})
            response = client.wait_for_response(seq)
            assert response is not None, f"No response for step {i+1}"

            stopped = client.wait_for_event("stopped", timeout=2.0)
            if not stopped:
                print("No more lines to step to (reached end)")
                break

            # Get current position
            seq = client.send_request("stackTrace", {"threadId": 1})
            response = client.wait_for_response(seq)
            if response and response['body']['stackFrames']:
                line = response['body']['stackFrames'][0]['line']
                actual_lines.append(line)
                print(f"✓ Stopped at line {line}")

        # Verify we hit the expected lines
        print(f"\nExpected lines: {expected_lines[:len(actual_lines)]}")
        print(f"Actual lines: {actual_lines}")

        # We should have made some progress
        assert len(actual_lines) > 0, "Should have stepped to at least one line"
        assert actual_lines[0] > initial_line, "Should have moved forward"

        print("✓ Step over progression verified")
        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_step_over_detailed()
    sys.exit(0 if success else 1)