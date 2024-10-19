#!/bin/bash
shopt -s extglob

NARGO=${NARGO:-0}
NOIR_REPO=~/aztec-repos/aztec-packages/noir/noir-repo

# regression_4709: Produces so much bytecode it's too slow to wait for (and segfaults as needs tonnes of mem).
# is_unconstrained: Fails because it expects main to be constrained, but we force all programs to be unconstrained.
# brillig_oracle: Requires advanced foreign function support to handle mocking.
# bigint: Might need to implement blackbox support. Although maybe bignum lib is the future.
# workspace_fail: Has two projects, one which passes, one which fails. The behaviour seems right so, bad test?
if [ "$NARGO" -eq 1 ]; then
  export RAYON_NUM_THREADS=4
  echo "Compiling..."
  parallel "(cd {} && $NOIR_REPO/target/release/nargo dump)" ::: $NOIR_REPO/test_programs/execution_*/!(regression_4709|is_unconstrained|brillig_oracle|bigint|workspace_fail)
fi

./run-dir-tests.sh $NOIR_REPO/test_programs/execution_success
[ $? -ne 0 ] && [ "$FAIL_FAST" -eq 1 ] && exit 1
echo
SHOULD=fail ./run-dir-tests.sh $NOIR_REPO/test_programs/execution_failure