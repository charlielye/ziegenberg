#!/usr/bin/env python3
"""Run all DAP tests and report results."""

import subprocess
import sys
import os
import time
from concurrent.futures import ProcessPoolExecutor, as_completed

def run_test(test_file):
    """Run a single test and return (test_file, success, duration, output)."""
    start_time = time.time()
    try:
        result = subprocess.run([
            sys.executable, test_file
        ], capture_output=True, text=True, cwd=os.path.dirname(__file__))

        duration = time.time() - start_time
        success = result.returncode == 0
        output = ""
        
        if not success:
            if result.stdout:
                output += f"STDOUT:\n{result.stdout}\n"
            if result.stderr:
                output += f"STDERR:\n{result.stderr}\n"
                
        return (test_file, success, duration, output)
    except Exception as e:
        duration = time.time() - start_time
        return (test_file, False, duration, f"ERROR: {e}")

def main():
    """Run all tests."""
    print("=== Running All DAP Tests in Parallel ===")
    start_time = time.time()

    # List of test files in order
    tests = [
        "test_breakpoint_line_adjustment.py",
        "test_call_stack.py",
        "test_initialization.py",
        "test_memory_tracking.py",
        "test_pause_command.py",
        "test_step_in.py",
        "test_step_over.py",
        "test_stepping_txe.py",
        "test_terminate_command.py",
        "test_variables_txe.py",
        "test_note_expansion_nested_vm.py",
    ]

    passed = 0
    failed = 0
    results = []

    # Run all tests in parallel
    max_workers = min(len(tests), os.cpu_count() or 4)
    print(f"Running {len(tests)} tests with {max_workers} workers...\n")
    
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        # Submit all tests
        future_to_test = {executor.submit(run_test, test): test for test in tests}
        
        # Process results as they complete
        for future in as_completed(future_to_test):
            test_file, success, duration, output = future.result()
            test_name = os.path.basename(test_file)
            
            if success:
                print(f"✓ {test_name} PASSED ({duration:.2f}s)")
                passed += 1
            else:
                print(f"✗ {test_name} FAILED ({duration:.2f}s)")
                failed += 1
            
            results.append((test_name, success, duration, output))

    # Print detailed failure information
    print("\n=== Failure Details ===")
    failures_found = False
    for test_name, success, duration, output in results:
        if not success:
            failures_found = True
            print(f"\n{test_name}:")
            print(output)
    
    if not failures_found:
        print("No failures!")

    total_time = time.time() - start_time
    print(f"\n=== Test Summary ===")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")
    print(f"Total:  {passed + failed}")
    print(f"Time:   {total_time:.2f}s")

    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())