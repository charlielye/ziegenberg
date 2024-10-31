#!/bin/bash
set -e

[ -n "$1" ] && ARGS+=" -Dtest-filter='$1'"
[ "$RELEASE" -eq 1 ] && ARGS+=" -Doptimize='ReleaseFast'"

cd $(dirname $0)

watchexec -c -e zig zig build test $ARGS