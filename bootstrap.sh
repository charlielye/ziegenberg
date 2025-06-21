#!/bin/bash
cd $(dirname $0)
export ci3=$PWD/aztec-packages/ci3
source $ci3/source

cmd=${1:-}
[ -n "$cmd" ] && shift

# By default aztec-packages ci system attempts to put logs in redis.
# We don't want that feature here, so we disable it.
export CI_REDIS_AVAILABLE=0

export DUMP_FAIL=1

# Noir test program exclusions.
exclusions=(
  array_oob_regression_7952 # TOML parser can't deal with empty array.
  databus_in_fn_with_empty_arr # TOML parser can't deal with empty array.
  fold* # Can't handle more then 1 fn yet.
  overlapping_dep_and_mod # Workspaces, urgh.
  ram_blowup_regression # Blows up.
  regression_7323 # Requires unstable features.
  workspace* # Workspaces, urgh.
)
exclude_pattern="!($(IFS="|"; echo "${exclusions[*]}"))"

export test_programs_dir="aztec-packages/noir/noir-repo/test_programs/execution_success"

function noir_bootstrap {
  cd aztec-packages/noir
  DENOISE=1 denoise ./bootstrap.sh
}

function compile_and_execute {
  export RAYON_NUM_THREADS=1
  cd $1
  local name=$(basename $1)
  ../../../target/release/nargo compile --silence-warnings --force-brillig
  ../../../target/release/nargo execute
  mv target/$name.json target/$name.brillig.json
  mv target/$name.gz target/$name.brillig.gz
  ../../../target/release/nargo compile --silence-warnings
  ../../../target/release/nargo execute
}
export -f compile_and_execute

function build_fixtures {
  parallel --tag -k --line-buffer --halt now,fail=1 compile_and_execute ::: $test_programs_dir/$exclude_pattern
}

function test_cmds {
  zig build list-tests | grep -v "bench" | grep "${1:-}" | awk '{print "xxx ./zig-out/bin/tests \"" $0 "\""}'
}

function test {
  # Pipe through cat to disable status bar mode.
  test_cmds ${1:-} | parallelise | cat
}

function test_program_cmds {
  for path in $test_programs_dir/$exclude_pattern; do
    echo "xxx check_parity $(basename $path)"
  done
}

function test_programs {
  # Pipe through cat to disable status bar mode.
  test_program_cmds | parallelise ${1:-} | cat
}

function bench_cmds {
  zig build list-tests | grep "bench" | grep "${1:-}" | awk '{print "xxx:CPUS=32 ./zig-out/bin/tests \"" $0 "\""}'
}

function bench {
  # Pipe through cat to disable status bar mode.
  bench_cmds ${1:-} | STRICT_SCHEDULING=1 parallelise | cat
}

function check_parity {
  set -e
  # zig build -Doptimize=Debug
  local path=$test_programs_dir/$1
  zb cvm run $path --binary
  cmp <(zcat $path/target/$1.gz) <(zcat $path/target/$1.zb.gz)
  echo "Parity check passed for $1."
}
export -f check_parity

case "$cmd" in
  ""|build)
    (noir_bootstrap)
    (build_fixtures)
    zig build test-exe -Doptimize='ReleaseFast'
    ;;
  build_fixtures|test|test_cmds|bench|bench_cmds|check_parity|test_programs|test_program_cmds)
    $cmd "$@"
    ;;
  *)
    echo "Usage: $0 {build|test}"
    exit 1
    ;;
esac