# `time-mcp` — The World's Smallest Compiled MCP Server (~490 Bytes)

Inspired by the [54-byte DOS `.COM` snake game](https://github.com/donno2048/snake), **`time-mcp`** is a fully compliant [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server written in pure 32-bit x86 Linux assembly with a hand-crafted 45-byte overlapped ELF header.

- **Zero dependencies:** No `libc`, no dynamic linker (`ld-linux.so`), no `/bin/sh`, no `/bin/date`.
- **100% pure machine code + 4 Linux kernel syscalls:** `sys_read`, `sys_time`, `sys_write`, `sys_exit`.
- **Universal MCP Client support:** Works with LibreChat, MCPJam, MCP Inspector, Claude Desktop, and VS Code Copilot.
- **Single tool (`date`):** Returns the live UTC timestamp formatted as `"2026-12-30 12:30:00 (Wed)"`.

---

## Binary Anatomy & Byte Map

```
+=============================================================================+
|                     time-mcp ELF32 BINARY (~490 BYTES)                      |
+=============================================================================+
| Offset       | Size  | Section / Component                                  |
+--------------+-------+------------------------------------------------------+
| 0x000..0x02C |  45 B | Overlapped ELF32 Header + Program Header             |
|              |       | (Includes 10 B of `_start` code inside Ehdr padding!)|
+--------------+-------+------------------------------------------------------+
| 0x02D..0x09F | ~115B | JSON-RPC 2.0 Parser & Method Dispatcher              |
|              |       | - Verbatim `"id"` extraction (int, string, UUID)     |
|              |       | - Notification filter (`notifications/initialized`)  |
|              |       | - Safe `"method"` dispatch (`i`, `t`+`l`, `t`+`c`)   |
|              |       | - Automatic `{}` fallback for `ping` & unknown calls |
+--------------+-------+------------------------------------------------------+
| 0x0A0..0x12F | ~135B | UTC Epoch-to-Calendar Math (`sys_time` -> ASCII)     |
|              |       | - Seconds/Minutes/Hours/Days division                |
|              |       | - 1970-2099 leap-year loop & month-length lookup     |
|              |       | - 2-digit BCD-to-ASCII (`aam` + `add ax, '00'`)      |
+--------------+-------+------------------------------------------------------+
| 0x130..0x1EA | ~195B | Static Lookup Tables & Factorized JSON Templates     |
|              |       | - `month_days` (12 B) & `"ThuFriSatSunMonTueWed"`    |
|              |       | - Shared envelope: `{"jsonrpc":"2.0","id":`          |
|              |       | - Payloads: `initialize`, `tools/list`, `tools/call` |
+--------------+-------+------------------------------------------------------+
| BSS (RAM)    |   0 B | `inbuf` (4 KB) + `outbuf` (4 KB) via `p_memsz`       |
+=============================================================================+
```

---

## Request Flow Architecture

```
MCP Client (LibreChat / MCPJam / Inspector)
  |
  |  stdin (JSON-RPC line)
  v
+-------------------------------------------------------------------+
| 1. sys_read(0, inbuf, 4096)                                       |
|    EOF? ---> sys_exit(0)                                          |
+-------------------------------------------------------------------+
  |
  v
+-------------------------------------------------------------------+
| 2. Scan for `"id"` (0x22646922)                                   |
|    Not found? ---> Notification (`notifications/initialized`)     |
|                    Silently ignore & loop back to (1)             |
|    Found?     ---> Copy ID token verbatim into response envelope  |
+-------------------------------------------------------------------+
  |
  v
+-------------------------------------------------------------------+
| 3. Scan for `"method"` & inspect method name characters           |
|                                                                   |
|    +-- 'i' ("initialize") ---> Emit protocolVersion & serverInfo  |
|    +-- 't' + 'l' ("tools/list") -> Emit `"name":"date"` schema    |
|    +-- 't' + 'c' ("tools/call") -> Call sys_time(13), format      |
|    |                               "YYYY-MM-DD HH:MM:SS (DDD)"    |
|    +-- default ("ping", etc.) ---> Emit empty result `{}`         |
+-------------------------------------------------------------------+
  |
  |  stdout (`sys_write`)
  v
MCP Client receives `{"jsonrpc":"2.0","id":<ID>,"result":{...}}\n`
```

---

## Quick Start (macOS / Linux)

### Option 1: Using Docker (Works on macOS Apple Silicon / Intel & Linux)

```bash
# Build the binary and run the automated MCP compliance + byte-size test suite
make docker-test

# Build the ~490-byte `FROM scratch` Docker image
make docker-build

# Run as an interactive MCP server over stdio
docker run --rm -i --platform linux/amd64 time-mcp:latest
```

### Option 2: Native Linux Build

```bash
make test
```

### Connecting to MCPJam / MCP Inspector / LibreChat

Configure your MCP client's `stdio` command:

```json
{
  "mcpServers": {
    "time": {
      "command": "docker",
      "args": [
        "run",
        "--rm",
        "-i",
        "--platform",
        "linux/amd64",
        "time-mcp:latest"
      ]
    }
  }
}
```

_(Or point `"command"` directly to `/path/to/time-mcp` when running on Linux)._

---

## Architecture Decision Records (ADRs)

All design decisions from our architecture session are documented in [docs/adr/README.md](docs/adr/README.md):

- [ADR-0001: Target 32-bit x86 Static ELF with 45-Byte Overlapped Header](docs/adr/0001-target-32bit-x86-static-elf.md)
- [ADR-0002: Pure Assembly & Linux Kernel Syscalls Only (Zero Child Processes)](docs/adr/0002-pure-assembly-kernel-syscalls.md)
- [ADR-0003: UTC Calendar Math (1970–2099) & 3-Letter Weekday Format](docs/adr/0003-utc-calendar-math-and-weekday-format.md)
- [ADR-0004: Golfed MCP Tool Schema & Shared JSON-RPC Envelope](docs/adr/0004-minimal-mcp-schema-and-envelope-sharing.md)
- [ADR-0005: Verbatim JSON-RPC `id` Echoing & Safe Method Dispatch](docs/adr/0005-verbatim-id-echo-and-safe-method-dispatch.md)
