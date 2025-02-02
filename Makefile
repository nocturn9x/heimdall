.DEFAULT_GOAL := openbench

.SUFFIXES:

# Define a variable to conditionally prefix commands with "@".
ECHO = $(if $(filter 1,$(SKIP_DEPS)),@,)

CC := clang
EXE_BASE := bin/heimdall
EXE := $(EXE_BASE)$(if $(OS),.exe,)
EVALFILE := ../networks/files/mistilteinn.bin
NET_NAME := $(notdir $(EVALFILE))
LD := lld
SRCDIR := src

LFLAGS := -flto -fuse-ld=$(LD)
LFLAGS_WINDOWS := $(LFLAGS) -target x86_64-windows-gnu

HINTSFLAG = $(if $(filter 1,$(SKIP_DEPS)),--hints:off,)
NFLAGS_SHARED := -d:danger --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) -d:evalFile=$(EVALFILE) $(HINTSFLAG)

NFLAGS := $(NFLAGS_SHARED) --cc:$(CC) --passL:"$(LFLAGS)"

CFLAGS := -flto -static

CFLAGS_AVX512 := $(CFLAGS) -mtune=znver4 -march=x86-64-v4
NFLAGS_AVX512 := $(NFLAGS) --passC:"$(CFLAGS_AVX512)" -d:simd -d:avx512

CFLAGS_MODERN := $(CFLAGS) -mtune=haswell -march=haswell
NFLAGS_MODERN := $(NFLAGS) --passC:"$(CFLAGS_MODERN)" -d:simd -d:avx2

CFLAGS_ZEN2 := $(CFLAGS) -march=bdver4 -mtune=znver2
NFLAGS_ZEN2 := $(NFLAGS) --passC:"$(CFLAGS_ZEN2)" -d:simd -d:avx2

CFLAGS_NATIVE := $(CFLAGS) -mtune=native -march=native
NFLAGS_NATIVE := $(NFLAGS) --passC:"$(CFLAGS_NATIVE)" -d:simd -d:avx2

CFLAGS_LEGACY := $(CFLAGS) -mtune=core2 -march=core2
NFLAGS_LEGACY := $(NFLAGS) --passC:"$(CFLAGS_LEGACY)" -u:simd -u:avx2

ifeq ($(SKIP_DEPS),)
avx512: deps net
modern: deps net
zen2: deps net
legacy: deps net
native: deps net
endif

avx512:
	$(ECHO) nim c $(NFLAGS_AVX512) $(SRCDIR)/heimdall.nim

modern:
	$(ECHO) nim c $(NFLAGS_MODERN) $(SRCDIR)/heimdall.nim

zen2:
	$(ECHO) nim c $(NFLAGS_ZEN2) $(SRCDIR)/heimdall.nim

legacy:
	$(ECHO) nim c $(NFLAGS_LEGACY) $(SRCDIR)/heimdall.nim

native:
	$(ECHO) nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim

deps:
	$(ECHO) nimble install -d

net:
	$(ECHO) git submodule update --init --recursive
	$(ECHO) cd networks && git fetch origin && git checkout FETCH_HEAD
	$(ECHO) git lfs fetch --include files/$(NET_NAME)

# Check if AVX-512 is supported (cross-platform)
AVX512_SUPPORTED := $(shell $(CC) -dM -E - </dev/null | grep -q '__AVX512F__' && echo 1 || echo 0)

releases: deps net
	@echo Building platform targets
	$(MAKE) -s legacy SKIP_DEPS=1 EXE=$(EXE_BASE)-linux-amd64-core2
	@echo Finished Core 2 build
	$(MAKE) -s modern SKIP_DEPS=1 EXE=$(EXE_BASE)-linux-amd64-haswell
	@echo Finished Haswell build
	$(MAKE) -s zen2 SKIP_DEPS=1 EXE=$(EXE_BASE)-linux-amd64-zen2
	@echo Finished Zen 2 build
	@if [ $(AVX512_SUPPORTED) -eq 1 ]; then \
		$(MAKE) -s avx512 SKIP_DEPS=1 EXE=$(EXE_BASE)-linux-amd64-avx512; \
		@echo Finished AVX-512 build; \
	fi
	@echo All targets built

openbench: deps
	nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim
