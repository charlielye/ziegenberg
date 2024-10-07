#!/bin/bash
set -u
shopt -s extglob

BYTECODES=$1
RELEASE=${RELEASE:-1}

[ "$RELEASE" -eq 1 ] && zig_args+=" --release=fast" || zig_args=""
zig build $zig_args

SECONDS=0
find $BYTECODES -name "*.bytecode" | parallel --joblog parallel.log ./run-test.sh {}

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo
echo "Summary:"
echo -e "   Time: ${SECONDS}s"
echo -e "Success: ${GREEN}$(cat parallel.log | tail -n +2 | awk '$7 == 0' | wc -l)${NC}"
echo -e " Failed: ${RED}$(cat parallel.log | tail -n +2 | awk '$7 != 0' | wc -l)${NC}"

rm parallel.log