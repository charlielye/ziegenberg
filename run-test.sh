#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

BYTECODE_PATH=$1
VM=${VM:-bvm}
ENGINE=${ENGINE:-zb}
VERBOSE=${VERBOSE:-0}
VERBOSE_FAIL=${VERBOSE_FAIL:-0}
NO_TRUNC=${NO_TRUNC:-0}

base_path="${BYTECODE_PATH%.*}"
json_path="${base_path}.json"
witness_path="${base_path}.gz"
calldata_path="${base_path}.calldata"

if [ "$NO_TRUNC" -eq 0 ]; then
  test_name="$(basename $base_path | awk '{ if (length($0) > 80) print substr($0, 1, 40) "..." substr($0, length($0)-40+1); else print $0 }')"
else
  test_name="$(basename $base_path)"
fi

function run_cmd() {
  zb_args="-s"
  [ -f "$calldata_path" ] && zb_args+=" -c $calldata_path"
  [ "$1" -eq 1 ] && zb_args+=" -t"
  case "$VM-$ENGINE" in
    "bvm-zb")
      ./zig-out/bin/zb bvm run $BYTECODE_PATH $zb_args
      return $?
      ;;
    "bvm-zb-wasm")
      wasmtime --dir $HOME ./zig-out/bin/zb.wasm bvm run $BYTECODE_PATH $zb_args
      return $?
      ;;
    "avm-zb")
      cat $BYTECODE_PATH | ./zig-out/bin/zb bvm dis -b | ~/aztec-repos/aztec-packages/avm-transpiler/target/release/avm-transpiler 2>/dev/null | ./zig-out/bin/zb avm run $zb_args
      statuses=("${PIPESTATUS[@]}")
      [ ${statuses[2]} -ne 0 ] && return 4
      return ${statuses[3]}
      ;;
    "avm-zb-wasm")
      cat $BYTECODE_PATH | ./zig-out/bin/zb bvm dis -b | ~/aztec-repos/aztec-packages/avm-transpiler/target/release/avm-transpiler 2>/dev/null | wasmtime --dir $HOME ./zig-out/bin/zb.wasm avm run $zb_args
      statuses=("${PIPESTATUS[@]}")
      [ ${statuses[2]} -ne 0 ] && return 4
      return ${statuses[3]}
      ;;
    "cvm-zb")
      cmp <(./zig-out/bin/zb cvm run $BYTECODE_PATH -c $calldata_path -b) <(cat $witness_path | gunzip) > /dev/null
      return $?
      ;;
    "bvm-nargo")
      cd $(dirname $BYTECODE_PATH)
      rm $json_path $witness_path
      # nargo prints to stdout, redirect to stderr.
      ~/aztec-repos/aztec-packages/noir/noir-repo/target/release/nargo execute --force-brillig --silence-warnings | tr -d '\0' 1>&2
      ;;
    "cvm-nargo")
      cd $(dirname $BYTECODE_PATH)
      rm $json_path $witness_path
      # nargo prints to stdout, redirect to stderr.
      ~/aztec-repos/aztec-packages/noir/noir-repo/target/release/nargo execute --silence-warnings | tr -d '\0' 1>&2
      ;;
    *)
      echo "Unknown vm."
      exit 1
  esac
}

should="${SHOULD:-${test_name##*.}}"
[[ "$should" != "pass" && "$should" != "fail" ]] && should="pass"

set +e
# Capture stderr in $output, stdout still goes to console.
output=$(run_cmd $VERBOSE 2>&1 1>/dev/tty)
result=$?
set -e
if { [[ $result -ne 0 && "$should" == "pass" ]]; } || \
   { [[ $result -ne 2 && "$should" == "fail" ]]; } || \
   echo "$output" | grep -qi "segmentation fault"
then
  case $result in
    3)  echo -e "$test_name: ${RED}UNIMPLEMENTED${NC}";;
    4)  echo -e "$test_name: ${YELLOW}TRANSPILE FAILED${NC}";;
    *)  echo -e "$test_name: ${RED}FAILED${NC}"
        [ "$VERBOSE_FAIL" -eq 1 ] && run_cmd $VERBOSE_FAIL
        exit 1
        ;;
  esac
  exit $result
fi

echo -e "$test_name: ${GREEN}PASSED${NC} ($(echo "$output" | grep -i 'time taken' | sed 's/time taken: //i'))"