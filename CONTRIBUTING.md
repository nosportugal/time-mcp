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

After building, smoke-test the binary over MCP stdio using an inspector, following the setup in the [README](README.md). Confirm that it:

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
- [ ] MCP behavior was smoke-tested, or any testing limitation is explained.
- [ ] Related documentation is updated, if needed.
