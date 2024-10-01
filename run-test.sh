#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

BYTECODE_PATH=$1

test_name="$(basename $BYTECODE_PATH .bytecode | awk '{ if (length($0) > 80) print substr($0, 1, 40) "..." substr($0, length($0)-40+1); else print $0 }')"

function run_cmd() {
  ./zig-out/bin/zb-bvm run $1 2>&1
}

should="${test_name%.*}"

set +e
output=$(run_cmd $BYTECODE_PATH)
result=$?
if { [[ $result -ne 0 && "$should" == "pass" ]]; } || \
   { [[ $result -ne 2 && "$should" == "fail" ]]; } || \
   echo "$output" | grep -qi "segmentation fault"
then
  echo -e "$test_name: ${RED}FAILED${NC}"
  # run_cmd $BYTECODE_PATH
  exit 1
fi
set -e

echo -e "$test_name: ${GREEN}PASSED${NC} ($(echo "$output" | grep 'time taken' | sed 's/time taken: //'))"