#!/bin/bash
shopt -s extglob

NARGO=${NARGO:-0}
NOIR_REPO=~/aztec-repos/aztec-packages/noir/noir-repo

if [ "$NARGO" -eq 1 ]; then
  echo "Compiling..."
  (cd ~/aztec-repos/aztec-packages/noir-projects/noir-protocol-circuits && $NOIR_REPO/target/release/nargo dump)
fi

./run-dir-tests.sh ~/aztec-repos/aztec-packages/noir-projects/noir-protocol-circuits/target/tests