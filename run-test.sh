#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

BYTECODE_PATH=$1
VM=${VM:-bvm}
VERBOSE=${VERBOSE:-0}

test_name="$(basename $BYTECODE_PATH .bytecode | awk '{ if (length($0) > 80) print substr($0, 1, 40) "..." substr($0, length($0)-40+1); else print $0 }')"

function run_cmd() {
  calldata_path=${1/.bytecode/.calldata}
  zb_args=""
  [ -f "$calldata_path" ] && zb_args+="-c $calldata_path"
  [ "$2" -eq 1 ] && zb_args+=" -t"
  case $VM in
    "bvm")
      ./zig-out/bin/zb bvm run $1 $zb_args
      return $?
      ;;
    "avm")
      cat $1 | ./zig-out/bin/zb bvm dis -b | ~/aztec-repos/aztec-packages/avm-transpiler/target/release/avm-transpiler 2>/dev/null | ./zig-out/bin/zb avm run $zb_args
      return $?
      ;;
    *)
      echo "Unknown vm."
      exit 1
  esac
}

should="${SHOULD:-${test_name##*.}}"
[[ "$should" != "pass" && "$should" != "fail" ]] && should="pass"

set +e
output=$(run_cmd $BYTECODE_PATH $VERBOSE 2>&1 1>/dev/tty)
result=$?
if { [[ $result -ne 0 && "$should" == "pass" ]]; } || \
   { [[ $result -ne 2 && "$should" == "fail" ]]; } || \
   echo "$output" | grep -qi "segmentation fault"
then
  echo -e "$test_name: ${RED}FAILED${NC}"
  run_cmd $BYTECODE_PATH 1
  exit 1
fi
set -e

echo -e "$test_name: ${GREEN}PASSED${NC} ($(echo "$output" | grep 'time taken' | sed 's/time taken: //'))"