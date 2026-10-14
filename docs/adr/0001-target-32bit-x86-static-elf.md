# ADR-0001: Target 32-bit x86 Static ELF with 45-Byte Overlapped Header

- **Status:** Accepted
- **Date:** 2026-10-14

## Context

Inspired by the [54-byte DOS `.COM` snake game](https://github.com/donno2048/snake), our goal is to build a small compiled MCP server binary.

Unlike 16-bit MS-DOS `.COM` files (which have a 0-byte header), modern operating systems require an executable header:

- **Windows PE (`.exe`):** Minimum valid overlapped MZ + PE header is ~97–268 bytes.
- **macOS Mach-O (64-bit):** Minimum `mach_header_64` + `LC_UNIXTHREAD` / `LC_MAIN` is ~168+ bytes (and strict codesigning/page-zero rules on Apple Silicon).
- **Linux ELF64 (`x86_64`):** Standard `Ehdr` (64B) + `Phdr` (56B) = 120 bytes (can be overlapped down to ~64 bytes).
- **Linux ELF32 (`i386`):** Standard `Ehdr` (52B) + `Phdr` (32B) = 84 bytes, which can be overlapped down to **45 bytes** while executing on standard 64-bit Linux kernels via `CONFIG_IA32_EMULATION=y`.

Additionally, 32-bit x86 instructions are denser than x86-64:

- Single-byte `inc reg` / `dec reg` (`0x40`–`0x4F`) exist in 32-bit mode (repurposed as REX prefixes in 64-bit mode).
- `push imm8` / `pop reg` pairs initialize 32-bit registers in 3 bytes without REX overhead.
- `pushad` / `popad` save and restore all 8 general-purpose registers in 1 byte each.

## Decision

We target a **32-bit x86 Linux static ELF executable (`elf_i386`)** assembled directly from raw NASM `bin` format (`nasm -f bin`), embedding a hand-crafted **45-byte overlapped ELF header + Program Header** (with executable code embedded directly inside unused `Ehdr` padding bytes). For native `stdio` execution on macOS Apple Silicon (`arm64`), we also provide a zero-libc native Mach-O assembly companion (`src/time_mcp_macos_arm64.s`).

```
Byte Offset:  0                   16                  32          45
              +-------------------+-------------------+-----------+
ELF32 Ehdr:   | 7F 'E' 'L' 'F' .. | e_type..e_entry   | overlapped|
              +-------------------+-------------------+-----------+
ELF32 Phdr:       | p_type=1  p_offset=0  p_vaddr ... | p_memsz   |
                  +-----------------------------------+-----------+
                  ^ Phdr starts at offset 4 (inside e_ident padding!)
```

## Consequences

- **Pros:**
  - Achieves the theoretical minimum native executable header floor on Linux (**45 bytes**, with executable instructions stuffed into unused header fields).
  - Single-command compilation (`nasm -f bin src/time_mcp.asm -o time-mcp`) with zero linker bloat.
- **Cons:**
  - Requires a Linux kernel with 32-bit x86 support (`ia32_emulation`) or a lightweight container (`FROM scratch`) when running on macOS/Windows hosts.
