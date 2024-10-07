#!/bin/bash
set -e

[ -n "$1" ] && FILTER="--test-filter $1"

cd $(dirname $0)

# if [ -z "$FILTER" ]; then
#   watchexec -c -e zig zig build test --summary all #--release=fast
# else
  watchexec -c -e zig zig test ./src/root.zig $FILTER
# fi