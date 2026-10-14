# ADR-0003: UTC Calendar Math (1970–2099) & 3-Letter Weekday Format

- **Status:** Accepted
- **Date:** 2026-10-14

## Context

The MCP tool must return the current datetime formatted as:
`YYYY-MM-DD HH:MM:SS UTC (DDD)` — e.g., `"2026-12-30 12:30:00 UTC (Wed)"`.

The Linux `sys_time` syscall returns seconds since `1970-01-01 00:00:00 UTC` (a Thursday). Converting raw epoch seconds into `YYYY-MM-DD HH:MM:SS UTC (Weekday)` in x86 assembly requires:

1. Breaking time-of-day into `SS`, `MM`, `HH` and total days since `1970-01-01`.
2. Computing the day of the week from `(days + 4) % 7` (or `(days + 3) % 7` for `Mon=0..Sun=6`).
3. Accounting for leap years and variable month lengths (`31, 28/29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31`).

## Decision

1. **UTC Timezone:** Use UTC directly from `sys_time` (`eax = 13`, `ebx = 0`), avoiding `/etc/localtime` TZif binary parsing. Include the literal `UTC` in the returned text so clients and LLMs can identify the timezone without external context.
2. **1970–2099 Leap Year Rule:** Because the year 2000 was divisible by 400, **every 4th year from 1968 to 2099 is strictly a leap year**. We omit the 100-year / 400-year exception checks, saving ~15 bytes while remaining 100% accurate through `2099-12-31 23:59:59`.
3. **3-Letter Weekday Table (`21 bytes`):** Store the 7 weekday names as a contiguous 21-byte lookup table:
   `"ThuFriSatSunMonTueWed"`
   Since `1970-01-01` (Day 0) was a **Thursday**, starting the table at `"Thu"` means `weekday_index = days % 7` requires **zero offset addition** (`add eax, 4` is eliminated, saving 3 bytes!).
4. **Bit-Packed / Table Month Lengths:** Compute month lengths using a compact 12-byte table or bitmask with February dynamically adjusted by `is_leap`.

```
Epoch Seconds (EAX)
  |-- div 60 --> Seconds (SS)
  |-- div 60 --> Minutes (MM)
  |-- div 24 --> Hours   (HH), Quotient = Days since 1970-01-01 (Thu)
                   |
                   +-- Days % 7 ---------> Index into "ThuFriSatSunMonTueWed"
                   +-- Year loop (1970+) -> Subtract 365 (or 366 if year % 4 == 0)
                   +-- Month loop (1..12)-> Subtract month_len[m] -> Month (MM), Day (DD)
```

## Consequences

- **Pros:**
  - Starting the weekday string at `"Thu"` (`"ThuFriSatSunMonTueWed"`) eliminates the `+4` weekday offset instruction.
  - 3-letter weekday names are fixed-width (always 3 bytes: `offset = (days % 7) * 3`), eliminating variable-length string scanning and saving ~18 bytes of code + data.
- **Cons:**
  - Calendar math will need a 15-byte patch in the year 2100 (74 years from now).
