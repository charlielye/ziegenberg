#!/bin/bash

# Test breakpoints with DAP

echo "=== Testing Breakpoint Support ==="

# Start the DAP debugger in the background
echo "Starting debugger with DAP..."
./zig-out/bin/zb cvm run --artifact_path ./aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/target/tests/Counter__extended_incrementing_and_decrementing_pass.json --debug_dap > debug_output.log 2>&1 &
DEBUG_PID=$!

# Give it time to start
sleep 2

# Use telnet or nc to send DAP commands
cat << 'EOF' | nc localhost 12345
Content-Length: 180

{"seq":1,"type":"request","command":"initialize","arguments":{"clientID":"test","clientName":"Test Client","adapterID":"ziegenberg","linesStartAt1":true,"columnsStartAt1":true}}
EOF

sleep 1

# Set breakpoints on lines where we expect code execution (debug_log statements)
cat << 'EOF' | nc localhost 12345
Content-Length: 254

{"seq":2,"type":"request","command":"setBreakpoints","arguments":{"source":{"path":"/mnt/user-data/charlie/ziegenberg/aztec-packages/noir-projects/noir-contracts/contracts/test/counter_contract/src/main.nr"},"breakpoints":[{"line":42},{"line":57},{"line":70}]}}
EOF

sleep 1

# Send launch and configuration done
cat << 'EOF' | nc localhost 12345
Content-Length: 62

{"seq":3,"type":"request","command":"launch","arguments":{}}
EOF

sleep 1

cat << 'EOF' | nc localhost 12345
Content-Length: 74

{"seq":4,"type":"request","command":"configurationDone","arguments":{}}
EOF

sleep 1

# Continue execution
cat << 'EOF' | nc localhost 12345
Content-Length: 73

{"seq":5,"type":"request","command":"continue","arguments":{"threadId":1}}
EOF

# Let it run for a bit
sleep 5

# Disconnect
cat << 'EOF' | nc localhost 12345
Content-Length: 62

{"seq":6,"type":"request","command":"disconnect","arguments":{}}
EOF

sleep 1

# Kill the debug process
kill $DEBUG_PID 2>/dev/null

echo ""
echo "=== Debug Output ==="
cat debug_output.log | grep -E "(Breakpoint|stopped|paused|line)"

# Clean up
rm -f debug_output.log

echo ""
echo "=== Test Complete ==="