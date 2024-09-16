#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

failed_transpile=0
failed_execution=0
success=0

NARGO=${NARGO:-0}

run_cmd() {
    BASE="$(basename $1)"
    jq -r .bytecode "$1/target/$BASE.json" | base64 -d | gunzip | ./zig-out/bin/ziegenberg - "$1/target/calldata" 2>&1
}

zig build

for DIR in $@; do
  if [ "$NARGO" -eq 1 ]; then
    (cd $DIR && ~/aztec-repos/aztec-packages/noir/noir-repo/target/release/nargo compile --force-brillig --silence-warnings) || exit 1
  fi

  echo -n "$(basename $DIR): "

  set +e
  output=$(run_cmd $DIR)
  if [ $? -ne 0 ] || echo "$output" | grep -qi "segmentation fault"; then
    echo -e "${RED}FAILED${NC}"
    run_cmd $DIR
    failed_execution=$((failed_execution + 1))
    [ "$EXIT_ON_FAIL" -eq 1 ] && exit 1
    continue
  fi
  set -e

  # output=$(perf stat -e duration_time -r 5 ./zig-out/bin/ziegenberg $DIR/target/$BASE.json $DIR/target/calldata 2>&1)
  # micros=$(echo "$output" | awk "/ ns/ {print int(\$1/1000)-$PROC_OVERHEAD_US}")
  # echo -e "${GREEN}PASSED${NC} (${micros}us)"
  echo -e "${GREEN}PASSED${NC}"
  success=$((success + 1))
done

echo
echo Summary:
echo -e "         Success: ${GREEN}$success${NC}"
# echo -e "Failed transpile: ${YELLOW}$failed_transpile${NC}"
echo -e "Failed execution: ${RED}$failed_execution${NC}"