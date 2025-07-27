#!/usr/bin/env python3
"""Test that the terminate command works (VSCode stop button)."""

import sys
import os
import time
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_terminate_command():
    """Test that the terminate command works (VSCode stop button)."""
    print("\n=== Test: Terminate Command (VSCode Stop Button) ===")

    # Use TXE test which runs longer
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

        seq = client.send_request("launch", {})
        client.wait_for_response(seq)

        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)

        # TXE might stop at entry or run (depends on if it has debug info)
        stopped = client.wait_for_event("stopped", timeout=1.0)
        if stopped:
            print("✓ Stopped (TXE test)")
            # Continue execution to let it run
            print("\nContinuing execution...")
            seq = client.send_request("continue", {"threadId": 1})
            response = client.wait_for_response(seq)
            assert response is not None, "No continue response"
            print("✓ Continue command accepted")
        else:
            print("✓ Already running (no breakpoints set)")

        # Give it a moment to start running
        time.sleep(0.5)

        # Send terminate command (what VSCode sends when stop button is clicked)
        print("\nSending terminate command...")
        terminate_seq = client.send_request("terminate")

        # Wait for terminate response
        terminate_response = client.wait_for_response(terminate_seq, timeout=1.0)
        assert terminate_response is not None, "No terminate response received"
        assert terminate_response.get('success'), "Terminate command failed"
        print("✓ Terminate command accepted")

        # Wait for terminated event
        terminated = client.wait_for_event("terminated", timeout=2.0)
        assert terminated is not None, "No terminated event after terminate"
        print("✓ Terminated event received")

        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_terminate_command()
    sys.exit(0 if success else 1)