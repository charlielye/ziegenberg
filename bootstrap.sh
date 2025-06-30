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
  # TOML parser can't deal with empty array.
  array_oob_regression_7952
  databus_in_fn_with_empty_arr
  # Can't handle more then 1 fn yet.
  fold*
  # Workspaces, urgh.
  overlapping_dep_and_mod
  workspace*
  # Requires unstable features.
  regression_7323
  # Pure brillig doesn't pass even in nargo.
  reference_counts_*
  # Debug build blows up ram.
  ram_blowup_regression

  # TODO!
  regression_4561
  signed_double_negation
  ski_calculus
)
exclude_pattern="!($(IFS="|"; echo "${exclusions[*]}"))"

export test_programs_dir="aztec-packages/noir/noir-repo/test_programs/execution_success"
export test_tests_dir="aztec-packages/noir/noir-repo/test_programs/noir_test_success"
export test_protocol_dir="aztec-packages/noir-projects/noir-protocol-circuits/target/tests"

function noir_bootstrap {
  cd aztec-packages/noir
  DENOISE=1 denoise ./bootstrap.sh
}

# Compiles and executes a given noir test program to generate witness data.
# Creates both ACIR and pure Brillig artifacts.
function compile_and_execute {
  export RAYON_NUM_THREADS=1
  cd $1
  local name=$(basename $1)
  ../../../target/release/nargo compile --silence-warnings --force-brillig
  ../../../target/release/nargo execute --force-brillig
  mv target/$name.json target/$name.brillig.json
  mv target/$name.gz target/$name.brillig.gz
  ../../../target/release/nargo compile --silence-warnings
  ../../../target/release/nargo execute
}

function nargo_dump {
  export RAYON_NUM_THREADS=1
  cd $1
  local name=$(basename $1)
  ../../../target/release/nargo dump
}
export -f compile_and_execute nargo_dump

# Compiles and executes all noir exexution success test programs to generate witness data.
function build_fixtures {
  parallel --tag -k --line-buffer --halt now,fail=1 compile_and_execute ::: $test_programs_dir/$exclude_pattern
  parallel --tag -k --line-buffer --halt now,fail=1 nargo_dump ::: $test_tests_dir/$exclude_pattern
}

function build_noir_protocol_circuits {
  (cd aztec-packages/noir-projects/noir-protocol-circuits && yarn && yarn generate_variants && ../../noir/noir-repo/target/release/nargo dump)
}

# Builds zb, tests and lib.
# Defaults to ReleaseFast.
# For debug: ./bootstrap.sh build Debug
function build {
  zig build -Doptimize=${1:-ReleaseFast}
}

function test_cmds_unit {
  zig build list-tests | grep -v "bench" | grep "${1:-}" | awk '{print "xxx ./zig-out/bin/tests \"" $0 "\""}'
}

function test_cmds_programs {
  {
    for path in $test_programs_dir/$exclude_pattern; do
      echo "xxx check_parity $(basename $path)"
      echo "xxx check_parity_brillig $(basename $path)"
    done
    for path in $test_tests_dir/$exclude_pattern; do
      for test_path in $path/target/tests/*.cvm_bytecode; do
        echo "xxx run_program_test $(basename $path) $(basename $test_path)"
      done
    done
  } | grep "${1:-}"
}

function proto_test {
    ./zig-out/bin/zb cvm run --bytecode_path=$test_protocol_dir/$1 || [[ "$1" =~ \.fail\. ]]
}

function run_program_test {
    ./zig-out/bin/zb cvm run --bytecode_path=$test_tests_dir/$1/target/tests/$2 || [[ "$2" =~ \.fail\. ]]
}
export -f proto_test run_program_test

function test_cmds_protocol_circuits {
  for path in $test_protocol_dir/*.cvm_bytecode; do
    echo "xxx proto_test $(basename $path)"
  done | grep "${1:-}"
}

# Runs tests with debug build.
# ./bootstrap.sh test
# ./bootstrap.sh test unit [filter]
# ./bootstrap.sh test programs [filter]
function test {
  # Build debug version.
  # build Debug
  # Pipe through cat to disable status bar mode.
  {
    if [ -z "$1" ]; then
      test_cmds_unit
      test_cmds_programs
    else
      "test_cmds_$1" ${2:-}
    fi
  } | parallelise ${JOBS:-} | cat
}

function test_programs_release {
  # Build release version.
  build ReleaseFast
  # Pipe through cat to disable status bar mode.
  test_cmds_programs | parallelise ${1:-} | cat
}

function bench_cmds {
  zig build list-tests | grep "bench" | grep "${1:-}" | awk '{print "xxx:CPUS=32 ./zig-out/bin/tests \"" $0 "\""}'
}

function bench {
  # Build release version.
  build ReleaseFast
  # Pipe through cat to disable status bar mode.
  bench_cmds ${1:-} | NO_HEADER=1 VERBOSE=1 STRICT_SCHEDULING=1 parallelise | cat
}

function check_parity {
  set -e
  local path=$test_programs_dir/$1
  ./zig-out/bin/zb cvm run $path --binary --witness_path=target/$1.zb.gz
  cmp <(zcat $path/target/$1.gz) <(zcat $path/target/$1.zb.gz)
  echo "Parity check passed for $1."
}

function check_parity_brillig {
  set -e
  local path=$test_programs_dir/$1
  ./zig-out/bin/zb cvm run $path --binary --artifact_path=target/$1.brillig.json --witness_path=target/$1.zb.brillig.gz
  cmp <(zcat $path/target/$1.brillig.gz) <(zcat $path/target/$1.zb.brillig.gz)
  echo "Parity check passed for $1."
}

export -f check_parity check_parity_brillig

case "$cmd" in
  ""|full)
    (noir_bootstrap)
    (build_fixtures)
    build ${1:-}
    ;;
  *)
    $cmd "$@"
    ;;
esac