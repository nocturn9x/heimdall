.DEFAULT_GOAL := openbench

.SUFFIXES:

CC := clang
EXE := bin/heimdall
EVALFILE := ../networks/files/mistilteinn.bin
NET_NAME := $(notdir $(EVALFILE))
LD := lld
SRCDIR := src

LFLAGS := -flto -fuse-ld=$(LD)
LFLAGS_WINDOWS := $(LFLAGS) -target x86_64-windows-gnu

NFLAGS_SHARED := -d:danger --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) -d:evalFile=$(EVALFILE)
NFLAGS_WINDOWS := $(NFLAGS_SHARED) --os:windows --cpu:amd64 --cc:clang --cc.exe=zigcc --clang.options.linker="$(LFLAGS_WINDOWS)"
NFLAGS := $(NFLAGS_SHARED) --cc:$(CC) --passL:"$(LFLAGS)"

CFLAGS := -flto -static
CFLAGS_WINDOWS := $(CFLAGS) -target x86_64-windows-gnu --sysroot=/usr/x86_64-w64-mingw32

CFLAGS_MODERN := $(CFLAGS) -mtune=haswell -march=haswell
NFLAGS_MODERN := $(NFLAGS) --passC:"$(CFLAGS_MODERN)" -d:simd -d:avx2

CFLAGS_ZEN2 := $(CFLAGS) -march=bdver4 -mtune=znver2
NFLAGS_ZEN2 := $(NFLAGS) --passC:"$(CFLAGS_ZEN2)" -d:simd -d:avx2

CFLAGS_NATIVE := $(CFLAGS) -mtune=native -march=native
NFLAGS_NATIVE := $(NFLAGS) --passC:"$(CFLAGS_NATIVE)" -d:simd -d:avx2

CFLAGS_LEGACY := $(CFLAGS) -mtune=core2 -march=core2
NFLAGS_LEGACY := $(NFLAGS) --passC:"$(CFLAGS_LEGACY)" -u:simd -u:avx2

# Only needed for cross-compilation
CFLAGS_MODERN_WINDOWS := $(CFLAGS_WINDOWS) -mtune=haswell -march=haswell
NFLAGS_MODERN_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_MODERN_WINDOWS)" -d:simd -d:avx2

CFLAGS_ZEN2_WINDOWS := $(CFLAGS_WINDOWS) -march=bdver4 -mtune=znver2
NFLAGS_ZEN2_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_ZEN2_WINDOWS)" -d:simd -d:avx2

CFLAGS_NATIVE_WINDOWS := $(CFLAGS_WINDOWS) -mtune=native -march=native
NFLAGS_NATIVE_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_NATIVE_WINDOWS)" -d:simd -d:avx2

CFLAGS_LEGACY_WINDOWS := $(CFLAGS_WINDOWS) -mtune=core2 -march=core2
NFLAGS_LEGACY_WINDOWS := $(NFLAGS_WINDOWS) --passC:"$(CFLAGS_LEGACY_WINDOWS)" -u:simd -u:avx2


deps:
	nimble install -d

net:
	git submodule update --init --recursive
	cd networks && git fetch origin && git checkout FETCH_HEAD
	git lfs fetch --include files/$(NET_NAME)

modern: deps net
	nim c $(NFLAGS_MODERN) $(SRCDIR)/heimdall.nim

zen2: deps net
	nim c $(NFLAGS_ZEN2) $(SRCDIR)/heimdall.nim

legacy: deps net
	nim c $(NFLAGS_LEGACY) $(SRCDIR)/heimdall.nim

native: deps net
	nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim

windows_native: deps net
	nim c $(NFLAGS_NATIVE_WINDOWS) $(SRCDIR)/heimdall.nim

windows_zen2: deps net
	nim c $(NFLAGS_ZEN2_WINDOWS) $(SRCDIR)/heimdall.nim

windows_modern: deps net
	nim c $(NFLAGS_MODERN_WINDOWS) $(SRCDIR)/heimdall.nim

windows_legacy: deps net
	nim c $(NFLAGS_LEGACY_WINDOWS) $(SRCDIR)/heimdall.nim


openbench: deps
	nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim