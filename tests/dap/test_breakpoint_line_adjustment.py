#!/usr/bin/env python3
"""Test that breakpoints on comment lines are adjusted to code lines."""

import sys
import os
import time
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_breakpoint_line_adjustment():
    """Test that breakpoints on comment lines are adjusted to code lines."""
    print("\n=== Test: Breakpoint Line Adjustment ===")

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

        # Set breakpoints on comment lines (5, 8, 11, 14)
        # These should be adjusted to code lines (6, 9, 12, 15)
        print("\nSetting breakpoints on comment lines: 5, 8, 11, 14")
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [
                {"line": 5},   # Comment -> should move to 6
                {"line": 8},   # Comment -> should move to 9
                {"line": 11},  # Comment -> should move to 12
                {"line": 14},  # Comment -> should move to 15
            ]
        })

        response = client.wait_for_response(seq)
        assert response is not None, "No setBreakpoints response"

        # Launch and configuration
        seq = client.send_request("launch", {})
        client.wait_for_response(seq)

        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)

        # Should hit the first breakpoint (line 6 after adjustment from line 5)
        stopped_event = client.wait_for_event("stopped", timeout=2.0)
        assert stopped_event is not None, "Should hit first breakpoint"
        assert stopped_event['body']['reason'] == 'breakpoint', "Should stop for breakpoint"
        print("\n✓ Hit first breakpoint")

        # Now collect breakpoint events that were sent
        print("\nCollecting breakpoint adjustment events...")
        time.sleep(0.5)

        # Collect all messages
        messages = client.get_all_messages()
        breakpoint_events = [m for m in messages if m.get('type') == 'event' and m.get('event') == 'breakpoint']

        print(f"\nReceived {len(breakpoint_events)} breakpoint events")
        for event in breakpoint_events:
            bp = event['body']['breakpoint']
            if bp.get('message'):
                print(f"✓ {bp['message']}")

        # Get stack trace to see where we stopped
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)

        if response and response.get('body', {}).get('stackFrames'):
            line = response['body']['stackFrames'][0].get('line')
            print(f"\nStopped at line {line} (first breakpoint)")

        # Continue and check breakpoint hits
        breakpoint_hits = []
        for _ in range(3):  # We expect to hit 3 breakpoints (9, 12, 15)
            seq = client.send_request("continue", {"threadId": 1})
            client.wait_for_response(seq)

            stopped = client.wait_for_event("stopped", timeout=2.0)
            if not stopped:
                break

            if stopped['body']['reason'] == 'breakpoint':
                # Get current line
                seq = client.send_request("stackTrace", {"threadId": 1})
                response = client.wait_for_response(seq)
                if response and response.get('body', {}).get('stackFrames'):
                    line = response['body']['stackFrames'][0].get('line')
                    breakpoint_hits.append(line)
                    print(f"✓ Hit breakpoint at line {line}")

        # Verify we hit the adjusted lines
        expected_hits = [9, 12, 15]  # Line 6 is the entry point, so we don't hit it
        assert breakpoint_hits == expected_hits, f"Expected {expected_hits}, got {breakpoint_hits}"
        print("\n✓ All breakpoints hit at correct adjusted lines")

        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_breakpoint_line_adjustment()
    sys.exit(0 if success else 1)