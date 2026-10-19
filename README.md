<p align="center">
  <img src="media/ken-jeong-community.gif" alt="Mr. Chang holding a tiny piece of paper" width="280">
</p>

# `time-mcp` — A 697-Byte Assembly MCP Server

Inspired by the [54-byte DOS `.COM` snake game](https://github.com/donno2048/snake), **`time-mcp`** is a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server written in assembly, with separate Linux x86 ELF32 and native macOS Apple Silicon builds. Both communicate over `stdio`.

- **Linux build:** Hand-crafted overlapped ELF header, no libraries or dynamic linker, and four kernel syscalls: `sys_read`, `sys_time`, `sys_write`, `sys_exit`.
- **macOS build:** Native arm64 assembly using XNU syscalls; built with Apple's standard linker.
- **Direct MCP connection:** Clients launch the executable over `stdio`; no Docker or network port required.
- **Single tool (`date`):** Returns the live UTC timestamp formatted as `"2026-12-30 12:30:00 UTC (Wed)"`.

---

## Measured Binary Sizes

Measured using `wc -c` (file length, not allocated disk space):

| Target             | Binary on macOS  |                         Size |
| :----------------- | :--------------- | ---------------------------: |
| Linux x86 ELF32    | `time-mcp-linux` |                **697 bytes** |
| macOS arm64 Mach-O | `time-mcp`       | **16,680 bytes** (16.29 KiB) |

These are separate executables, not a combined universal binary. The macOS build does not add bytes to the Linux artifact. On macOS Apple Silicon (`arm64`), the kernel enforces a mandatory 16 KiB segment page alignment (`__TEXT` / `__LINKEDIT`) plus an embedded Mach-O ad-hoc code signature, which sets a ~16 KiB floor regardless of how small the assembly instructions are.

The Linux artifact contains the overlapped header, request parser, UTC calendar conversion, lookup tables, and JSON templates. Both implementations allocate 8 KiB of input/output buffers on the stack, which does not add 8 KiB to the file. Linux places the output after the input line and a four-byte zero guard, rather than clearing the entire input buffer on every request.

To rebuild and measure locally:

```bash
make size
```

---

## Footprint & Benchmarks

Measured locally on macOS Apple Silicon (`./time-mcp` over `stdio`):

| Metric                                   |    Measured Value | Fun Context                                                              |
| :--------------------------------------- | ----------------: | :----------------------------------------------------------------------- |
| **Mr. Chang GIF vs. binary**             |  **~737x larger** | `media/ken-jeong-community.gif` (~519 KB) is 737x bigger than the server |
| **Heap allocations**                     |       **0 bytes** | Uses only an 8 KiB stack buffer (`sub esp, 8192`)                        |
| **Peak memory footprint**                |     **~1.13 MiB** | `1,163,648` bytes total OS process footprint on macOS                    |
| **Sequential round-trip (`tools/call`)** | **85.6 µs / req** | **~11,677 requests/sec** (strict 1-by-1 synchronous ping-pong)           |
| **Pipelined burst (`tools/call`)**       | **27.5 µs / req** | **~36,315 requests/sec** (10,000 live UTC calls in **275 ms**)           |
| **CPU work per request**                 |   **~20k cycles** | ~66k retired instructions (mostly the 1-byte-at-a-time `read` syscalls)  |

---

## Quick Start (Native `stdio` — macOS & Linux)

```bash
# Build native stdio binary (also assembles Linux ELF32 on macOS if NASM is installed)
make
```

Build requirements: Apple's command-line tools on macOS Apple Silicon and NASM on Linux x86/x86_64. Native macOS Intel and Linux ARM builds are not provided. The Linux target requires a kernel with 32-bit x86 support.

## Automated Tests

The regression suite is written in C and tests the assembly server over stdio.
Install the test-only compiler, `pkg-config`, and `json-c` dependencies as described
in [CONTRIBUTING.md](CONTRIBUTING.md), then run:

```sh
make test-linux  # Linux x86/x86_64, including the less-than-800-byte budget
make test-macos # macOS Apple Silicon
```

Pull-request CI runs both targets and reports before/after binary sizes. The
production executables remain pure assembly with no library dependencies.

## Try It with an Inspector

With the binary built and your Inspector already running, connect to it over **STDIO**:

| Setting | Value |
| :------ | :---- |
| Transport | `STDIO` |
| Command | Absolute path to the built executable, e.g. `/path/to/time-mcp/time-mcp` after `make` |
| Arguments | None |

If you used `make build-linux` instead, the executable is named `time-mcp-linux`. Use the native binary for your machine, not the Linux binary on macOS.

### MCP Inspector

1. Enter the settings above and click **Connect**.
2. Open **Tools** and click **List Tools**.
3. Select **date** and click **Run Tool**. It takes no arguments (`{}`).

### MCPJam Inspector

1. In your local MCPJam Inspector, add a server using the settings above and connect.
2. Open the server's tools and select **date**.
3. Run it with no arguments (`{}`).

Both should return a text result containing the current UTC timestamp, for example:

```text
2026-12-30 12:30:00 UTC (Wed)
```
