#!/usr/bin/env python3
"""Test DAP initialization sequence."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_initialization():
    """Test DAP initialization sequence."""
    print("\n=== Test: Initialization ===")

    client = DapClient([
        './zig-out/bin/zb', 'cvm', 'run',
        '--artifact_path', './simple_test/target/simple_test.json',
        '--calldata_path', './simple_test/Prover.toml',
        '--debug-dap'
    ])

    try:
        # Send initialize request
        seq = client.send_request("initialize", {
            "clientID": "test",
            "clientName": "Test Client",
            "adapterID": "ziegenberg",
            "linesStartAt1": True,
            "columnsStartAt1": True
        })

        # Wait for response
        response = client.wait_for_response(seq)
        assert response is not None, "No initialize response received"
        assert response['success'], "Initialize failed"
        print("✓ Initialize request successful")

        # Wait for initialized event
        event = client.wait_for_event("initialized")
        assert event is not None, "No initialized event received"
        print("✓ Initialized event received")

        # Send configuration done
        seq = client.send_request("configurationDone")
        response = client.wait_for_response(seq)
        assert response is not None, "No configurationDone response"
        print("✓ Configuration done")

        # Verify we don't get a stopped event (should just run)
        stopped = client.wait_for_event("stopped", timeout=0.5)
        assert stopped is None, "Should not stop at entry anymore"
        print("✓ Did not stop at entry (correct behavior)")

        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_initialization()
    sys.exit(0 if success else 1)