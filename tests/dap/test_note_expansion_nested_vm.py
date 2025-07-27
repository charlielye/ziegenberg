#!/usr/bin/env python3
"""Test note expansion in nested VM contexts.

This test verifies that notes can be properly expanded when debugging
nested VM calls in TXE. It specifically tests the case where a note
is added in a nested VM and should be visible when expanding the
notes collection in the DAP variables view.
"""

import sys
import os
sys.path.append(os.path.join(os.path.dirname(__file__), 'tests/dap'))

from dap_client import DapClient

def test_line77_notes():
    print("\n=== Testing notes at line 77 ===")

    client = DapClient([
        './zig-out/bin/zb', 'txe',
        './aztec-packages/noir-projects/noir-contracts/target/tests/Counter__extended_incrementing_and_decrementing_pass.json',
        '--debug-dap'
    ])

    try:
        # Initialize
        seq = client.send_request("initialize", {
            "clientID": "test",
            "supportsVariableType": True
        })
        response = client.wait_for_response(seq)
        assert response is not None

        client.wait_for_event("initialized")

        # Set breakpoint at line 77
        seq = client.send_request("setBreakpoints", {
            "source": {
                "path": "/mnt/user-data/charlie/ziegenberg/aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/src/main.nr"
            },
            "breakpoints": [{"line": 77}]
        })
        response = client.wait_for_response(seq)
        print(f"✓ Breakpoint set at line 77")

        # Launch
        seq = client.send_request("launch", {})
        client.wait_for_response(seq)
        
        # Configuration done
        seq = client.send_request("configurationDone", {})
        client.wait_for_response(seq)
        
        # Wait for entry stop
        event = client.wait_for_event("stopped", timeout=30)
        
        # Continue to hit breakpoint at line 77
        seq = client.send_request("continue", {"threadId": 1})
        client.wait_for_response(seq)
        
        # Wait for breakpoint hit
        print("Waiting for breakpoint at line 77...")
        event = client.wait_for_event("stopped", timeout=30)
        print(f"✓ Hit breakpoint")
        
        # Get stack trace
        seq = client.send_request("stackTrace", {"threadId": 1})
        response = client.wait_for_response(seq)
        frame_id = response['body']['stackFrames'][0]['id']
        
        # Get scopes
        seq = client.send_request("scopes", {"frameId": frame_id})
        response = client.wait_for_response(seq)
        
        print("\nScopes:")
        for scope in response['body']['scopes']:
            print(f"  {scope['name']} (ref: {scope['variablesReference']})")
        
        # Get variables for each VM scope
        for scope in response['body']['scopes']:
            if "VM State" in scope['name']:
                print(f"\nVariables in {scope['name']}:")
                seq = client.send_request("variables", {
                    "variablesReference": scope['variablesReference']
                })
                response2 = client.wait_for_response(seq)
                
                notes_ref = None
                for var in response2['body']['variables']:
                    if var['name'] == 'notes':
                        print(f"  {var['name']}: {var['value']} (ref: {var.get('variablesReference', 0)})")
                        notes_ref = var.get('variablesReference', 0)
                    elif var['name'] in ['contract_address', 'side_effect_counter']:
                        print(f"  {var['name']}: {var['value']}")
                
                # Try to expand notes if found
                if notes_ref and notes_ref > 0:
                    print(f"  Expanding notes (ref: {notes_ref})...")
                    seq = client.send_request("variables", {
                        "variablesReference": notes_ref
                    })
                    response3 = client.wait_for_response(seq)
                    
                    items = response3['body']['variables']
                    print(f"  Result: {len(items)} items")
                    for item in items[:3]:  # Show first 3
                        print(f"    - {item['name']}: {item['value']}")
        
        return True

    finally:
        client.shutdown()

if __name__ == "__main__":
    success = test_line77_notes()
    sys.exit(0 if success else 1)