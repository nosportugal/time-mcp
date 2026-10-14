# =============================================================================
# Makefile for time-mcp (Linux & macOS via Docker)
# =============================================================================

BINARY := time-mcp
SRC    := src/time_mcp.asm

.PHONY: all build test docker-build docker-test clean size

all: build size

# Native build (requires `nasm` installed on Linux or macOS)
build: $(SRC)
	nasm -f bin $(SRC) -o $(BINARY)
	chmod +x $(BINARY)

# Print exact byte count
size: $(BINARY)
	@wc -c < $(BINARY) | awk '{print "Compiled ELF size: " $$1 " bytes"}'

# Run MCP compliance suite natively (Linux x86/x86_64)
test: build
	python3 tests/test_mcp.py

# Build & run tests inside a Linux x86 container (Works on macOS Apple Silicon / Intel & Windows!)
docker-test:
	docker build --platform linux/amd64 --target test -t time-mcp:test .

# Build a minimal `FROM scratch` container image (~490 bytes total image size!)
docker-build:
	docker build --platform linux/amd64 -t time-mcp:latest .

clean:
	rm -f $(BINARY)
