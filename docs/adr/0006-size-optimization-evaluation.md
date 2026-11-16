# ADR-0006: Size Optimization Evaluation

- **Status:** Accepted
- **Date:** 2026-11-16

## Context

The request was to evaluate how to shrink the `time-mcp` server (reported as "currently 700 KB") and propose techniques for both Linux ELF32 and macOS arm64. The initial rebuild from HEAD established much smaller baselines; a second instruction-level audit then found three Linux reductions that preserve the protocol behavior.

- **Linux ELF32: 697 B initial baseline; 688 B after the accepted reductions.** `LINUX_BYTE_BUDGET` remains 799. The optimized byte accounting from the `nasm -l` listing is:
  - 45 B overlapped ELF32 header + program header (ADR-0001) at bytes 0x00–0x2C, plus 1 B of `e_phnum` padding at 0x2D;
  - 387 B of code at 0x2E–0x1B0;
  - 255 B of data at 0x1B1–0x2AF: `s_prefix` 22, `s_result` 11, `s_call_pre` 34, `month_days` 12, `weekdays` 21, `s_init` 98, `s_list` 57.
- **macOS arm64: 16,672 B** (clang `-Wl,-e,_start,-S,-x,-no_function_starts,-no_data_in_code_info,-no_exported_symbols,-no_fixup_chains`), consisting of `__TEXT` 16,384 B (one 16 KB arm64 page, holding 0x443 = 1,091 B of `__text` at file offset 728) and `__LINKEDIT` 288 B (export trie 8, strtab 8, ad-hoc signature 272). Rebuilding with a different output filename shifts the total by about 8 B because the ad-hoc signature embeds the identifier derived from it.

The 45-byte overlapped production ELF is intentionally accepted by real Linux kernels but rejected by qemu-i386 and the local container loaders. To make code-level changes executable locally, validation builds the same MCP body behind a standard ELF32 header and runs it in a `linux/386` container. The production header is unchanged from the CI-proven baseline.

## Decision

Apply the three behavior-preserving Linux reductions below. The resulting golfed ELF32 is **688 B**, a 9 B reduction from 697 B, with 111 B of headroom below `LINUX_BYTE_BUDGET`.

| Technique | Result (evidence) |
| :--- | :--- |
| Inline both `scan_colon` calls (Linux) | Each 5 B `call` becomes the same 5 B `lodsb`/`cmp`/short-`jne` loop; deleting the now-unused 6 B helper saves **6 B**. |
| Keep days in `ebp`, year in `ebx` (Linux) | `mov bx, 1969` and the swapped day-loop operations keep the same encodings; `test bl, 3` is 3 B instead of `test bp, 3` at 5 B. Saves **2 B**. |
| Load the 60-second divisor through `cl` (Linux) | The preceding `rep movsb` exhausts `ecx`, so `mov cl, 60` creates a full `ecx=60`. Replaces 3 B `push 60; pop ecx`, saving **1 B**. |
| macOS `-nostdlib`, `-static` | Does not load: ld error "dynamic executables or dylibs must link with libSystem.dylib" (`-nostdlib`); `-static` output is "Bad executable". |
| macOS `-Wl,-no_uuid` | Same size 16,672 B; dyld refuses: "missing LC_UUID load command". |
| macOS `-Wl,-pagezero_size,0x4000` | "Malformed Mach-o file". |
| macOS Mach-O repack with unaligned or shortened `__TEXT`/`__LINKEDIT` | Kernel rejects ("Malformed Mach-o file") for `__TEXT` filesize 0x800/0x1000 and for unaligned `__LINKEDIT` fileoff; only 0x4000 works, and `codesign -f -s -` after repack grew the file to 34,720 B. Floor is one 16 KB page + signature, about 16.4 KB; reachable gain at most 288 B for large complexity. Not pursued. |
| macOS `-dead_strip`, extra strip flags | No size change (already `-S -x -no_function_starts -no_data_in_code_info -no_exported_symbols -no_fixup_chains`). |
| Smaller stack buffers (8 KB to 1.5 KB) | Runtime-only. `sub esp, imm32` is 6 B for any value above 127 on x86; arm64 `sub sp,sp,#N` is 4 B either way. No file-size effect. |
| Remove arm64 4 KB zeroing loop | Real instruction saving (~20 B) but the macOS file stays 16,672 B because of page alignment; and the Linux code already avoids zeroing. Not worth a behavior-risk change. |
| `repne scasd` token search (Linux) | Invalid: stride is 4 B, so it misses tokens at unaligned offsets. |
| Bitmask month lengths (Linux) | Built and measured against the 697 B baseline: 708 B (larger); it remains larger than the accepted 688 B build. |
| Move tools/call block to fall through into `.send_close` (Linux) | Saves 3 B on the one `jmp`, but the two other `jne .send_close` short jumps become near jumps (+8 B): net +5 B. |
| `inc eax` for exit (Linux) | Would save 2 B but breaks the negative-errno read-error path that currently exits cleanly. Rejected as a behavior regression. |
| Byte-register replacements for remaining `push imm8; pop r32` sites | Unsafe. At the read setup, `eax` and `edx` can retain upper bits from a response longer than 255 B; at `sys_time`, `find_token`'s `lodsd` leaves token bytes in upper `eax`; `ebx` is `s_call_pre` at write; and the exit path can retain negative errno bits. |
| Era-based (146097-day) calendar algorithm | Larger than the year/month loops; ADR-0003's 1970–2099 rule stays. |
| Executable compression | Decompressor stub exceeds the 688 B payload; not applicable. |
| Dropping `serverInfo`, `capabilities`, or `inputSchema` | Violates MCP schema; ADR-0004 keeps them. |

## Consequences

- The Linux build is 688 B with 111 B of budget headroom. The accepted reductions are protocol-tested; candidates that rely on partial-register writes remain rejected unless their full-register invariant is proven for arbitrary permitted IDs and I/O errors.
- The standard-header `linux/386` test variant runs the same MCP code body and passed initialize, notification silence/tools-list schema, live tools/call timestamp/weekday, pipelining/ping/unknown methods/zero and negative IDs, EOF shutdown, and empty stdin. The golfed header itself remains unchanged and is executed by native Linux CI.
- The macOS size remains fixed by the 16 KB arm64 page plus the mandatory ad-hoc signature: 16,384 B of `__TEXT` + 288 B of `__LINKEDIT`. Code-size changes below ~16 KB of `__text` cannot move the file size at all.
- A further substantial reduction would need a protocol-surface change (dropping or shortening MCP-required fields), which is a decision for the maintainers, not a size-optimization task.
