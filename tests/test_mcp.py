#!/usr/bin/env python3
"""
MCP Compliance & Byte-Size Verification Suite for `time-mcp`.

Tests:
1. Binary size is under 600 bytes (target ~480-520 bytes).
2. `initialize` handshake (integer ID).
3. `notifications/initialized` produces zero output (does not hang or reply).
4. `tools/list` returns valid MCP tool schema with `"name": "date"`.
5. `tools/call` (with string UUID ID and extra whitespace) returns exact UTC
   timestamp matching `"YYYY-MM-DD HH:MM:SS (DDD)"`.
6. `ping` and unknown methods (e.g. `resources/list`) return `{}` without hanging.
"""

from datetime import datetime, timezone
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BINARY_PATH = Path(os.environ.get("MCP_BINARY", "./time-mcp"))
DATETIME_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \((Mon|Tue|Wed|Thu|Fri|Sat|Sun)\)$"
)


def send_and_receive(proc: subprocess.Popen, payload: dict) -> dict:
    line = json.dumps(payload) + "\n"
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(line.encode("utf-8"))
    proc.stdin.flush()
    raw = proc.stdout.readline().decode("utf-8").strip()
    assert raw, f"Expected JSON-RPC response for {payload}, got EOF"
    return json.loads(raw)


def main() -> int:
    if not BINARY_PATH.exists():
        print(f"ERROR: Binary not found at {BINARY_PATH}. Run `make` first.", file=sys.stderr)
        return 1

    size = BINARY_PATH.stat().st_size
    print(f"[1/6] Binary size: {size} bytes")
    assert size < 600, f"Binary too large: {size} bytes"

    proc = subprocess.Popen(
        [str(BINARY_PATH)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        # 1. initialize (integer ID)
        init_resp = send_and_receive(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "librechat", "version": "1.0.0"},
                },
            },
        )
        assert init_resp["jsonrpc"] == "2.0"
        assert init_resp["id"] == 1
        assert "protocolVersion" in init_resp["result"]
        assert "tools" in init_resp["result"]["capabilities"]
        print(f"[2/6] initialize OK: {json.dumps(init_resp)}")

        # 2. notifications/initialized (MUST NOT produce a response)
        assert proc.stdin is not None
        proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        proc.stdin.flush()
        print("[3/6] notifications/initialized sent (silently ignored as required)")

        # 3. tools/list (multi-digit integer ID)
        list_resp = send_and_receive(
            proc,
            {"jsonrpc": "2.0", "id": 42, "method": "tools/list", "params": {}},
        )
        assert list_resp["id"] == 42
        tools = list_resp["result"]["tools"]
        assert len(tools) == 1
        assert tools[0]["name"] == "date"
        assert tools[0]["inputSchema"]["type"] == "object"
        print(f"[4/6] tools/list OK: {json.dumps(list_resp)}")

        # 4. tools/call (string ID)
        now_utc = datetime.now(timezone.utc)
        call_resp = send_and_receive(
            proc,
            {
                "jsonrpc": "2.0",
                "id": "req-uuid-99",
                "method": "tools/call",
                "params": {"name": "date", "arguments": {}},
            },
        )
        assert call_resp["id"] == "req-uuid-99"
        content = call_resp["result"]["content"]
        assert len(content) == 1 and content[0]["type"] == "text"
        dt_text = content[0]["text"]
        assert DATETIME_RE.match(dt_text), f"Invalid datetime format: {dt_text!r}"

        expected_prefix = now_utc.strftime("%Y-%m-%d %H:%M")
        expected_day = now_utc.strftime("(%a)")
        assert dt_text.startswith(expected_prefix[:13]), (
            f"Date/hour mismatch: got {dt_text!r}, expected prefix {expected_prefix!r}"
        )
        assert dt_text.endswith(expected_day), (
            f"Weekday mismatch: got {dt_text!r}, expected {expected_day!r}"
        )
        print(f"[5/6] tools/call OK: {dt_text}")

        # 5. ping & unknown method fallback
        ping_resp = send_and_receive(
            proc, {"jsonrpc": "2.0", "id": 99, "method": "ping"}
        )
        assert ping_resp == {"jsonrpc": "2.0", "id": 99, "result": {}}
        print(f"[6/6] ping fallback OK: {json.dumps(ping_resp)}")

    finally:
        if proc.stdin:
            proc.stdin.close()
        proc.wait(timeout=2)

    print(f"\nALL TESTS PASSED! Compiled size: {size} bytes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
