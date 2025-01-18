.DEFAULT_GOAL := native

.SUFFIXES:

CC := clang
EXE := bin/heimdall
EVALFILE := ../networks/files/mistilteinn.bin
NET_NAME := $(notdir $(EVALFILE))
LD := ld
SRCDIR := src
LFLAGS := -flto -fuse-ld=$(LD)
NFLAGS := --panics:on --cc:$(CC) --mm:atomicArc -d:useMalloc -o:$(EXE) --passL:"$(LFLAGS)" -d:evalFile=$(EVALFILE)
CFLAGS := -flto -static

CFLAGS_MODERN := $(CFLAGS) -mtune=haswell -march=haswell
NFLAGS_MODERN := $(NFLAGS) -d:danger --passC:"$(CFLAGS_MODERN)" -d:simd -d:avx2

CFLAGS_NATIVE:= $(CFLAGS) -mtune=native -march=native
NFLAGS_NATIVE := $(NFLAGS) -d:danger --passC:"$(CFLAGS_NATIVE)" -d:simd -d:avx2

CFLAGS_LEGACY := $(CFLAGS) -mtune=core2 -march=core2
NFLAGS_LEGACY := $(NFLAGS) -d:danger --passC:"$(CFLAGS_LEGACY)" -u:simd -u:avx2


deps:
	nimble install -d

net:
	git submodule update --init --recursive
	cd networks && git fetch origin && git checkout FETCH_HEAD
	git lfs fetch --include files/$(NET_NAME)

modern: deps net
	nim c $(NFLAGS_MODERN) $(SRCDIR)/heimdall.nim

legacy: deps net
	nim c $(NFLAGS_LEGACY) $(SRCDIR)/heimdall.nim

native: deps net
	nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim