# ADR-0004: Golfed MCP Tool Schema & Shared JSON-RPC Envelope

- **Status:** Accepted
- **Date:** 2026-10-14

## Context

In the Model Context Protocol (MCP) over `stdio`, every response is a newline-delimited JSON-RPC 2.0 object:

1. **`initialize` response:**
   ```json
   {
     "jsonrpc": "2.0",
     "id": 1,
     "result": {
       "protocolVersion": "2024-11-05",
       "capabilities": {"tools": {}},
       "serverInfo": {"name": "d", "version": "1"}
     }
   }
   ```
2. **`tools/list` response:**
   ```json
   {
     "jsonrpc": "2.0",
     "id": 2,
     "result": {"tools": [{"name": "date", "inputSchema": {"type": "object"}}]}
   }
   ```
3. **`tools/call` response:**
   ```json
   {
     "jsonrpc": "2.0",
     "id": 3,
     "result": {
       "content": [{"type": "text", "text": "2026-12-30 12:30:00 (Wed)"}]
     }
   }
   ```
4. **`ping` / fallback response:**
   ```json
   {"jsonrpc": "2.0", "id": 4, "result": {}}
   ```

Notice that:

- In the MCP specification, a Tool's `description` field is **optional**. Naming the tool `"date"` makes its purpose self-explanatory to any LLM while saving the 16 bytes of `"description":""`.
- Every response starts with the exact same 22-byte prefix (`{"jsonrpc":"2.0","id":`) and followed by the echoed `id`, then the 10-byte middle (`,"result":{`), and ends with `}\n`.

## Decision

1. **Self-Descriptive Tool Name (`"date"`), Omit `description`:** Define the tool schema as `{"name":"date","inputSchema":{"type":"object"}}`.
2. **Envelope Factorization:** Store the JSON-RPC prefix (`{"jsonrpc":"2.0","id":`) and result opener (`,"result":{`) **once** in memory. Every response dynamically constructs:
   ```
   [Prefix: {"jsonrpc":"2.0","id":] + [Echoed ID] + [Opener: ,"result":{] + [Method Payload] + [}\n]
   ```

## Consequences

- **Pros:**
  - Factoring out `{"jsonrpc":"2.0","id":` and `,"result":{` across all 4 response types saves **~96 bytes** of duplicated static strings.
  - Naming the tool `"date"` gives LLMs in LibreChat, MCPJam, and MCP Inspector clear semantic intent without paying for a `"description"` key.
- **Cons:**
  - None; responses are 100% valid JSON-RPC 2.0 and pass strict Zod schema validation in the official MCP SDK.
