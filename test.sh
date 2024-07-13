#!/bin/bash
set -e

FILE=${1}
[ -n "$2" ] && FILTER="--test-filter $2"

cd $(dirname $0)

if [ -z "$FILE" ]; then
  watchexec -e zig zig build test
else
  watchexec -e zig zig test $FILE $FILTER
fi