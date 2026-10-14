# Architecture Decision Records (ADRs)

This directory captures the architectural decisions made while designing **`time-mcp`** — a small compiled MCP (Model Context Protocol) server.

```
+-----------------------------------------------------------------------+
|                        ADR DEPENDENCY TREE                            |
+-----------------------------------------------------------------------+
|                                                                       |
|  [ADR-0001] Target 32-bit x86 Static ELF + 45-Byte Overlapped Header  |
|       |                                                               |
|       +---> [ADR-0002] Pure Assembly + Linux Kernel Syscalls Only     |
|                  |                                                    |
|                  +---> [ADR-0003] 1970-2099 Epoch Math & 3-Char Day   |
|                  |                                                    |
|                  +---> [ADR-0004] Golfed MCP Schema & Shared Envelope |
|                  |                                                    |
|                  +---> [ADR-0005] Verbatim ID Echo & Safe Dispatch    |
|                                                                       |
+-----------------------------------------------------------------------+
```

| ADR                                                           | Title                                                  | Status   | Impact on Binary Size                             |
| :------------------------------------------------------------ | :----------------------------------------------------- | :------- | :------------------------------------------------ |
| [ADR-0001](0001-target-32bit-x86-static-elf.md)               | Target 32-bit x86 Static ELF with Overlapped Header    | Accepted | Header reduced from 120B (ELF64) to **45B**       |
| [ADR-0002](0002-pure-assembly-kernel-syscalls.md)             | Pure Assembly & Kernel Syscalls (Zero Child Processes) | Accepted | Eliminates ~200B dynamic linker / `libc` overhead |
| [ADR-0003](0003-utc-calendar-math-and-weekday-format.md)      | UTC Calendar Math (1970–2099) & 3-Letter Weekday       | Accepted | Saves ~15B leap-century math & ~11B weekday table |
| [ADR-0004](0004-minimal-mcp-schema-and-envelope-sharing.md)   | Golfed MCP Tool Schema & Shared JSON-RPC Envelope      | Accepted | Saves ~75B of redundant JSON keys and prefixes    |
| [ADR-0005](0005-verbatim-id-echo-and-safe-method-dispatch.md) | Verbatim JSON-RPC `id` Echoing & Safe Method Dispatch  | Accepted | Universal client compatibility in ~38B of code    |
