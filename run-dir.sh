#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

skipped=0
failed_execution=0
success=0

NARGO=${NARGO:-0}
RELEASE=${RELEASE:-0}
EXIT_ON_FAIL=${EXIT_ON_FAIL:-0}

run_cmd() {
    BASE="$(basename $1)"
    jq -r .bytecode "$1/target/$BASE.json" | base64 -d | gunzip | ./zig-out/bin/ziegenberg - "$1/target/calldata" 2>&1
}

# Limit to generic cpu to prevent avx as avx is just worse performance.
zig_args="-Dcpu=x86_64"
[ "$RELEASE" -eq 1 ] && zig_args+=" --release=fast"
zig build $zig_args

for DIR in $@; do
  if [ "$NARGO" -eq 1 ]; then
    (cd $DIR && ~/aztec-repos/aztec-packages/noir/noir-repo/target/release/nargo compile --force-brillig --silence-warnings) || exit 1
  fi

  echo -n "$(basename $DIR): "

  if [ ! -f "$DIR/target/calldata" ]; then
    echo -e "${YELLOW}SKIPPING${NC} (missing calldata)"
    skipped=$((skipped + 1))
    continue
  fi

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
  echo -e "${GREEN}PASSED${NC} ($(echo "$output" | grep 'time taken' | sed 's/time taken: //'))"
  success=$((success + 1))
done

echo
echo Summary:
echo -e "Success: ${GREEN}$success${NC}"
echo -e "Skipped: ${YELLOW}$skipped${NC}"
echo -e " Failed: ${RED}$failed_execution${NC}"