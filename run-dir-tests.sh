#!/bin/bash
set -u
shopt -s extglob

DIR=$1
FILTER=${2:-}
RELEASE=${RELEASE:-1}
JOBS=${JOBS:-0}
FAIL_FAST=${FAIL_FAST:-0}
TIMEOUT=${TIMEOUT:-10}
VM=${VM:-bvm}
ENGINE=${ENGINE:-zb}
EXCLUDE=${EXCLUDE:-}

[ "$RELEASE" -eq 1 ] && zig_args+=" --release=fast" || zig_args=""
zig build $zig_args || exit 1

SECONDS=0
find_args=""
[ -n "$EXCLUDE" ] && find_args+="! -ipath $EXCLUDE"
parallel_args=""
[ "$FAIL_FAST" -eq 1 ] && parallel_args+=" --halt now,fail=1" && export VERBOSE_FAIL=1
[ "$TIMEOUT" -ne 0 ] && parallel_args+=" --timeout $TIMEOUT"
[ "$JOBS" -gt 0 ] && parallel_args+=" -j$JOBS"
find $DIR -name "*.${VM}_bytecode" $find_args | grep "$FILTER" | sort | parallel $parallel_args -k --joblog parallel.log ./run-test.sh {}
code=$?

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo
echo "Summary:"
echo -e "   Time: ${SECONDS}s"
echo -e "Success: ${GREEN}$(cat parallel.log | tail -n +2 | awk '$7 == 0' | wc -l)${NC}"
echo -e "Skipped: ${YELLOW}$(cat parallel.log | tail -n +2 | awk '$7 == 4 || $7 == 3' | wc -l)${NC}"
echo -e " Failed: ${RED}$(cat parallel.log | tail -n +2 | awk '$7 == 1 || $7 == 2 || $7 > 4' | wc -l)${NC}"

rm parallel.log

exit $code