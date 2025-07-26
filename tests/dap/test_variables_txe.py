#!/usr/bin/env python3
"""Test that DAP variables work for TXE state inspection."""

import sys
import os
sys.path.append(os.path.dirname(__file__))

from dap_client import DapClient

def test_variables_txe():
    """Test that DAP variables work for TXE state inspection."""
    print("\n=== Test: Variables (TXE State) ===")

    # Use TXE test which has TxeState
    client = DapClient([
        './zig-out/bin/zb', 'txe',
        './aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/target/tests/Counter__extended_incrementing_and_decrementing_pass.json',
        '--debug-dap'
    ])

    try:
        # Initialize
        seq = client.send_request("initialize", {
            "clientID": "test",
            "supportsVariableType": True
        })
        response = client.wait_for_response(seq)
        assert response is not None, "No initialize response"

        # Check that server reports variable support
        capabilities = response.get('body', {})
        print(f"✓ Server capabilities include supportsVariableType: {capabilities.get('supportsVariableType', False)}")

        client.wait_for_event("initialized")

        # Set a breakpoint to stop execution
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/aztec-packages/noir-projects/noir-contracts/contracts/counter_contract/src/main.nr"
            },
            "breakpoints": [{"line": 10}]  # Try to set breakpoint in Counter contract
        })
        client.wait_for_response(seq)

        seq = client.send_request("launch", {})
        client.wait_for_response(seq)

        seq = client.send_request("configurationDone")
        client.wait_for_response(seq)

        # Wait for a stop (either at entry or breakpoint)
        stopped = client.wait_for_event("stopped", timeout=2.0)
        if not stopped:
            print("! No stopped event - trying to pause execution")
            # Try to pause
            seq = client.send_request("pause", {"threadId": 1})
            client.wait_for_response(seq)
            stopped = client.wait_for_event("stopped", timeout=2.0)

        if not stopped:
            print("✗ Could not stop execution to inspect variables")
            return False

        print("✓ Execution stopped")

        # Get stack frames
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        assert response is not None, "No stackTrace response"

        frames = response['body']['stackFrames']
        assert len(frames) > 0, "No stack frames"
        print(f"✓ Got {len(frames)} stack frames")

        # Request scopes for the top frame
        frame_id = frames[0]['id']
        seq = client.send_request("scopes", {"frameId": frame_id})
        response = client.wait_for_response(seq)
        assert response is not None, "No scopes response"
        assert response.get('success'), "Scopes request failed"

        scopes = response['body']['scopes']
        print(f"\n✓ Got {len(scopes)} scopes:")
        for scope in scopes:
            print(f"  - {scope['name']} (variablesReference: {scope['variablesReference']})")

        # Verify we have TXE scopes
        scope_names = [s['name'] for s in scopes]
        assert "TXE Global State" in scope_names, "Missing TXE Global State scope"
        
        # Should have at least one VM State scope
        vm_state_scopes = [s for s in scope_names if "VM State" in s and s != "Memory Writes"]
        assert len(vm_state_scopes) >= 1, f"Expected at least one VM State scope, got {vm_state_scopes}"
        print(f"  Found {len(vm_state_scopes)} VM State scope(s)")

        # Get variables for each scope
        for scope in scopes:
            print(f"\nVariables in {scope['name']}:")
            seq = client.send_request("variables", {
                "variablesReference": scope['variablesReference']
            })
            response = client.wait_for_response(seq)
            assert response is not None, f"No variables response for {scope['name']}"
            assert response.get('success'), f"Variables request failed for {scope['name']}"

            variables = response['body']['variables']
            for var in variables:
                var_name = var['name']
                var_value = var['value']
                var_type = var.get('type', 'unknown')
                print(f"  - {var_name}: {var_value} ({var_type})")

                # Verify some expected variables exist
                if scope['name'] == "TXE Global State":
                    if var_name == "block_number":
                        assert var_type == "u32", f"block_number should be u32, got {var_type}"
                    elif var_name == "timestamp":
                        assert var_type == "u64", f"timestamp should be u64, got {var_type}"
                    elif var_name == "chain_id":
                        assert var_type == "Field", f"chain_id should be Field, got {var_type}"
                elif scope['name'] == "Current Call State":
                    if var_name == "contract_address":
                        assert var_type == "AztecAddress", f"contract_address should be AztecAddress, got {var_type}"
                    elif var_name == "is_static_call":
                        assert var_type == "bool", f"is_static_call should be bool, got {var_type}"
                        assert var_value in ["true", "false"], f"is_static_call should be true/false, got {var_value}"
                    elif var_name == "num_storage_writes":
                        assert var_type == "usize", f"num_storage_writes should be usize, got {var_type}"
                    elif var_name == "num_private_logs":
                        assert var_type == "usize", f"num_private_logs should be usize, got {var_type}"
                    elif var_name == "memory_writes" and var.get('variablesReference', 0) > 0:
                        # Test expanding memory writes
                        print(f"\n  Testing memory_writes expansion ({var_value}):")
                        seq2 = client.send_request("variables", {
                            "variablesReference": var['variablesReference']
                        })
                        response2 = client.wait_for_response(seq2)
                        if response2 and response2.get('success'):
                            mem_vars = response2['body']['variables']
                            print(f"    Found {len(mem_vars)} memory slots")
                            # Show first few
                            for mem_var in mem_vars[:5]:
                                print(f"    - {mem_var['name']}: {mem_var['value']}")
                            if len(mem_vars) > 5:
                                print(f"    ... and {len(mem_vars) - 5} more")

        print("\n✓ Variables inspection verified")
        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_variables_txe()
    sys.exit(0 if success else 1)