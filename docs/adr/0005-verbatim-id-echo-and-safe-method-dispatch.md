# ADR-0005: Verbatim JSON-RPC `id` Echoing & Safe Method Dispatch

- **Status:** Accepted
- **Date:** 2026-10-14

## Context

Different MCP clients (LibreChat, MCPJam, MCP Inspector, Claude Desktop, VS Code Copilot) exhibit different JSON-RPC behaviors:

1. **ID formats vary:** Clients may send integer IDs (`"id":0`, `"id":42`), string IDs (`"id":"req-1"`), or whitespace after the colon (`"id": 1`).
2. **Notifications:** Clients send `"method":"notifications/initialized"` (which has **no `"id"` field**). According to JSON-RPC 2.0, the server **must not** reply to notifications.
3. **Optional capability probes:** Clients like LibreChat or MCP Inspector may send `ping`, `resources/list`, or `prompts/list`. If an MCP server ignores a request that has an `"id"`, the client hangs indefinitely waiting for a response.

A naive 1-byte scan across the entire JSON line can misfire if `clientInfo` contains characters like `"librechat"`. Conversely, comparing full method strings (`"initialize"`, `"tools/list"`, `"tools/call"`, `"ping"`) wastes ~40 bytes.

## Decision

We implement a two-stage parser in assembly (~48 bytes):

1. **Stage 1 — Locate `"id":` and Echo Verbatim:**
   - Scan the input buffer for the 4-byte sequence `"id"` followed by `:` (skipping optional spaces).
   - If `"id"` is **not found** in the message (e.g., `notifications/initialized`), immediately loop back to read the next line (**0 bytes sent**).
   - Copy the `id` value byte-for-byte into the output buffer until `,` or `}` or whitespace/newline is reached. This supports integers (`0`, `12345`), strings (`"abc-1"`), and `null`.

2. **Stage 2 — Locate `"method":` and Safe 2-Character Dispatch:**
   - Scan the input buffer for `"method"` followed by `:` and `"`.
   - Inspect the first character of the method name (and 7th character if it starts with `'t'`):
     - `'i'` (`initialize`) → Emit `initialize` payload.
     - `'t'` + 7th char `'l'` (`tools/list`) → Emit `tools/list` payload.
     - `'t'` + 7th char `'c'` (`tools/call`) → Compute current UTC datetime and emit `tools/call` payload.
     - **Anything else** (including `ping`!) → Emit empty result payload (`}\n`, completing `{"jsonrpc":"2.0","id":<ID>,"result":{}}`).

```
Incoming stdin line
  |
  +--> Contains `"id"`? --- NO ---> Ignore (Notification, e.g. notifications/initialized)
  |
 YES (Copy ID token verbatim into response buffer)
  |
  +--> Find `"method":"`
         |
         +-- 1st char == 'i' -----------------> initialize response
         +-- 1st char == 't' & 7th == 'l' ----> tools/list response
         +-- 1st char == 't' & 7th == 'c' ----> tools/call response (live UTC timestamp)
         +-- default (e.g. `ping`) -----------> `{"jsonrpc":"2.0","id":<ID>,"result":{}}`
```

## Consequences

- **Pros:**
  - **Zero client hangs:** `ping` works with **0 extra bytes** of comparison logic via the default `{}` fallback, and unexpected probes never block the client.
  - **Immune to `clientInfo` collisions:** Only inspects bytes immediately following `"method":"`.
  - **Universal ID support:** Works with integer, string, and UUID request IDs of any length.
- **Cons:**
  - Assumes each JSON-RPC message arrives as a single line read from `stdin` (guaranteed by the MCP `stdio` transport specification, which mandates newline-delimited JSON).
