.DEFAULT_GOAL := native

.SUFFIXES:

CC := clang
EXE := bin/heimdall
EVALFILE := ../hofud-v2.bin
LD := ld
SRCDIR := heimdall
LFLAGS := -flto -fuse-ld=$(LD)
NFLAGS := --cc:$(CC) --mm:atomicArc -d:useMalloc -o:$(EXE) -d:evalFile=$(EVALFILE)

CFLAGS_MODERN := -flto -mtune=haswell -march=haswell -static
NFLAGS_MODERN := $(NFLAGS) -d:danger --passC:"$(CFLAGS_MODERN)" --passL:"$(LFLAGS)" -d:simd -d:avx2

CFLAGS_NATIVE:= -flto -mtune=native -march=native -static
NFLAGS_NATIVE := $(NFLAGS) -d:danger --passC:"$(CFLAGS_MODERN)" --passL:"$(LFLAGS)" -d:simd -d:avx2

CFLAGS_LEGACY := -flto -mtune=core2 -march=core2 -static
NFLAGS_LEGACY := $(NFLAGS) -d:danger --passC:"$(CFLAGS_LEGACY)" --passL:"$(LFLAGS)" -u:simd -u:avx2


deps:
	nimble install -d

modern: deps
	nim c $(NFLAGS_MODERN) $(SRCDIR)/heimdall.nim

legacy: deps
	nim c $(NFLAGS_LEGACY) $(SRCDIR)/heimdall.nim

native: deps
	nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim