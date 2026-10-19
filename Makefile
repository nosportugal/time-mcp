# =============================================================================
# Makefile for time-mcp (Native stdio MCP Server — Linux ELF32 & macOS arm64)
# =============================================================================

BINARY      := time-mcp
ELF_BINARY  := time-mcp-linux
ASM_LINUX   := src/time_mcp.asm
ASM_MACOS   := src/time_mcp_macos_arm64.s
UNAME_S     := $(shell uname -s)
PKG_CONFIG  ?= pkg-config
TEST_BINARY := tests/test_mcp
LINUX_BYTE_BUDGET ?= 799

.PHONY: all build build-linux build-macos clean size test test-linux test-macos check-size

all: build size

# Build native stdio binary for the current OS (and always verify Linux ELF32 if nasm is installed)
build:
ifeq ($(UNAME_S),Darwin)
	clang -Wl,-e,_start,-S,-x,-no_function_starts,-no_data_in_code_info,-no_exported_symbols,-no_fixup_chains $(ASM_MACOS) -o $(BINARY)
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
	clang -Wl,-e,_start,-S,-x,-no_function_starts,-no_data_in_code_info,-no_exported_symbols,-no_fixup_chains $(ASM_MACOS) -o $(BINARY)

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

$(TEST_BINARY): tests/test_mcp.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -Wall -Wextra -Werror $$($(PKG_CONFIG) --cflags json-c) $< -o $@ $(LDFLAGS) $$($(PKG_CONFIG) --libs json-c)

test: build $(TEST_BINARY)
	./$(TEST_BINARY) ./$(BINARY)

test-linux: build-linux $(TEST_BINARY) check-size
	./$(TEST_BINARY) ./$(ELF_BINARY)

test-macos: build-macos $(TEST_BINARY)
	./$(TEST_BINARY) ./$(BINARY)

check-size: build-linux
	@test "$$(wc -c < $(ELF_BINARY))" -le "$(LINUX_BYTE_BUDGET)" || { echo "Linux binary exceeds $(LINUX_BYTE_BUDGET) bytes"; exit 1; }

clean:
	rm -f $(BINARY) $(ELF_BINARY) $(TEST_BINARY)
