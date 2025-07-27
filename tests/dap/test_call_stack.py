#!/usr/bin/env python3
"""Test that call stack is displayed correctly."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_call_stack():
    """Test that call stack is displayed correctly."""
    print("\n=== Test: Call Stack ===")

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

        # Set a breakpoint inside the compute function
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/simple_test/src/main.nr"
            },
            "breakpoints": [{"line": 12}]  # Inside compute function
        })
        client.wait_for_response(seq)

        seq = client.send_request("launch", {})
        client.wait_for_response(seq)

        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)

        # Should hit the breakpoint
        stopped = client.wait_for_event("stopped")
        assert stopped is not None, "Should hit breakpoint"

        # Get the stack trace
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)

        assert response is not None, "No stackTrace response"
        assert response.get('success'), "stackTrace failed"

        frames = response['body']['stackFrames']
        print(f"\nCall stack has {len(frames)} frames:")

        for i, frame in enumerate(frames):
            name = frame.get('name', 'unknown')
            source = frame.get('source')
            line = frame.get('line', 0)

            if source:
                path = source.get('path', 'unknown')
                filename = path.split('/')[-1] if '/' in path else path
                print(f"  [{i}] {name} at {filename}:{line}")
            else:
                print(f"  [{i}] {name} at <no source>:{line}")

        # Verify we have at least 2 frames (compute function and main)
        assert len(frames) >= 2, f"Expected at least 2 frames, got {len(frames)}"

        # The top frame should be in compute function (around line 12)
        assert frames[0]['line'] == 12, f"Expected top frame at line 12, got {frames[0]['line']}"

        # The frame names should have VM index prefix (e.g., "0:- name" or "0:0 name")
        assert frames[0]['name'].startswith(('0:', '1:', '2:')), f"Frame name should start with VM index: {frames[0]['name']}"

        print("\n✓ Call stack display verified")
        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_call_stack()
    sys.exit(0 if success else 1)