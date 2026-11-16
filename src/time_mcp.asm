; =============================================================================
; time-mcp: Small Compiled MCP Server
; =============================================================================
; Target:      Linux x86 (32-bit Static ELF, IA32 / x86_64 compatible)
; Assembler:   nasm -f bin src/time_mcp.asm -o time-mcp && chmod +x time-mcp
; Dependencies: NONE (0 libraries, 0 child processes, raw int 0x80 syscalls)
; Protocol:    Model Context Protocol (MCP) 2024-11-05 over stdio (JSON-RPC 2.0)
; Tool:        "date" -> returns UTC "YYYY-MM-DD HH:MM:SS UTC (DDD)"
; =============================================================================

BITS 32
            org     0x08048000

; -----------------------------------------------------------------------------
; 45-BYTE OVERLAPPED ELF32 HEADER + PROGRAM HEADER (ADR-0001)
; -----------------------------------------------------------------------------
ehdr:
            db      0x7F, "ELF"         ; 0x00: e_ident[0..3] magic
phdr:                                   ; --- Phdr overlaps at offset 0x04! ---
            dd      1                   ; 0x04: p_type = PT_LOAD (1)    | e_ident[4..7]
            dd      0                   ; 0x08: p_offset = 0            | e_ident[8..11]
            dd      $$                  ; 0x0C: p_vaddr = 0x08048000    | e_ident[12..15]
            dw      2                   ; 0x10: e_type = ET_EXEC (2)    | p_paddr[0..1]
            dw      3                   ; 0x12: e_machine = EM_386 (3)  | p_paddr[2..3]
            dd      filesize            ; 0x14: p_filesz = filesize     | e_version
            dd      _start              ; 0x18: e_entry = _start        | p_memsz (>= filesz + 8KB BSS!)
            dd      4                   ; 0x1C: e_phoff = 4             | p_flags = 7 (PF_R|PF_W|PF_X)

; -----------------------------------------------------------------------------
; ENTRY POINT EMBEDDED INSIDE UNUSED ELF HEADER FIELDS (0x20..0x29)
; -----------------------------------------------------------------------------
_start:
            ; Allocate 8KB writable scratch space on stack:
            ;   [esp]        .. [esp+4095] = inbuf  (4 KB)
            ;   outbuf follows the input line within the 8KB allocation
            mov     bh, 32              ; 0x20: [2B] ebx = 8192 (Linux ELF execve starts with ebx = 0)
            sub     esp, ebx            ; 0x22: [2B] 8KB writable buffers on stack
do_read:
            xor     ebx, ebx            ; 0x24: [2B] FD 0 = stdin
            lea     edx, [ebx + 1]      ; 0x26: [3B] edx = 1 byte
            db      0xB8                ; 0x29: mov eax, imm32 consumes the next fields
            dw      0x20                ; 0x2A: e_phentsize = 32 bytes
            dw      1                   ; 0x2C: e_phnum = 1

; -----------------------------------------------------------------------------
; MAIN MCP STDIO LOOP (ADR-0002, ADR-0005)
; -----------------------------------------------------------------------------
            mov     edi, esp            ; edi = inbuf
.read_char:
            mov     ecx, edi            ; ecx = current byte in inbuf
            push    3
            pop     eax                 ; syscall 3 = sys_read(0, ecx, 1)
            int     0x80
            test    eax, eax
            jle     short .check_eof
            mov     al, 10              ; '\n'?
            scasb
            jne     short .read_char
.check_eof:
            cmp     edi, esp            ; any bytes read (or '\n' just scanned)?
            jne     short .line_ready   ; non-empty line -> process it!
            push    1
            pop     eax                 ; EOF on empty line -> sys_exit(0) (ebx is already 0!)
            int     0x80
.line_ready:
            mov     ebp, edi
            sub     ebp, esp            ; ebp = line length
            mov     [edi], ebx          ; zero-pad token scans without clearing the buffer
            scasd

            ; -----------------------------------------------------------------
            ; STAGE 1: Find `"id"` in inbuf. If missing -> notification (ignore)
            ; -----------------------------------------------------------------
            mov     esi, esp            ; esi = inbuf
            mov     edx, 0x22646922     ; '"id"' in little-endian: 0x22 'i' 'd' 0x22
            call    find_token
.to_do_read:
            jne     short do_read       ; Not found -> notification (e.g. initialized), ignore!

            ; EDI follows the input line. Save outbuf start on stack for sys_write.
            push    edi                 ; [stack: outbuf]
            mov     edx, esi            ; save position right after `"id"` in inbuf
            mov     esi, s_prefix
            mov     cl, s_prefix_len
            rep     movsb               ; leaves ESI = s_result!
            xchg    esi, edx            ; esi = inbuf pointer, edx = s_result

            ; Advance past `:` and any whitespace after `"id"`
.skip_id_sep:
            lodsb
            cmp     al, ':'
            je      short .skip_id_sep
            cmp     al, ' '
            jbe     short .skip_id_sep

            ; Copy ID token verbatim until `,` or `}` or control char (<= 0x20)
.copy_id:
            stosb
            lodsb
            cmp     al, ','
            je      short .id_done
            cmp     al, '}'
            je      short .id_done
            cmp     al, ' '
            ja      short .copy_id
.id_done:

            ; Append `,"result":{` to outbuf (EDX is already s_result!)
            mov     esi, edx
            mov     cl, s_result_len
            rep     movsb               ; leaves EBX = 0 untouched!

            ; -----------------------------------------------------------------
            ; STAGE 2: Find `"method"` in inbuf & dispatch (ADR-0005)
            ; -----------------------------------------------------------------
            lea     esi, [esp + 4]      ; esi = inbuf ([esp] currently holds outbuf!)
            mov     edx, 'hod"'         ; end of '"method"' (skips past key quote)
            call    find_token
            jne     short .send_close   ; Fallback: close with `}}\n`

            ; Advance to the opening quote of the method value: `"method" : "<HERE>`
.find_m_quote:
            lodsb
            cmp     al, '"'
            jne     short .find_m_quote

            ; Now [esi] points to the 1st character of the method name!
            lodsb                       ; al = 1st char of method name
            cmp     al, 'i'             ; "initialize"
            jne     short .check_tools

            ; --- Method: initialize ---
            mov     esi, s_init
            mov     cl, s_init_len
.copy_and_send:
            rep     movsb
.send_close:
            mov     eax, 0x000A7D7D     ; "}}\n" in little-endian
            stosd
            dec     edi                 ; advance 3 bytes (not 4)

            ; sys_write(1, outbuf, edi - outbuf)
            pop     ecx                 ; ecx = outbuf (saved on stack)
            mov     edx, edi
            sub     edx, ecx            ; edx = length of response (> 0, so ZF = 0!)
            push    1
            pop     ebx                 ; FD 1 = stdout
            push    4
            pop     eax                 ; syscall 4 = sys_write
            int     0x80
            jne     short .to_do_read   ; ZF=0 preserved by int 0x80 -> loop via .to_do_read!

.check_tools:
            ; [esi] was incremented by lodsb, so [esi+5] is the 7th char of "tools/X..."
            cmp     byte [esi+5], 'l'   ; "tools/list"
            jne     short .do_tool_call

            ; --- Method: tools/list ---
            mov     esi, s_list
            mov     cl, s_list_len
            jmp     short .copy_and_send

.do_tool_call:
            ; --- Method: tools/call (or ping/unknown fallback!) ---
            cmp     al, 't'             ; "tools/call"? (sets ZF; preserved across mov/lea/push/pop/int 0x80/cdq!)
            mov     ebp, write_2digits
            lea     esi, [byte ebp + s_call_pre - write_2digits]
            mov     cl, s_call_pre_len
            push    13
            pop     eax                 ; syscall 13 = sys_time(NULL) (EBX is already 0!)
            int     0x80
            cdq
.to_send_close:
            jne     short .send_close   ; "ping" or unknown method -> `{"jsonrpc":"2.0","id":X,"result":{}}`

            rep     movsb               ; copy s_call_pre; leaves ESI = month_days, ECX = 0!

            ; -----------------------------------------------------------------
            ; CALENDAR MATH: Epoch Seconds -> "YYYY-MM-DD HH:MM:SS UTC (DDD)" (ADR-0003)
            ; -----------------------------------------------------------------
            ; First split EAX (epoch seconds) into SS, MM, HH, and Days
            mov     cl, 60
            div     ecx                 ; EAX = total minutes, EDX = SS (0..59)
            push    edx                 ; [stack 1] save SS

            cdq
            div     ecx                 ; EAX = total hours,   EDX = MM (0..59)
            push    edx                 ; [stack 2] save MM

            mov     cl, 24
            cdq
            div     ecx                 ; EAX = days since 1970-01-01, EDX = HH (0..23)
            push    edx                 ; [stack 3] save HH

            ; Compute Weekday: 1970-01-01 was Thursday (index 0 in "ThuFriSatSunMonTueWed")
            push    eax                 ; save days since epoch
            mov     cl, 7
            cdq
            div     ecx                 ; EDX = days % 7 (0..6)
            pop     ebx                 ; EBX = days since 1970-01-01
            push    edx                 ; [stack 4] save weekday index (0..6)

            ; Year loop starting from 1969 (incremented at top of loop -> 1970..)
            mov     ax, 1969            ; high word of EAX is already 0 (from days / 7)
.year_loop:
            inc     eax
            mov     cx, 365
            ; Check leap year (1970..2099: divisible by 4 iff low 2 bits == 0)
            test    al, 3
            jnz     short .not_leap_yr
            inc     ecx                 ; 366 days in leap year
.not_leap_yr:
            sub     ebx, ecx
            jae     short .year_loop
            add     ebx, ecx            ; restore remainder day of year (0..365)

            ; Write 4-digit Year to [edi]:
            mov     cl, 100
            div     cl                  ; AL = century (20), AH = year_in_century (26)
            mov     ch, ah              ; save year_in_century in CH
            call    ebp                 ; write "20-" (trailing byte overwritten next)
            dec     edi                 ; rewind over trailing separator byte
            mov     al, ch
            mov     cl, '-'
            call    ebp                 ; write "26-"

            ; Month loop (1..12) using month_days table (ESI is already month_days!)
            cdq                         ; EDX = 0 (since EAX > 0); EAX upper 24 bits are 0; CL is '-'!
.month_loop:
            inc     edx
            lodsb                       ; EAX = days in month (31, 28, ...)
            cmp     al, 28              ; February (only month with 28 days)?
            jne     short .chk_month
            test    ch, 3               ; Is current year a leap year? (year_in_century % 4 == 0!)
            jnz     short .chk_month
            inc     eax                 ; Feb has 29 days
.chk_month:
            sub     ebx, eax
            jae     short .month_loop
            adc     ebx, eax            ; CF=1 from jae exit -> EBX = 1-based Day (1..31)!

            ; EDX = Month (1..12), CL is still '-', EBX = Day (1..31)
            xchg    eax, edx            ; EAX = Month
            call    ebp                 ; write "MM-"

            xchg    eax, ebx            ; EAX = Day
            mov     cl, ' '
            call    ebp                 ; write "DD "

            pop     edx                 ; [stack 4] EDX = weekday index (0..6)
            pop     eax                 ; [stack 3] EAX = HH
            mov     cl, ':'
            call    ebp                 ; write "HH:"

            pop     eax                 ; [stack 2] EAX = MM
            call    ebp                 ; write "MM:" (CL is still ':')

            pop     eax                 ; [stack 1] EAX = SS
            mov     cl, ' '
            call    ebp                 ; write "SS "

            ; Append "UTC ("
            mov     eax, 'UTC '
            stosd
            mov     al, '('
            stosb

            ; Copy 3-letter weekday from `weekdays + edx * 3`
            lea     esi, [byte ebp + edx*2 + weekdays - write_2digits]
            add     esi, edx
            movsd
            dec     edi

            ; Write ')"}]' (0x5D7D2229) directly!
            mov     eax, ')"}]'
            stosd
            jne     short .to_send_close ; ZF=0 from dec edi -> jump via .to_send_close!

; -----------------------------------------------------------------------------
; HELPER: write_2digits — Converts AL (0..99) into two ASCII digits + CL at [EDI]
; -----------------------------------------------------------------------------
write_2digits:
            aam                         ; AH = AL / 10, AL = AL % 10
            add     ax, '00'            ; convert both nibbles to ASCII
            xchg    al, ah              ; tens digit in AL, ones digit in AH
            stosw                       ; write 2 digits to [edi]
            movzx   eax, cl
            stosb                       ; write trailing separator to [edi] (leaves AH = 0!)
            ret

; -----------------------------------------------------------------------------
; HELPER: find_token — Scans [ESI..ESI+EBP] for 4-byte token in EDX
; Returns ZF=1 and ESI pointing right after the 4-byte token if found.
; -----------------------------------------------------------------------------
find_token:
            mov     ecx, ebp
.scan:
            cmp     dword [esi], edx
            je      short .found
            inc     esi
            loop    .scan               ; preserves ZF=0 from inc esi (stack addr != 0)
            ret
.found:
            lodsd                       ; advance ESI by 4 bytes (preserves ZF=1)
            ret
; -----------------------------------------------------------------------------
; STATIC DATA & GOLFED MCP TEMPLATES (ADR-0003, ADR-0004)
; -----------------------------------------------------------------------------
s_prefix:
            db      '{"jsonrpc":"2.0","id":'
s_prefix_len equ    $ - s_prefix

s_result:
            db      ',"result":{'
s_result_len equ    $ - s_result

s_call_pre:
            db      '"content":[{"type":"text","text":"'
s_call_pre_len equ  $ - s_call_pre

month_days:
            db      31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

weekdays:
            db      "ThuFriSatSunMonTueWed"

s_init:
            db      '"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"d","version":"1"}'
s_init_len  equ     $ - s_init

s_list:
            db      '"tools":[{"name":"date","inputSchema":{"type":"object"}}]'
s_list_len  equ     $ - s_list

filesize    equ     $ - $$

