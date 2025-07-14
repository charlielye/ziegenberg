Ziegenberg is "execution engine" for the Aztec Network.
It attempts to define in one place what can be considered the "state transition function" for Aztec.

It aims to be written with following philosophy:

- A clean, minimal reference implementation of the Aztec engine.
- Focus on readability and maintainability.
- Minimal lines of code and boilerplate.
- Highly specialised towards the Aztec use case.
- Unix philosophy. Use of pipes and file descriptors where relevant.
- Leverage advanced OS features like memory mapping, sparse files, where possible and relevant.
- A swiss army knife of small modular tools (e.g. disassembler).
- Locality of behaviour (500-1000 line files are acceptable if code is coupled and doesn't need to be separated for reuse).

You can look at bootstrap.sh to figure out the various ci related commands for:
building
testing
benchmarking

To ensure you get a rebuild when running tests provide the build type to BUILD env var.

Example to run all unit tests:
BUILD=Debug VERBOSE=1 ./bootstrap.sh test unit

Example to run a subset of unit tests matching "nargo.contract" in the name:
BUILD=Debug VERBOSE=1 ./bootstrap.sh test unit "nargo.contract"

"unit" is a test catagory. There are also tests for:
programs
protocol_circuits
contracts

The VERBOSE flag is only needed if you need to see log output.
The final argument is a test name filter.
The unit tests are named as per zigs test name.

When writing code:

- avoid rightward drift with optionals by using assigments with "orelse" style syntax and early returns.
