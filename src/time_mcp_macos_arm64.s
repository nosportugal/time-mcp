; =============================================================================
; time-mcp: Native macOS arm64 (Apple Silicon) Assembly MCP Server
; =============================================================================
; Target:       macOS arm64 (Mach-O 64-bit, Apple Silicon)
; Assembler:    clang -nostdlib -e _start src/time_mcp_macos_arm64.s -o time-mcp
; Dependencies: Zero C runtime, zero libraries (raw XNU kernel svc #0x80 syscalls)
; Syscalls:     read (3), write (4), gettimeofday (116), exit (1) [class 0x2000000]
; Protocol:     Model Context Protocol (MCP) 2024-11-05 over stdio (JSON-RPC 2.0)
; Tool:         "date" -> returns UTC "YYYY-MM-DD HH:MM:SS (DDD)"
; =============================================================================

.global _start
.align 2

_start:
    // Allocate 8KB on stack (16-byte aligned):
    //   [sp, #0]    .. [sp, #4095] = inbuf  (4 KB)
    //   [sp, #4096] .. [sp, #8191] = outbuf (4 KB)
    sub     sp, sp, #8192

do_read:
    // Zero out inbuf (512 * 8 = 4096 bytes)
    mov     x0, sp
    mov     x1, #512
1:
    str     xzr, [x0], #8
    subs    x1, x1, #1
    b.ne    1b

    // Read one JSON-RPC line from stdin (up to '\n' or 4096 bytes)
    mov     x28, sp                 // base of inbuf
    mov     x20, x28                // current write pointer in inbuf
read_line:
    mov     x0, #0                  // FD 0 = stdin
    mov     x1, x20                 // buf = current pos
    mov     x2, #1                  // read 1 byte at a time so multiple piped lines don't coalesce
    movz    x16, #3                 // SYS_read = 3
    movk    x16, #0x200, lsl #16
    svc     #0x80
    b.cs    do_exit                 // Carry set = syscall error -> exit(0)
    cbz     x0, check_eof           // 0 bytes read (EOF)
    ldrb    w3, [x20], #1
    cmp     w3, #'\n'
    b.ne    read_line
    b       line_ready
check_eof:
    cmp     x20, x28
    b.eq    do_exit                 // EOF at start of line -> exit(0)
line_ready:
    sub     x19, x20, x28           // x19 = bytes in current line

    // -------------------------------------------------------------------------
    // STAGE 1: Find `"id"` (0x22646922) in inbuf. Missing -> notification
    // -------------------------------------------------------------------------
    mov     x0, sp                  // scan start = inbuf
    mov     x1, x19                 // length
    movz    w2, #0x6922             // '"i'
    movk    w2, #0x2264, lsl #16    // 'd"' -> 0x22646922
    bl      find_token
    b.ne    do_read                 // Not found -> ignore notification

    // x0 now points right after `"id"` in inbuf. Save in x20.
    mov     x20, x0

    // Set x21 = outbuf ([sp + 4096]) and copy s_prefix: `{"jsonrpc":"2.0","id":`
    add     x21, sp, #4096
    adr     x1, s_prefix
    mov     x2, #s_prefix_len
    bl      copy_bytes

    // Advance x20 past `:` and any whitespace
2:
    ldrb    w3, [x20], #1
    cmp     w3, #':'
    b.ne    2b
3:
    ldrb    w3, [x20], #1
    cmp     w3, #' '
    b.ls    3b

    // Copy ID token verbatim until `,` or `}` or control/space (<= ' ')
4:
    strb    w3, [x21], #1
    ldrb    w3, [x20], #1
    cmp     w3, #','
    b.eq    5f
    cmp     w3, #'}'
    b.eq    5f
    cmp     w3, #' '
    b.hi    4b
5:
    // Append `,"result":{`
    adr     x1, s_result
    mov     x2, #s_result_len
    bl      copy_bytes

    // -------------------------------------------------------------------------
    // STAGE 2: Find `"method"` (`"met` = 0x74656d22) & dispatch (ADR-0005)
    // -------------------------------------------------------------------------
    mov     x0, sp
    mov     x1, x19
    movz    w2, #0x6d22             // '"m'
    movk    w2, #0x7465, lsl #16    // 'et' -> 0x74656d22
    bl      find_token
    b.ne    send_close

    // Advance to `:` then opening `"` of method value
6:
    ldrb    w3, [x0], #1
    cmp     w3, #':'
    b.ne    6b
7:
    ldrb    w3, [x0], #1
    cmp     w3, #'"'
    b.ne    7b

    // Read 1st character of method name
    ldrb    w3, [x0], #1
    cmp     w3, #'i'                // "initialize"
    b.ne    check_tools

    // --- Method: initialize ---
    adr     x1, s_init
    mov     x2, #s_init_len
    b       append_and_send

check_tools:
    cmp     w3, #'t'                // "tools/list" or "tools/call"
    b.ne    send_close              // "ping" or unknown -> `{}`

    // x0 points to 2nd char ('o' of "tools/..."), so [x0, #5] is 'l' or 'c'
    ldrb    w4, [x0, #5]
    cmp     w4, #'l'                // "tools/list"
    b.ne    do_tool_call

    // --- Method: tools/list ---
    adr     x1, s_list
    mov     x2, #s_list_len
    b       append_and_send

do_tool_call:
    // --- Method: tools/call ---
    adr     x1, s_call_pre
    mov     x2, #s_call_pre_len
    bl      copy_bytes

    // -------------------------------------------------------------------------
    // CALENDAR MATH: gettimeofday (116) -> UTC Epoch Seconds in x0 (ADR-0003)
    // Note: On XNU arm64, sys_gettimeofday returns tv_sec directly in x0!
    // We also pass a scratch buffer at [sp] in x0 just in case kernel writes struct.
    // -------------------------------------------------------------------------
    mov     x0, sp                  // timeval* scratch (inbuf is no longer needed)
    mov     x1, #0                  // timezone* = NULL
    movz    x16, #116               // SYS_gettimeofday = 116
    movk    x16, #0x200, lsl #16
    svc     #0x80
    // On XNU arm64, if x0 was overwritten with 0 or tv_sec, check [sp] fallback:
    ldr     x1, [sp]
    cmp     x0, #4095
    csel    x0, x0, x1, hi          // x0 = UTC epoch seconds

    // Split epoch seconds (x0) into SS, MM, HH, Days
    mov     x1, #60
    udiv    x2, x0, x1              // x2 = total minutes
    msub    x22, x2, x1, x0         // x22 = SS (0..59)

    udiv    x3, x2, x1              // x3 = total hours
    msub    x23, x3, x1, x2         // x23 = MM (0..59)

    mov     x1, #24
    udiv    x24, x3, x1             // x24 = days since 1970-01-01
    msub    x25, x24, x1, x3        // x25 = HH (0..23)

    // Weekday index: 1970-01-01 was Thursday (index 0 in "ThuFriSatSunMonTueWed")
    mov     x1, #7
    udiv    x2, x24, x1
    msub    x26, x2, x1, x24        // x26 = days % 7 (0..6)

    // Year loop starting from 1970
    mov     x27, #1970              // x27 = year
year_loop:
    mov     x1, #365
    tst     x27, #3                 // divisible by 4? (valid 1970..2099)
    cinc    x1, x1, eq              // 366 if leap year
    cmp     x24, x1
    b.lo    year_done
    sub     x24, x24, x1
    add     x27, x27, #1
    b       year_loop
year_done:
    // Write 4-digit Year (x27): century and year-in-century
    mov     x1, #100
    udiv    x0, x27, x1             // x0 = century (20)
    msub    x28, x0, x1, x27        // x28 = year in century (26)
    bl      write_2digits
    mov     x0, x28
    bl      write_2digits
    mov     w0, #'-'
    strb    w0, [x21], #1

    // Month loop (0..11)
    adr     x1, month_days
    mov     x2, #0                  // x2 = month index (0..11)
month_loop:
    ldrb    w3, [x1, x2]            // w3 = days in month
    cmp     x2, #1                  // February?
    b.ne    chk_month
    tst     x27, #3                 // Leap year?
    cinc    w3, w3, eq
chk_month:
    cmp     x24, x3
    b.lo    month_done
    sub     x24, x24, x3
    add     x2, x2, #1
    b       month_loop
month_done:
    // Write Month (x2 + 1)
    add     x0, x2, #1
    bl      write_2digits
    mov     w0, #'-'
    strb    w0, [x21], #1

    // Write Day (x24 + 1)
    add     x0, x24, #1
    bl      write_2digits
    mov     w0, #' '
    strb    w0, [x21], #1

    // Write HH:MM:SS
    mov     x0, x25
    bl      write_2digits
    mov     w0, #':'
    strb    w0, [x21], #1

    mov     x0, x23
    bl      write_2digits
    mov     w0, #':'
    strb    w0, [x21], #1

    mov     x0, x22
    bl      write_2digits

    // Write " ("
    mov     w0, #' '
    strb    w0, [x21], #1
    mov     w0, #'('
    strb    w0, [x21], #1

    // Copy 3-letter weekday from weekdays + x26 * 3
    mov     x2, #3
    mul     x3, x26, x2
    adr     x1, weekdays
    add     x1, x1, x3
    bl      copy_bytes

    adr     x1, s_call_post
    mov     x2, #s_call_post_len

append_and_send:
    bl      copy_bytes

send_close:
    mov     w0, #'}'
    strb    w0, [x21], #1
    strb    w0, [x21], #1
    mov     w0, #'\n'
    strb    w0, [x21], #1

    // sys_write(1, outbuf, x21 - outbuf) -> XNU syscall 0x2000004
    mov     x0, #1                  // FD 1 = stdout
    add     x1, sp, #4096           // outbuf
    sub     x2, x21, x1             // length
    movz    x16, #4
    movk    x16, #0x200, lsl #16
    svc     #0x80
    b       do_read

do_exit:
    mov     x0, #0
    movz    x16, #1                 // SYS_exit = 1
    movk    x16, #0x200, lsl #16
    svc     #0x80

// -----------------------------------------------------------------------------
// HELPER: copy_bytes — Copies x2 bytes from [x1] to [x21], advancing x21
// -----------------------------------------------------------------------------
copy_bytes:
    cbz     x2, 2f
1:
    ldrb    w3, [x1], #1
    strb    w3, [x21], #1
    subs    x2, x2, #1
    b.ne    1b
2:
    ret

// -----------------------------------------------------------------------------
// HELPER: write_2digits — Writes w0 (0..99) as two ASCII digits to [x21]
// -----------------------------------------------------------------------------
write_2digits:
    mov     w3, #10
    udiv    w4, w0, w3              // w4 = tens
    msub    w5, w4, w3, w0          // w5 = ones
    add     w4, w4, #'0'
    add     w5, w5, #'0'
    strb    w4, [x21], #1
    strb    w5, [x21], #1
    ret

// -----------------------------------------------------------------------------
// HELPER: find_token — Scans [x0..x0+x1] for 4-byte token in w2 (unaligned-safe)
// Returns Z=1 (b.eq) and x0 pointing right after the 4-byte token if found.
// -----------------------------------------------------------------------------
find_token:
1:
    ldrb    w3, [x0]
    ldrb    w4, [x0, #1]
    orr     w3, w3, w4, lsl #8
    ldrb    w4, [x0, #2]
    orr     w3, w3, w4, lsl #16
    ldrb    w4, [x0, #3]
    orr     w3, w3, w4, lsl #24
    cmp     w3, w2
    b.eq    2f
    add     x0, x0, #1
    subs    x1, x1, #1
    b.ne    1b
    cmp     w2, #0                  // clear Z (w2 is non-zero ASCII token)
    ret
2:
    add     x0, x0, #4              // advance past 4-byte token
    cmp     w2, w2                  // set Z=1 (found!)
    ret

// -----------------------------------------------------------------------------
// STATIC DATA & GOLFED MCP TEMPLATES (ADR-0003, ADR-0004)
// -----------------------------------------------------------------------------
month_days:
    .byte   31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

weekdays:
    .ascii  "ThuFriSatSunMonTueWed"

s_prefix:
    .ascii  "{\"jsonrpc\":\"2.0\",\"id\":"
.set s_prefix_len, . - s_prefix

s_result:
    .ascii  ",\"result\":{"
.set s_result_len, . - s_result

s_init:
    .ascii  "\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"d\",\"version\":\"1\"}"
.set s_init_len, . - s_init

s_list:
    .ascii  "\"tools\":[{\"name\":\"date\",\"inputSchema\":{\"type\":\"object\"}}]"
.set s_list_len, . - s_list

s_call_pre:
    .ascii  "\"content\":[{\"type\":\"text\",\"text\":\""
.set s_call_pre_len, . - s_call_pre

s_call_post:
    .ascii  ")\"}]"
.set s_call_post_len, . - s_call_post
