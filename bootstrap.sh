#!/bin/bash
cd $(dirname $0)
export ci3=$PWD/aztec-packages/ci3
source $ci3/source

cmd=${1:-}
[ -n "$cmd" ] && shift

# By default aztec-packages ci system attempts to put logs in redis.
# We don't want that feature here, so we disable it.
export CI_REDIS_AVAILABLE=0

# Think something sus is going on with memsuspend on parallel.
# This shouldn't really make a difference but without performance sucks.
export MEMSUSPEND=0

# With no redis for logs, we want to be sure to dump failure logs to terminal.
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
  ski_calculus
  # Pure brillig doesn't pass even in nargo.
  reference_counts_*
  # Debug build blows up ram.
  ram_blowup_regression
  # Tests that require inputs?
  signed_double_negation
)
exclude_pattern="!($(IFS="|"; echo "${exclusions[*]}"))"

export test_programs_dir="aztec-packages/noir/noir-repo/test_programs/execution_success"
export test_tests_dir="aztec-packages/noir/noir-repo/test_programs/noir_test_success"
export test_protocol_dir="aztec-packages/noir-projects/noir-protocol-circuits/target/tests"
export test_contracts_dir="aztec-packages/noir-projects/noir-contracts/target/tests"

########################################################################################################################
# BUILD COMMANDS
# -------------
###
function noir_bootstrap {
  cd aztec-packages/noir/noir-repo
  cargo build --release --bin nargo
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
  ../../../target/release/nargo dump
}
export -f compile_and_execute nargo_dump

function build_noir_projects {
  (cd aztec-packages/noir-projects/noir-protocol-circuits &&
    git clean -fdx &&
    yarn &&
    yarn generate_variants &&
    ../../noir/noir-repo/target/release/nargo dump)
  (cd aztec-packages/noir-projects/noir-contracts &&
    git clean -fdx &&
    ../../noir/noir-repo/target/release/nargo dump)
}

# Compiles and executes all noir execution_success test programs to generate witness data.
# Uses nargo to dump out all noir_test_success test bytecode.
# Uses nargo to dump out all protocol circuits test bytecode.
# Uses nargo to dump out all aztec contracts test bytecode.
function build_fixtures {
  (cd $test_programs_dir && git clean -fdx)
  (cd $test_tests_dir && git clean -fdx)
  parallel --tag -k --line-buffer --halt now,fail=1 compile_and_execute ::: $test_programs_dir/$exclude_pattern
  parallel --tag -k --line-buffer --halt now,fail=1 nargo_dump ::: $test_tests_dir/$exclude_pattern
  build_noir_projects
}

# Builds zb, tests and lib.
# Defaults to ReleaseFast.
# For debug: ./bootstrap.sh build Debug
function build {
  zig build -Doptimize=${1:-ReleaseFast}
}

########################################################################################################################
# TEST COMMANDS
# -------------
# Outputs different catagories of test commands to be piped into parallel.
# Follows the structure as expected by ci3's run_test_cmd script.
###
function test_cmds_unit {
  zig build list-tests | grep -v "bench" | grep "${1:-}" | awk '{print "xxx ./zig-out/bin/tests \"" $0 "\""}'
}

function test_cmds_programs {
  {
    for path in $test_programs_dir/$exclude_pattern; do
      echo "xxx check_witness_parity $(basename $path)"
      echo "xxx check_witness_parity_brillig $(basename $path)"
    done
    for path in $test_tests_dir/$exclude_pattern; do
      for test_path in $path/target/tests/*.cvm_bytecode; do
        echo "xxx run_program_test $(basename $path) $(basename $test_path)"
      done
    done
  } | grep "${1:-}"
}

function test_cmds_protocol_circuits {
  for path in $test_protocol_dir/*.cvm_bytecode; do
    echo "xxx proto_test $(basename $path)"
  done | grep "${1:-}"
}

function test_cmds_contracts {
  {
    for path in $test_tests_dir/$exclude_pattern; do
      for test_path in $path/target/tests/*.cvm_bytecode; do
        echo "xxx run_program_test $(basename $path) $(basename $test_path)"
      done
    done
  } | grep "${1:-}"
}

function test_cmds_bench {
  zig build list-tests | grep "bench" | grep "${1:-}" | awk '{print "xxx:CPUS=32 ./zig-out/bin/tests \"" $0 "\""}'
}

########################################################################################################################
# TEST FUNCTIONS
# --------------
# These are the actual test command functions.
# test_cmds_* functions output variations of calls to these commands.
# The test function then pipes them into parallel.
# You can also execute them directly via bootstrap.sh e.g:
#   ./bootstrap.sh proto_test blob__tests__test_full_blobs.pass.cvm_bytecode
#   ./bootstrap.sh run_program_test mock_oracle test_mock.pass.cvm_bytecode
#   ./bootstrap.sh check_witness_parity bit_not
###
function proto_test {
    ./zig-out/bin/zb cvm run --bytecode_path=$test_protocol_dir/$1 || [[ "$1" =~ \.fail\. ]]
}

function run_program_test {
    ./zig-out/bin/zb cvm run --bytecode_path=$test_tests_dir/$1/target/tests/$2 "${@:3}" || [[ "$2" =~ \.fail\. ]]
}

function check_witness_parity {
  set -e
  local path=$test_programs_dir/$1
  ./zig-out/bin/zb cvm run $path --binary --witness_path=target/$1.zb.gz
  cmp <(zcat $path/target/$1.gz) <(zcat $path/target/$1.zb.gz)
  echo "Parity check passed for $1."
}

function check_witness_parity_brillig {
  set -e
  local path=$test_programs_dir/$1
  ./zig-out/bin/zb cvm run $path --binary --artifact_path=target/$1.brillig.json --witness_path=target/$1.zb.brillig.gz
  cmp <(zcat $path/target/$1.brillig.gz) <(zcat $path/target/$1.zb.brillig.gz)
  echo "Parity check passed for $1."
}

export -f check_witness_parity check_witness_parity_brillig proto_test run_program_test

########################################################################################################################
# TEST ENTRYPOINT
# ---------------
# Runs tests with debug build.
#   ./bootstrap.sh test
#   ./bootstrap.sh test unit [filter]
#   ./bootstrap.sh test programs [filter]
#   ./bootstrap.sh test protocol_circuits [filter]
#   ./bootstrap.sh test contracts [filter]
###
function test {
  # Build debug version.
  # build Debug

  # Pipe through cat to disable status bar mode.
  {
    if [ -z "${1:-}" ]; then
      test_cmds_unit
      test_cmds_programs
      test_cmds_protocol_circuits
      # test_cmds_contracts
    else
      "test_cmds_$1" ${2:-}
    fi
  } | parallelise ${JOBS:-} | cat
}

########################################################################################################################
# BENCHMARK ENTRYPOINT
# --------------------
# Performs a release build first.
# Runs all benchmarks through the "strict scheduler".
# This ensures dedicated cpu cores for each benchmark.
#   ./bootstrap.sh bench [filter]
###
function bench {
  # Build release version.
  build ReleaseFast
  # Pipe through cat to disable status bar mode.
  test_cmds_bench ${1:-} | NO_HEADER=1 VERBOSE=1 STRICT_SCHEDULING=1 parallelise | cat
}

########################################################################################################################
# MAIN COMMAND DISPATCH
# --------------------
# Default if no command given is to build everything.
# Otherwise call the requested function and forward any arguments.
###
case "$cmd" in
  "")
    (noir_bootstrap)
    (build_fixtures)
    build ${1:-}
    ;;
  *)
    $cmd "$@"
    ;;
esac