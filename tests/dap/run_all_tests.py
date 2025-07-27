#!/usr/bin/env python3
"""Run all DAP tests and report results."""

import subprocess
import sys
import os

def run_test(test_file):
    """Run a single test and return success status."""
    try:
        result = subprocess.run([
            sys.executable, test_file
        ], capture_output=True, text=True, cwd=os.path.dirname(__file__))

        if result.returncode == 0:
            print(f"✓ {os.path.basename(test_file)} PASSED")
            return True
        else:
            print(f"✗ {os.path.basename(test_file)} FAILED")
            if result.stdout:
                print(f"STDOUT:\n{result.stdout}")
            if result.stderr:
                print(f"STDERR:\n{result.stderr}")
            return False
    except Exception as e:
        print(f"✗ {os.path.basename(test_file)} ERROR: {e}")
        return False

def main():
    """Run all tests."""
    print("=== Running All DAP Tests ===")

    # List of test files in order
    tests = [
        "test_breakpoint_line_adjustment.py",
        "test_call_stack.py",
        "test_initialization.py",
        "test_memory_tracking.py",
        "test_multiple_files.py",
        "test_pause_command.py",
        "test_step_over_detailed.py",
        "test_stepping_txe.py",
        "test_stepping.py",
        "test_terminate_command.py",
        "test_variables_txe.py",
    ]

    passed = 0
    failed = 0

    for test in tests:
        if run_test(test):
            passed += 1
        else:
            failed += 1
        print()  # Add blank line between tests

    print(f"=== Test Summary ===")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")
    print(f"Total:  {passed + failed}")

    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())