#!/bin/bash
set -e

cd $(dirname $0)

RELEASE=${RELEASE:-0}

[ -n "$1" ] && ARGS+=" -Dtest-filter='$1'"
[ "$RELEASE" -eq 1 ] && ARGS+=" -Doptimize='ReleaseFast'"

if [ -n "$REMOTE" ]; then
  watchexec -c -e zig "zig build test-exe $ARGS && scp ./zig-out/bin/tests $REMOTE:. && ssh $REMOTE 'cd /mnt/data && ~/tests 2>&1 | tee -a output.log'"
else
  watchexec -c -e zig zig build test $ARGS
fi