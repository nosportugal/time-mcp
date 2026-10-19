# Contributing to `time-mcp`

Thanks for helping improve `time-mcp`. The main contribution goal is simple:

> Make the Linux server smaller without losing functionality.

The Linux x86 ELF32 executable is the primary target. Its byte size matters, but a smaller binary is only an improvement if it continues to behave as an MCP server and return the correct result. Contributions that fix bugs or improve documentation are welcome too.

## Build the Linux target

The Linux implementation is in [`src/time_mcp.asm`](src/time_mcp.asm). It is assembled directly into a static ELF32 executable with NASM; it has no library dependencies.

You need GNU Make and NASM. On Linux, run:

```sh
make build-linux
```

This creates `time-mcp-linux` and prints its size in bytes. To measure it again later:

```sh
wc -c < time-mcp-linux
```

Windows contributors can use WSL with GNU Make and NASM installed. macOS contributors are welcome, but building or testing the macOS implementation is not required for a Linux-targeted contribution.

The Linux binary requires a Linux environment with 32-bit x86 execution support. If your development environment cannot run it, please still include the build and size results, and say which checks you could not perform.

## Check functionality

The protocol tests are written in C and exercise the actual assembly executable over
stdio. Install a C compiler, `pkg-config`, and `json-c` (test-only dependencies):

```sh
# Ubuntu / Debian (plus NASM for the server)
sudo apt-get install build-essential nasm pkg-config libjson-c-dev

# macOS Apple Silicon (with Apple's command-line tools installed)
brew install pkgconf json-c
```

Run the suite for your platform:

```sh
make test-linux  # Builds Linux, checks its size, and runs protocol tests
make test-macos # Builds and tests native macOS arm64
```

`make test` builds and tests the native target. `make check-size` independently
enforces the Linux budget of at most 799 bytes, preserving the original suite's
less-than-800-byte limit. The harness uses `json-c` for strict JSON parsing;
neither it nor the C runtime is linked into the server.

The tests cover initialization, the tool schema, integer and string IDs,
notification silence, pipelined requests, ping and unknown-method fallback,
the current UTC timestamp including its weekday, and EOF with or without a final
newline. Response and overall timeouts prevent a stalled server from hanging tests.
These are focused regression checks, not full MCP conformance certification.

Pull-request CI runs the suite on Linux x86-64 and macOS arm64. Each job reports
base and PR-merge binary sizes built from source with the same toolchain; Linux
also enforces the byte budget. To change the budget intentionally, update
`LINUX_BYTE_BUDGET` in the Makefile and explain the trade-off in the PR.

You can also smoke-test the binary over MCP stdio using an inspector, following
the setup in the [README](README.md). Confirm that it:

1. Connects and responds to `initialize`.
2. Lists the `date` tool with `tools/list`.
3. Runs `date` with `tools/call` and returns the current UTC date and time in the expected format.

If your change affects another behavior, test that behavior too. In particular, size optimizations must preserve existing protocol behavior and date results.

## Keep the change focused

- Include the Linux binary's before-and-after byte counts in your pull request. Build both versions with the same toolchain and command so the comparison is meaningful.
- Describe the functionality you checked and the environment you used.
- Update the README if user-facing behavior or build instructions change.
- For significant architectural decisions, add an ADR following [`docs/adr/README.md`](docs/adr/README.md).

## Pull request checklist

- [ ] The Linux target builds with `make build-linux`.
- [ ] The before-and-after Linux binary sizes are reported.
- [ ] Native C protocol tests pass, or any testing limitation is explained.
- [ ] The Linux binary is below 800 bytes (`make check-size`), or a budget change is justified.
- [ ] Related documentation is updated, if needed.
