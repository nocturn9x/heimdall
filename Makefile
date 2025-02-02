.DEFAULT_GOAL := openbench

.SUFFIXES:

# Define a variable to conditionally prefix commands with "@".
ECHO = $(if $(filter 1,$(SKIP_DEPS)),@,)

CC := clang
EXE := bin/heimdall
EVALFILE := ../networks/files/mistilteinn.bin
NET_NAME := $(notdir $(EVALFILE))
LD := lld
SRCDIR := src


LFLAGS := -flto -fuse-ld=$(LD)
LFLAGS_WINDOWS := $(LFLAGS) -target x86_64-windows-gnu

HINTSFLAG = $(if $(filter 1,$(SKIP_DEPS)),--hints:off,)
NFLAGS_SHARED := -d:danger --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) -d:evalFile=$(EVALFILE) $(HINTSFLAG)

NFLAGS_WINDOWS := $(NFLAGS_SHARED) --os:windows --cpu:amd64 --cc:clang --cc.exe=zigcc --clang.options.linker="$(LFLAGS_WINDOWS)"
NFLAGS := $(NFLAGS_SHARED) --cc:$(CC) --passL:"$(LFLAGS)"

CFLAGS := -flto -static
CFLAGS_WINDOWS := $(CFLAGS) -target x86_64-windows-gnu --sysroot=/usr/x86_64-w64-mingw32

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

# Only needed for cross-compilation
CFLAGS_AVX512_WINDOWS := $(CFLAGS_WINDOWS) -mtune=znver4 -march=x86-64-v4
NFLAGS_AVX512_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_AVX512_WINDOWS)" -d:simd -d:avx512

CFLAGS_MODERN_WINDOWS := $(CFLAGS_WINDOWS) -mtune=haswell -march=haswell
NFLAGS_MODERN_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_MODERN_WINDOWS)" -d:simd -d:avx2

CFLAGS_ZEN2_WINDOWS := $(CFLAGS_WINDOWS) -march=bdver4 -mtune=znver2
NFLAGS_ZEN2_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_ZEN2_WINDOWS)" -d:simd -d:avx2

CFLAGS_NATIVE_WINDOWS := $(CFLAGS_WINDOWS) -mtune=native -march=native
NFLAGS_NATIVE_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_NATIVE_WINDOWS)" -d:simd -d:avx2

CFLAGS_LEGACY_WINDOWS := $(CFLAGS_WINDOWS) -mtune=core2 -march=core2
NFLAGS_LEGACY_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_LEGACY_WINDOWS)" -u:simd -u:avx2


# Conditionally include dependency prerequisites only when SKIP_DEPS is not set.
ifeq ($(SKIP_DEPS),)
avx512: deps net
modern: deps net
zen2: deps net
legacy: deps net
native: deps net
windows_native: deps net
windows_zen2: deps net
windows_modern: deps net
windows_legacy: deps net
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

windows_native:
	$(ECHO) nim c $(NFLAGS_NATIVE_WINDOWS) $(SRCDIR)/heimdall.nim

windows_zen2:
	$(ECHO) nim c $(NFLAGS_ZEN2_WINDOWS) $(SRCDIR)/heimdall.nim

windows_modern:
	$(ECHO) nim c $(NFLAGS_MODERN_WINDOWS) $(SRCDIR)/heimdall.nim

windows_legacy:
	$(ECHO) nim c $(NFLAGS_LEGACY_WINDOWS) $(SRCDIR)/heimdall.nim

deps:
	$(ECHO) nimble install -d

net:
	$(ECHO) git submodule update --init --recursive
	$(ECHO) cd networks && git fetch origin && git checkout FETCH_HEAD
	$(ECHO) git lfs fetch --include files/$(NET_NAME)

# "releases" runs deps and net once, then calls sub‑make for each target silently.
releases: deps net
	@echo Building all targets
	$(MAKE) -s legacy SKIP_DEPS=1 EXE=bin/heimdall-linux-amd64-core2
	@echo Finished Linux Core 2 build
	$(MAKE) -s modern SKIP_DEPS=1 EXE=bin/heimdall-linux-amd64-haswell
	@echo Finished Linux Haswell build
	$(MAKE) -s zen2 SKIP_DEPS=1 EXE=bin/heimdall-linux-amd64-zen2
	@echo Finished Linux Zen 2 build
	$(MAKE) -s avx512 SKIP_DEPS=1 EXE=bin/heimdall-linux-amd64-avx512
	@echo Finished Linux AVX-512 build
	$(MAKE) -s windows_legacy SKIP_DEPS=1 EXE=bin/heimdall-windows-amd64-core2
	@echo Finished Windows legacy build
	$(MAKE) -s windows_modern SKIP_DEPS=1 EXE=bin/heimdall-windows-amd64-haswell
	@echo Finished Windows Haswell build
	$(MAKE) -s windows_zen2 SKIP_DEPS=1 EXE=bin/heimdall-windows-amd64-zen2
	@echo Finished Windows Zen2 build
	$(MAKE) -s windows_avx512 SKIP_DEPS=1 EXE=bin/heimdall-windows-amd64-avx512
	@echo Finished Windows AVX-512 build
	@echo All targets built


openbench: deps
	nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim