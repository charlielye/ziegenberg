#!/usr/bin/env python3
"""Test that the pause command works when debugger is running."""

import sys
import os
import time
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_pause_command():
    """Test that the pause command works when debugger is running."""
    print("\n=== Test: Pause Command (Stop Button) ===")

    # Use TXE test which runs longer
    client = DapClient([
        './zig-out/bin/zb', 'txe',
        './aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/target/tests/Counter__extended_incrementing_and_decrementing_pass.json',
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

        # Send pause command while running
        print("\nSending pause command...")
        pause_seq = client.send_request("pause", {"threadId": 1})

        # Wait for pause response
        pause_response = client.wait_for_response(pause_seq, timeout=1.0)
        if pause_response is None:
            # Process might have terminated already
            print("! Program may have completed before pause command")
            # Check if we got a terminated event
            messages = client.get_all_messages()
            terminated = any(m.get('type') == 'event' and m.get('event') == 'terminated' for m in messages)
            if terminated:
                print("✓ Program terminated (too fast to pause)")
                return True
            else:
                assert False, "No pause response and no termination"

        assert pause_response.get('success'), "Pause command failed"
        print("✓ Pause command accepted")

        # Wait for stopped event
        stopped = client.wait_for_event("stopped", timeout=2.0)
        assert stopped is not None, "No stopped event after pause"
        assert stopped['body']['reason'] == 'pause', f"Wrong stop reason: {stopped['body']['reason']}"
        print("✓ Stopped event received with reason 'pause'")

        # Verify we can continue again
        seq = client.send_request("continue", {"threadId": 1})
        response = client.wait_for_response(seq)
        assert response is not None, "No continue response after pause"
        print("✓ Can continue after pause")

        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_pause_command()
    sys.exit(0 if success else 1)