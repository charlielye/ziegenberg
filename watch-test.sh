#!/bin/bash
set -e

cd $(dirname $0)

RELEASE=${RELEASE:-0}

if [ -n "$REMOTE" ]; then
  [ -n "$1" ] && ARGS+=" --test-filter '$1'"
  [ "$RELEASE" -eq 1 ] && ARGS+=" -O ReleaseFast"

  watchexec -c -e zig "zig test --test-no-exec -femit-bin=zig-out/bin/tests $ARGS -lc ./src/lib.zig && scp ./zig-out/bin/tests $REMOTE:. && ssh $REMOTE bash -c './tests && cat merkle_tree_data/layer_39.dat | xxd -c 32 -g 32 -R never -ps | tee -a output.log'"
else
  [ -n "$1" ] && ARGS+=" -Dtest-filter='$1'"
  [ "$RELEASE" -eq 1 ] && ARGS+=" -Doptimize='ReleaseFast'"

  watchexec -c -e zig zig build test $ARGS
fi