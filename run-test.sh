#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

BYTECODE_PATH=$1
VM=${VM:-bvm}
VERBOSE=${VERBOSE:-0}
FAIL_FAST=${FAIL_FAST:-0}

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
      statuses=("${PIPESTATUS[@]}")
      [ ${statuses[2]} -ne 0 ] && return 4
      return ${statuses[3]}
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
set -e
if { [[ $result -ne 0 && "$should" == "pass" ]]; } || \
   { [[ $result -ne 2 && "$should" == "fail" ]]; } || \
   echo "$output" | grep -qi "segmentation fault"
then
  case $result in
    3) echo -e "$test_name: ${RED}UNIMPLEMENTED${NC}";;
    4) echo -e "$test_name: ${YELLOW}TRANSPILE FAILED${NC}";;
    *) echo -e "$test_name: ${RED}FAILED${NC}"
       [ "$FAIL_FAST" -eq 1 ] && run_cmd $BYTECODE_PATH 1
       ;;
  esac
  exit $result
fi

echo -e "$test_name: ${GREEN}PASSED${NC} ($(echo "$output" | grep 'time taken' | sed 's/time taken: //'))"