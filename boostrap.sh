#!/bin/bash
cd $(dirname $0)
export ci3=$PWD/aztec-packages/ci3
source $ci3/source

cmd=${1:-}

function noir_bootstrap {
  cd aztec-packages/noir
  export DENOISE=1
  export CI_REDIS_AVAILABLE=0
  denoise ./bootstrap.sh
}

function build_fixtures {
  cd aztec-packages/noir/noir-repo/test_programs/execution_success/1_mul
  ../../../target/release/nargo compile
  ../../../target/release/nargo execute
}

function test_cmds {
  zig build list-tests | awk '{print "xxx ./zig-out/bin/tests \"" $0 "\""}' | grep -v "bench"
}

function test {
  test_cmds | parallelise
}

function bench_cmds {
  zig build list-tests | awk '{print "xxx:CPUS=32 ./zig-out/bin/tests \"" $0 "\""}' | grep "bench"
}

function bench {
  export VERBOSE=1
  export CI_REDIS_AVAILABLE=0
  bench_cmds | STRICT_SCHEDULING=1 parallelise
}

case "$cmd" in
  ""|build)
    (noir_bootstrap)
    (build_fixtures)
    zig build test-exe -Doptimize='ReleaseFast'
    ;;
  test|test_cmds|bench|bench_cmds)
    $cmd
    ;;
  *)
    echo "Usage: $0 {build|test}"
    exit 1
    ;;
esac