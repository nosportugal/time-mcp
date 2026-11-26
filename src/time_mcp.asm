; =============================================================================
; time-mcp: Small Compiled MCP Server
; =============================================================================
; Target:      Linux x86 (32-bit Static ELF, IA32 / x86_64 compatible)
; Assembler:   nasm -f bin src/time_mcp.asm -o time-mcp && chmod +x time-mcp
; Dependencies: NONE (0 libraries, 0 child processes, raw int 0x80 syscalls)
; Protocol:    Model Context Protocol (MCP) 2024-11-05 over stdio (JSON-RPC 2.0)
; Tool:        "date" -> returns UTC "YYYY-MM-DD HH:MM:SS UTC (DDD)"
; =============================================================================
;
; Register conventions used across the main loop:
;   esp  inbuf (8 KB scratch); the response is built right after the input line
;   ebp  find_key after the first successful key match (set by the header's
;        `mov ebp, imm32`, see below); write_2digits inside tools/call
;   ebx  pointer to s_call_pre while dispatching (s_list / s_init are relative)
; -----------------------------------------------------------------------------

BITS 32
            org     0x00010000          ; requires vm.mmap_min_addr <= 65536 (the usual default)

; -----------------------------------------------------------------------------
; 45-BYTE OVERLAPPED ELF32 HEADER + PROGRAM HEADER (ADR-0001)
; -----------------------------------------------------------------------------
ehdr:
            db      0x7F, "ELF"         ; 0x00: e_ident[0..3] magic
phdr:                                   ; --- Phdr overlaps at offset 0x04! ---
            dd      1                   ; 0x04: p_type = PT_LOAD (1)    | e_ident[4..7]
            dd      0                   ; 0x08: p_offset = 0            | e_ident[8..11]
            dd      $$                  ; 0x0C: p_vaddr = 0x00010000    | e_ident[12..15]
            dw      2                   ; 0x10: e_type = ET_EXEC (2)    | p_paddr[0..1]
            dw      3                   ; 0x12: e_machine = EM_386 (3)  | p_paddr[2..3]
            dd      filesize            ; 0x14: p_filesz = filesize     | e_version
            dd      _start              ; 0x18: e_entry = _start        | p_memsz (>= filesz)
            dd      4                   ; 0x1C: e_phoff = 4             | p_flags = PF_R (+X implied)

; -----------------------------------------------------------------------------
; HELPER: find_key -- lives at 0x10020, inside the unused e_shoff..e_ehsize bytes
; -----------------------------------------------------------------------------
; Scans the '\n'-terminated line at ESI for the 4-byte key tail in EDX followed
; by optional whitespace and ':'.
;   Found:     ZF=1, EAX = start of the 4-byte token, ESI = just after ':'.
;   Not found: ZF=0.
; Every match attempt runs through the `mov ebp, 0x00010020` that swallows
; e_phentsize/e_phnum, so after the first match EBP == find_key and later
; calls are a 2-byte `call ebp`. Uses EAX/ESI only; EBX, ECX, EDX, EDI are kept.
; -----------------------------------------------------------------------------
find_key:
.scan:      cmp     [esi], edx          ; 0x20
            jne     short .next         ; 0x22
            push    esi                 ; 0x24
            lodsd                       ; 0x25: skip the 4-byte token
.ws:        lodsb                       ; 0x26
            cmp     al, ' '             ; 0x27
            db      0xBD                ; 0x29: mov ebp, imm32 consumes the next fields
            dw      0x20                ; 0x2A: e_phentsize = 32 bytes
            dw      1                   ; 0x2C: e_phnum = 1
            jbe     short .ws           ; 0x2E: skip whitespace before ':'
            cmp     al, ':'             ; a JSON key must be followed by ':'
            pop     eax                 ; EAX = token start (flags preserved)
            je      short .ret
            xchg    eax, esi            ; not a key: resume right after the token start
.next:      lodsb
            cmp     al, 10              ; end of line?
            jne     short .scan
            inc     esi                 ; ZF=0: not found (ESI is never -1)
.ret:       ret

; -----------------------------------------------------------------------------
; STATIC DATA, part 1: tables addressed relative to write_2digits (EBP)
; -----------------------------------------------------------------------------
; February holds 28 - 0x6D: adding CL (0x6D or 0x6E, the low byte of the final
; year length 365/366) yields 28 or 29 (ADR-0003).
; Response prefix (EBP = find_key when these are loaded)
s_prefix:   db      '{"jsonrpc":"2.0",'           ; then the request's own `"id":<value>`
s_prefix_len equ    $ - s_prefix
s_result:   db      ',"result":{'
s_result_len equ    $ - s_result

month_days: db      31, 28 - 0x6D, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

; -----------------------------------------------------------------------------
; HELPER: write_2digits -- [ESI++] separator, then AL (0..99) as two digits
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
write_2digits:
            movsb                       ; copy separator from s_seps
            aam                         ; AH = AL / 10, AL = AL % 10
            add     ax, '00'
            xchg    al, ah              ; tens digit first
            stosw
            ret

; -----------------------------------------------------------------------------
; STATIC DATA, part 2: golfed MCP templates (ADR-0004)
; -----------------------------------------------------------------------------
s_call_pre: db      '"content":[{"type":"text","text":"2'          ; century "2|0" spans both strings
s_call_pre_len equ  $ - s_call_pre
s_seps:     db      '0-- :: UTC ('                ; separators consumed by write_2digits
weekdays:   db      "ThuFriSatSunMonTueWed"       ; 1970-01-01 was a Thursday
s_list:     db      '"tools":[{"name":"date","inputSchema":{"type":"object"}}]'
s_list_len  equ     $ - s_list
s_init:     db      '"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"d","version":"1"}'
s_init_len  equ     $ - s_init

; -----------------------------------------------------------------------------
; ENTRY POINT
; -----------------------------------------------------------------------------
_start:
            mov     bh, 0xFF            ; ebx = 65280 (Linux ELF execve starts with ebx = 0)
            sub     esp, ebx            ; ~64 KB for input + response: lines up to ~32 KB are supported

; -----------------------------------------------------------------------------
; MAIN MCP STDIO LOOP (ADR-0002, ADR-0005)
; -----------------------------------------------------------------------------
do_read:
            xor     ebx, ebx            ; FD 0 = stdin
            mul     ebx                 ; eax = edx = 0
            inc     edx                 ; 1 byte per read
            mov     edi, esp            ; edi = inbuf
.read_char:
            mov     ecx, edi
            mov     al, 3               ; sys_read(0, ecx, 1); EAX upper bits are 0 here
            int     0x80
            dec     eax                 ; 1 byte read -> ZF=1
            mov     al, 10              ; '\n' (flags preserved)
            jnz     short .check_eof    ; EOF or error
            scasb
            jne     short .read_char
.check_eof:
            cmp     edi, esp            ; anything read?
            jne     short .line_ready
            xchg    eax, edx            ; eax = 1 = sys_exit, ebx = 0
            int     0x80
.line_ready:
            stosd                       ; terminate with '\n' + 3 pad bytes (also for EOF without one)

            ; -----------------------------------------------------------------
            ; STAGE 1: Find `"id"`. If missing -> notification (no reply)
            ; -----------------------------------------------------------------
            mov     esi, esp
            mov     edx, 0x22646922     ; '"id"'
            call    find_key
.to_do_read:
            jne     short do_read       ; notification (e.g. initialized): ignore

            push    edi                 ; [stack: outbuf]
            xchg    eax, ebx            ; ebx = start of `"id"` in the request
            lea     esi, [byte ebp + s_prefix - find_key]
            push    s_prefix_len
            pop     ecx
            rep     movsb               ; leaves ESI = s_result

            ; Echo `"id" : <value>` verbatim up to the next ',' or '}'
            db      0xA8                ; test al, imm8: skips the first stosb
.copy_id:   stosb
            mov     al, [ebx]
            inc     ebx
            cmp     al, ','
            je      short .id_done
            cmp     al, '}'
            jne     short .copy_id
.id_done:
            mov     cl, s_result_len
            rep     movsb

            ; -----------------------------------------------------------------
            ; STAGE 2: Find `"method"` & dispatch (ADR-0005)
            ; -----------------------------------------------------------------
            mov     esi, esp
            lodsd                       ; esi = inbuf ([esp] holds outbuf)
            mov     dx, 'ho'            ; edx = 'hod"' (upper half 'd"' is shared with '"id"')
            call    ebp                 ; find_key
            lea     ebp, [byte ebp + write_2digits - find_key] ; base for the payloads (flags kept)
            jne     short .send_close   ; no method: reply `{}`
.m_quote:
            lodsb                       ; skip whitespace up to the opening quote
            cmp     al, '"'
            jne     short .m_quote
            lodsb                       ; al = 1st char of the method name
            cmp     al, 'i'             ; "initialize"
            jne     short .check_tools
.init_or_list:                          ; ZF=1: initialize, ZF=0: tools/list
            lea     esi, [byte ebp + s_list - write_2digits]
            mov     cl, s_list_len
            jne     short .copy_and_send
            add     esi, ecx            ; s_init follows s_list
            mov     cl, s_init_len
.copy_and_send:
            rep     movsb
.send_close:
            mov     eax, 0x0A207D7D     ; "}} \n" (JSON whitespace before the newline)
            stosd

            ; sys_write(1, outbuf, edi - outbuf)
            pop     ecx                 ; ecx = outbuf
            mov     edx, edi
            sub     edx, ecx            ; edx = length (> 0, so ZF = 0!)
            push    1
            pop     ebx                 ; FD 1 = stdout
            push    4
            pop     eax                 ; syscall 4 = sys_write
            int     0x80
            jne     short .to_do_read   ; ZF=0 preserved by int 0x80

.check_tools:
            cmp     al, 't'             ; "tools/list" or "tools/call"?
.to_send_close:                         ; also the tools/call exit (ZF=0), in short range
            jne     short .send_close   ; ping, roots/list, unknown -> `{}` (no sys_time)
            cmp     byte [esi+5], 'c'   ; 7th char of "tools/X..."
            jne     short .init_or_list ; ZF=0: tools/list

.do_tool_call:                          ; reached only for tools/call
            lea     esi, [byte ebp + s_call_pre - write_2digits]
                                        ; ebx = just past the echoed id member (>= 4 bytes before outbuf)
            mov     cl, s_call_pre_len
            push    13
            pop     eax                 ; sys_time(ebx): also stores into the spent inbuf
            int     0x80
            cdq
            rep     movsb               ; copy s_call_pre; leaves ESI = s_seps

            ; -----------------------------------------------------------------
            ; CALENDAR MATH: Epoch Seconds -> "YYYY-MM-DD HH:MM:SS UTC (DDD)" (ADR-0003)
            ; -----------------------------------------------------------------
            mov     cl, 60
            div     ecx                 ; EAX = total minutes, EDX = SS
            push    edx                 ; [stack] SS
            cdq
            div     ecx                 ; EAX = total hours,   EDX = MM
            push    edx                 ; [stack] MM
            mov     cl, 24
            cdq
            div     ecx                 ; EAX = days since 1970-01-01, EDX = HH
            push    edx                 ; [stack] HH
            push    eax
            mov     cl, 7
            cdq
            div     ecx                 ; EDX = weekday index (0 = Thu)
            pop     ebx                 ; EBX = days since 1970-01-01
            push    edx                 ; [stack] weekday

            ; Year loop starting from 1969 (incremented at top of loop -> 1970..)
            mov     al, 1969 - 2000     ; AL = year - 2000 (mod 256); high word of EAX is 0
.year_loop:
            inc     eax                 ; (a carry into AH at 1999 -> 2000 is harmless)
            mov     cx, 365
            test    al, 3               ; 2000..2099: leap iff year % 4 == 0
            jnz     short .not_leap
            inc     ecx
.not_leap:
            sub     ebx, ecx
            jae     short .year_loop
            add     ebx, ecx            ; EBX = day of year (0..365), CL = 0x6D / 0x6E

            call    ebp                 ; "0" + "26": with the "2" ending s_call_pre -> "2026"

            cdq                         ; EDX = 0 = month counter
.month_loop:
            inc     edx
            movzx   eax, byte [byte ebp + edx + month_days - 1 - write_2digits]
            cmp     al, 28 - 0x6D       ; February?
            jne     short .chk_month
            add     al, cl              ; 28 or 29
.chk_month:
            sub     ebx, eax
            jae     short .month_loop
            adc     ebx, eax            ; CF=1 from jae exit -> EBX = 1-based day

            xchg    ebx, [esp]          ; ebx = weekday, [stack] DD
            push    edx                 ; [stack] MM DD HH MM SS
            push    5
            pop     ecx
.print:
            pop     eax
            call    ebp                 ; "-MM" "-DD" " HH" ":MM" ":SS"
            loop    .print
            movsd
            movsw                       ; " UTC (" -> leaves ESI = weekdays

            lea     esi, [esi + ebx*2]
            add     esi, ebx            ; weekdays + 3 * index
            movsd
            dec     edi                 ; keep 3 letters (ZF=0)
            mov     eax, ')"}]'
            stosd
            jne     short .to_send_close

filesize    equ     $ - $$
