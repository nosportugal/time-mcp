; =============================================================================
; time-mcp: The World's Smallest Compiled MCP Server (~449 bytes)
; =============================================================================
; Target:      Linux x86 (32-bit Static ELF, IA32 / x86_64 compatible)
; Assembler:   nasm -f bin src/time_mcp.asm -o time-mcp && chmod +x time-mcp
; Dependencies: NONE (0 libraries, 0 child processes, raw int 0x80 syscalls)
; Protocol:    Model Context Protocol (MCP) 2024-11-05 over stdio (JSON-RPC 2.0)
; Tool:        "date" -> returns UTC "YYYY-MM-DD HH:MM:SS (DDD)"
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
            ;   [esp+4096]   .. [esp+8191] = outbuf (4 KB)
            sub     esp, 8192           ; 0x20: [6B] 8KB writable buffers on stack
            jmp     short do_read       ; 0x26: [2B] jump over e_phentsize/e_phnum
            dw      0                   ; 0x28: [2B] pad to 0x2A
            dw      0x20                ; 0x2A: e_phentsize = 32 bytes
            db      1                   ; 0x2C: e_phnum = 1             | (end of 45B header!)

; -----------------------------------------------------------------------------
; MAIN MCP STDIO LOOP (ADR-0002, ADR-0005)
; -----------------------------------------------------------------------------
do_read:
            ; Zero out inbuf ([esp..esp+4095]) so string scans terminate cleanly
            mov     edi, esp
            xor     eax, eax
            xor     ecx, ecx
            mov     ch, 16              ; ecx = 4096 bytes
            rep     stosb

            ; sys_read(0, inbuf, 4096)
            xor     ebx, ebx            ; FD 0 = stdin
            mov     ecx, esp            ; ecx = inbuf
            xor     edx, edx
            mov     dh, 16              ; edx = 4096 (0x1000)
            mov     al, 3               ; syscall 3 = sys_read
            int     0x80
            test    eax, eax
            jle     short do_exit       ; EOF or error -> exit(0)

            ; -----------------------------------------------------------------
            ; STAGE 1: Find `"id"` in inbuf. If missing -> notification (ignore)
            ; -----------------------------------------------------------------
            mov     esi, esp            ; esi = inbuf
            mov     ebp, eax            ; ebp = bytes read
            mov     edx, 0x22646922     ; '"id"' in little-endian: 0x22 'i' 'd' 0x22
            call    find_token
            jne     short do_read       ; Not found -> notification (e.g. initialized), ignore!

            ; Build response envelope prefix in outbuf ([esp+4096]): `{"jsonrpc":"2.0","id":`
            lea     edi, [esp + 4096]   ; edi = outbuf
            push    esi                 ; save position right after `"id"` in inbuf
            mov     esi, s_prefix
            push    s_prefix_len
            pop     ecx
            rep     movsb
            pop     esi                 ; restore inbuf pointer after `"id"`

            ; Advance past `:` and any whitespace after `"id"`
.skip_id_sep:
            lodsb
            cmp     al, ':'
            jne     short .skip_id_sep
.skip_id_ws:
            lodsb
            cmp     al, ' '
            jbe     short .skip_id_ws

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

            ; Append `,"result":{` to outbuf
            mov     esi, s_result
            push    s_result_len
            pop     ecx
            rep     movsb

            ; -----------------------------------------------------------------
            ; STAGE 2: Find `"method"` in inbuf & dispatch (ADR-0005)
            ; -----------------------------------------------------------------
            mov     esi, esp            ; esi = inbuf
            mov     edx, 0x74656d22     ; '"met' in little-endian ('"method"')
            call    find_token
            jne     near .send_close    ; Fallback: close with `}\n`

            ; Advance to the opening quote of the method value: `"method" : "<HERE>`
.find_m_colon:
            lodsb
            cmp     al, ':'
            jne     short .find_m_colon
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
            jmp     near .append_and_send

do_exit:
            xor     ebx, ebx
            xor     eax, eax
            inc     eax                 ; syscall 1 = sys_exit(0)
            int     0x80

.check_tools:
            cmp     al, 't'             ; "tools/list" or "tools/call"
            jne     short .send_close   ; "ping" or unknown method -> `{"jsonrpc":"2.0","id":X,"result":{}}`

            ; [esi] was incremented by lodsb, so [esi+5] is the 7th char of "tools/X..."
            ; Index: 0='t'(in al), esi[0]='o', esi[1]='o', esi[2]='l', esi[3]='s', esi[4]='/', esi[5]='l' or 'c'
            cmp     byte [esi+5], 'l'   ; "tools/list"
            jne     short .do_tool_call

            ; --- Method: tools/list ---
            mov     esi, s_list
            mov     cl, s_list_len
            jmp     short .append_and_send

.do_tool_call:
            ; --- Method: tools/call (Compute live UTC datetime!) ---
            mov     esi, s_call_pre
            mov     cl, s_call_pre_len
            rep     movsb

            ; -----------------------------------------------------------------
            ; CALENDAR MATH: Epoch Seconds -> "YYYY-MM-DD HH:MM:SS (DDD)" (ADR-0003)
            ; -----------------------------------------------------------------
            ; sys_time(NULL) -> returns UTC epoch seconds in EAX
            xor     ebx, ebx
            push    13
            pop     eax                 ; syscall 13 = sys_time
            int     0x80

            ; Reserve 25 bytes in outbuf (`YYYY-MM-DD HH:MM:SS (DDD)`)
            ; First split EAX (epoch seconds) into SS, MM, HH, and Days
            push    60
            pop     ecx
            xor     edx, edx
            div     ecx                 ; EAX = total minutes, EDX = SS (0..59)
            push    edx                 ; [stack 1] save SS

            xor     edx, edx
            div     ecx                 ; EAX = total hours,   EDX = MM (0..59)
            push    edx                 ; [stack 2] save MM

            mov     cl, 24
            xor     edx, edx
            div     ecx                 ; EAX = days since 1970-01-01, EDX = HH (0..23)
            push    edx                 ; [stack 3] save HH

            ; Compute Weekday: 1970-01-01 was Thursday (index 0 in "ThuFriSatSunMonTueWed")
            push    eax                 ; save days since epoch
            mov     cl, 7
            xor     edx, edx
            div     ecx                 ; EDX = days % 7 (0..6)
            pop     ebx                 ; EBX = days since 1970-01-01
            push    edx                 ; [stack 4] save weekday index (0..6)

            ; Year loop starting from 1970
            mov     ebp, 1970
.year_loop:
            mov     ecx, 365
            ; Check leap year (1970..2099: divisible by 4 iff low 2 bits == 0)
            test    ebp, 3
            jnz     short .not_leap_yr
            inc     ecx                 ; 366 days in leap year
.not_leap_yr:
            cmp     ebx, ecx
            jb      short .year_done
            sub     ebx, ecx
            inc     ebp
            jmp     short .year_loop
.year_done:
            ; EBP = Year (e.g. 2026), EBX = day of year (0..365)
            ; Write 4-digit Year to [edi]:
            mov     eax, ebp
            mov     cl, 100
            div     cl                  ; AL = century (20), AH = year_in_century (26)
            push    eax
            call    write_2digits       ; write "20"
            pop     eax
            mov     al, ah
            call    write_2digits       ; write "26"
            mov     al, '-'
            stosb

            ; Month loop (1..12) using month_days table
            mov     esi, month_days
            xor     ecx, ecx            ; ECX = month index (0..11)
.month_loop:
            xor     eax, eax
            lodsb                       ; EAX = days in month (31, 28, ...)
            cmp     cl, 1               ; February (index 1)?
            jne     short .chk_month
            test    ebp, 3              ; Is current year a leap year?
            jnz     short .chk_month
            inc     eax                 ; Feb has 29 days
.chk_month:
            cmp     ebx, eax
            jb      short .month_done
            sub     ebx, eax
            inc     ecx
            jmp     short .month_loop
.month_done:
            ; ECX + 1 = Month (1..12), EBX + 1 = Day (1..31)
            lea     eax, [ecx + 1]
            call    write_2digits       ; write MM
            mov     al, '-'
            stosb

            lea     eax, [ebx + 1]
            call    write_2digits       ; write DD
            mov     al, ' '
            stosb

            pop     edx                 ; [stack 4] EDX = weekday index (0..6)
            pop     eax                 ; [stack 3] EAX = HH
            call    write_2digits       ; write HH
            mov     al, ':'
            stosb

            pop     eax                 ; [stack 2] EAX = MM
            call    write_2digits       ; write MM
            mov     al, ':'
            stosb

            pop     eax                 ; [stack 1] EAX = SS
            call    write_2digits       ; write SS

            mov     ax, ' ('
            stosw

            ; Copy 3-letter weekday from `weekdays + edx * 3`
            imul    edx, edx, 3
            lea     esi, [weekdays + edx]
            movsb
            movsb
            movsb

            mov     esi, s_call_post
            xor     ecx, ecx
            mov     cl, s_call_post_len

.append_and_send:
            rep     movsb

.send_close:
            mov     ax, 0x0A7D          ; "}\n" in little-endian
            stosw

            ; sys_write(1, outbuf, edi - outbuf)
            xor     ebx, ebx
            inc     ebx                 ; FD 1 = stdout
            lea     ecx, [esp + 4096]   ; ecx = outbuf
            mov     edx, edi
            sub     edx, ecx            ; edx = length of response
            push    4
            pop     eax                 ; syscall 4 = sys_write
            int     0x80
            jmp     do_read             ; loop for next JSON-RPC line!

; -----------------------------------------------------------------------------
; HELPER: write_2digits — Converts AL (0..99) into two ASCII digits at [EDI]
; -----------------------------------------------------------------------------
write_2digits:
            aam                         ; AH = AL / 10, AL = AL % 10
            add     ax, '00'            ; convert both nibbles to ASCII
            xchg    al, ah              ; tens digit in AL, ones digit in AH
            stosw                       ; write 2 bytes to [edi]
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
            loop    .scan
            inc     ecx                 ; clear ZF (not found)
            ret
.found:
            lodsd                       ; advance ESI by 4 bytes (preserves ZF=1)
            ret

; -----------------------------------------------------------------------------
; STATIC DATA & GOLFED MCP TEMPLATES (ADR-0003, ADR-0004)
; -----------------------------------------------------------------------------
month_days:
            db      31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

weekdays:
            db      "ThuFriSatSunMonTueWed"

s_prefix:
            db      '{"jsonrpc":"2.0","id":'
s_prefix_len equ    $ - s_prefix

s_result:
            db      ',"result":{'
s_result_len equ    $ - s_result

s_init:
            db      '"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"d","version":"1"}'
s_init_len  equ     $ - s_init

s_list:
            db      '"tools":[{"name":"date","inputSchema":{"type":"object"}}]'
s_list_len  equ     $ - s_list

s_call_pre:
            db      '"content":[{"type":"text","text":"'
s_call_pre_len equ  $ - s_call_pre

s_call_post:
            db      ')"}]'
s_call_post_len equ $ - s_call_post

filesize    equ     $ - $$

