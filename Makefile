# =============================================================================
# Makefile for time-mcp (Native stdio MCP Server — Linux ELF32 & macOS arm64)
# =============================================================================

BINARY      := time-mcp
ELF_BINARY  := time-mcp-linux
ASM_LINUX   := src/time_mcp.asm
ASM_MACOS   := src/time_mcp_macos_arm64.s
UNAME_S     := $(shell uname -s)

.PHONY: all build build-linux build-macos clean size

all: build size

# Build native stdio binary for the current OS (and always verify Linux ELF32 if nasm is installed)
build:
ifeq ($(UNAME_S),Darwin)
	clang -Wl,-e,_start,-S,-x $(ASM_MACOS) -o $(BINARY)
	@if command -v nasm >/dev/null 2>&1; then \
		nasm -f bin $(ASM_LINUX) -o $(ELF_BINARY) && chmod +x $(ELF_BINARY); \
	fi
else
	nasm -f bin $(ASM_LINUX) -o $(BINARY)
	chmod +x $(BINARY)
endif

# Explicitly build the ultra-tiny Linux x86 32-bit Static ELF binary
build-linux: $(ASM_LINUX)
	nasm -f bin $(ASM_LINUX) -o $(ELF_BINARY)
	chmod +x $(ELF_BINARY)
	@wc -c < $(ELF_BINARY) | awk '{print "Linux ELF32 size: " $$1 " bytes"}'

# Explicitly build the native macOS arm64 (Apple Silicon) Mach-O binary
build-macos: $(ASM_MACOS)
	clang -Wl,-e,_start,-S,-x $(ASM_MACOS) -o $(BINARY)

# Print exact byte count
size: build
ifeq ($(UNAME_S),Darwin)
	@if [ -f $(ELF_BINARY) ]; then \
		wc -c < $(ELF_BINARY) | awk '{print "Compiled Linux ELF32 size: " $$1 " bytes"}'; \
	fi
	@wc -c < $(BINARY) | awk '{print "Compiled native macOS Mach-O size: " $$1 " bytes"}'
else
	@wc -c < $(BINARY) | awk '{print "Compiled ELF size: " $$1 " bytes"}'
endif

clean:
	rm -f $(BINARY) $(ELF_BINARY)
