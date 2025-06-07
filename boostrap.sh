#!/bin/bash
cd $(dirname $0)
export ci3=$PWD/aztec-packages/ci3
source $ci3/source

cmd=${1:-}
[ -n "$cmd" ] && shift

# By default aztec-packages ci system attempts to put logs in redis.
# We don't want that feature here, so we disable it.
export CI_REDIS_AVAILABLE=0

function noir_bootstrap {
  cd aztec-packages/noir
  DENOISE=1 denoise ./bootstrap.sh
}

function build_fixtures {
  cd aztec-packages/noir/noir-repo/test_programs/execution_success/1_mul
  ../../../target/release/nargo compile
  ../../../target/release/nargo execute
}

function test_cmds {
  zig build list-tests | grep -v "bench" | grep "${1:-}" | awk '{print "xxx ./zig-out/bin/tests \"" $0 "\""}'
}

function test {
  # Pipe through cat to disable status bar mode.
  test_cmds ${1:-} | parallelise | cat
}

function bench_cmds {
  zig build list-tests | grep "bench" | grep "${1:-}" | awk '{print "xxx:CPUS=32 ./zig-out/bin/tests \"" $0 "\""}'
}

function bench {
  # Pipe through cat to disable status bar mode.
  bench_cmds ${1:-} | STRICT_SCHEDULING=1 parallelise | cat
}

case "$cmd" in
  ""|build)
    (noir_bootstrap)
    (build_fixtures)
    zig build test-exe -Doptimize='ReleaseFast'
    ;;
  test|test_cmds|bench|bench_cmds)
    $cmd "$@"
    ;;
  *)
    echo "Usage: $0 {build|test}"
    exit 1
    ;;
esac