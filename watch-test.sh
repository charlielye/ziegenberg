#!/bin/bash
set -e

[ -n "$1" ] && FILTER="-Dtest-filter='$1'"

cd $(dirname $0)

watchexec -c -e zig zig build test $FILTER