# =============================================================================
# Multi-stage Dockerfile for building, testing, and packaging `time-mcp`
# Works on macOS (Apple Silicon / Intel), Linux, and Windows:
#   docker build --platform linux/amd64 --target test .
#   docker build --platform linux/amd64 -t time-mcp .
# =============================================================================

FROM --platform=linux/amd64 debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends nasm python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
COPY src/ src/
COPY tests/ tests/
RUN nasm -f bin src/time_mcp.asm -o time-mcp && chmod +x time-mcp

FROM builder AS test
RUN python3 tests/test_mcp.py

# Final production image: literally 0 OS layers, just the ~490-byte binary!
FROM --platform=linux/amd64 scratch
COPY --from=builder /workspace/time-mcp /time-mcp
ENTRYPOINT ["/time-mcp"]
