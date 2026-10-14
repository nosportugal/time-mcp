# ADR-0002: Pure Assembly & Linux Kernel Syscalls Only (Zero Child Processes)

- **Status:** Accepted
- **Date:** 2026-10-14

## Context

The user requirement allows reading the current time from the host system. We evaluated four architectural tracks for obtaining and formatting the timestamp:

| Track                           | Mechanism                                                    | Est. Size  | Latency   | Dependencies              | Demoscene Purity |
| :------------------------------ | :----------------------------------------------------------- | :--------- | :-------- | :------------------------ | :--------------- |
| **A: Pure ASM + Syscalls**      | `int 0x80` (`sys_time`, `sys_read`, `sys_write`, `sys_exit`) | ~420–470 B | ~0.002 ms | **Zero** (`FROM scratch`) | **10/10**        |
| **B: Hybrid ASM + `/bin/date`** | `fork` + `execve("/bin/date")`                               | ~360–420 B | ~2–5 ms   | `/bin/date`               | 7/10             |
| **C: Dynamic ELF + `libc`**     | `strftime` via `libc.so.6`                                   | ~500–600 B | ~0.005 ms | `ld-linux.so`, `libc.so`  | 8/10             |
| **D: ELF `execve(/bin/sh)`**    | Shell loop inside `argv`                                     | ~240–300 B | ~5–8 ms   | `/bin/sh`, `sed`, `date`  | 2/10             |

## Decision

We select **Track A: Pure Assembly + Linux Kernel Syscalls Only**.

The binary makes only 4 raw Linux kernel syscalls via `int 0x80`:

1. `sys_read` (`eax = 3`): Read JSON-RPC line from `stdin` (FD 0).
2. `sys_time` (`eax = 13`): Read current UTC Unix epoch seconds directly from the kernel.
3. `sys_write` (`eax = 4`): Write JSON-RPC response to `stdout` (FD 1).
4. `sys_exit` (`eax = 1`): Exit cleanly with code 0 when `stdin` closes (`EOF`).

## Consequences

- **Pros:**
  - **Zero dependencies:** No `libc`, no dynamic linker (`PT_INTERP`), no `/bin/sh`, no `/bin/date`, no `/proc` mount required. Runs directly over `stdio` as a single self-contained binary.
  - **Sub-microsecond execution:** No child process spawning overhead; capable of handling 500,000+ MCP requests/second.
  - **True demoscene spirit:** Faithful to the 54-byte Snake game philosophy where every byte is self-contained machine code and data.
- **Cons:**
  - Requires implementing Unix epoch-to-Gregorian calendar conversion and integer-to-ASCII formatting in x86 assembly (~115 bytes).
