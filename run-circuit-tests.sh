#!/bin/bash
shopt -s extglob

BYTECODES=${1:-~/aztec-repos/aztec-packages/noir-projects/noir-protocol-circuits/target/tests/*}

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

SECONDS=0
parallel --joblog parallel.log ./run-test.sh {} ::: $BYTECODES

echo
echo "Summary:"
echo -e "   Time: ${SECONDS}s"
echo -e "Success: ${GREEN}$(cat parallel.log | tail -n +2 | awk '$7 == 0' | wc -l)${NC}"
echo -e " Failed: ${RED}$(cat parallel.log | tail -n +2 | awk '$7 != 0' | wc -l)${NC}"

rm parallel.log