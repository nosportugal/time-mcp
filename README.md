<p align="center">
  <img src="media/ken-jeong-community.gif" alt="Mr. Chang holding a tiny piece of paper" width="280">
</p>

# `time-mcp` — Small Assembly MCP Server (737-Byte Linux Binary)

Inspired by the [54-byte DOS `.COM` snake game](https://github.com/donno2048/snake), **`time-mcp`** is a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server written in assembly, with separate Linux x86 ELF32 and native macOS Apple Silicon builds. Both communicate over `stdio`.

- **Linux build:** Hand-crafted overlapped ELF header, no libraries or dynamic linker, and four kernel syscalls: `sys_read`, `sys_time`, `sys_write`, `sys_exit`.
- **macOS build:** Native arm64 assembly using XNU syscalls; built with Apple's standard linker.
- **Direct MCP connection:** Clients launch the executable over `stdio`; no Docker or network port required.
- **Single tool (`date`):** Returns the live UTC timestamp formatted as `"2026-12-30 12:30:00 (Wed)"`.

---

## Measured Binary Sizes

Measured on 2026-10-14 using `wc -c` (file length, not allocated disk space):

| Target             | Binary on macOS  |                         Size |
| :----------------- | :--------------- | ---------------------------: |
| Linux x86 ELF32    | `time-mcp-linux` |                **737 bytes** |
| macOS arm64 Mach-O | `time-mcp`       | **16,872 bytes** (16.48 KiB) |

These are separate executables, not a combined universal binary. The macOS build does not add bytes to the Linux artifact. Mach-O headers, alignment, and signing contribute to the macOS file size; sizes may vary with toolchain changes.

The Linux artifact contains the overlapped header, request parser, UTC calendar conversion, lookup tables, and JSON templates. Both implementations allocate 8 KiB of input/output buffers on the stack, which does not add 8 KiB to the file.

Linux execution remains unverified: the overlapped ELF header was rejected by an earlier emulation probe, and `file` reports an invalid ELF byte order. Its measured size is not evidence of runtime compatibility.

To rebuild and measure locally:

```bash
make size
```

---

## Quick Start (Native `stdio` — macOS & Linux)

```bash
# Build native stdio binary (also assembles Linux ELF32 on macOS if NASM is installed)
make
```

Build requirements: Apple's command-line tools on macOS Apple Silicon and NASM on Linux x86/x86_64. Native macOS Intel and Linux ARM builds are not provided. The Linux target requires a kernel with 32-bit x86 support; see the runtime caveat above.

### Connecting to MCPJam / MCP Inspector / LibreChat / Claude Desktop

Configure your MCP client's `stdio` command to point directly to the compiled binary:

```json
{
  "mcpServers": {
    "time": {
      "command": "/absolute/path/to/time-mcp"
    }
  }
}
```

---

## Architecture Decision Records (ADRs)

All design decisions from our architecture session are documented in [docs/adr/README.md](docs/adr/README.md):

- [ADR-0001: Target 32-bit x86 Static ELF with 45-Byte Overlapped Header](docs/adr/0001-target-32bit-x86-static-elf.md)
- [ADR-0002: Pure Assembly & Linux Kernel Syscalls Only (Zero Child Processes)](docs/adr/0002-pure-assembly-kernel-syscalls.md)
- [ADR-0003: UTC Calendar Math (1970–2099) & 3-Letter Weekday Format](docs/adr/0003-utc-calendar-math-and-weekday-format.md)
- [ADR-0004: Golfed MCP Tool Schema & Shared JSON-RPC Envelope](docs/adr/0004-minimal-mcp-schema-and-envelope-sharing.md)
- [ADR-0005: Verbatim JSON-RPC `id` Echoing & Safe Method Dispatch](docs/adr/0005-verbatim-id-echo-and-safe-method-dispatch.md)
