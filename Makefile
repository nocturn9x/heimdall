.DEFAULT_GOAL := release

.SUFFIXES:

CC := clang
EXE := bin/heimdall
GDB := gdb
LD := ld
SRCDIR := heimdall
CFLAGS_RELEASE := -flto -Ofast -mtune=native -march=native
CFLAGS_DEBUG := -g -fno-omit-frame-pointer
LFLAGS_RELEASE := -flto -fuse-ld=$(LD)
LFLAGS_DEBUG := -fuse-ld=$(LD)
NFLAGS := --cc:$(CC) --mm:arc -d:useMalloc -o:$(EXE)
NFLAGS_RELEASE := $(NFLAGS) -d:danger --passC:"$(CFLAGS_RELEASE)" --passL:"$(LFLAGS_RELEASE)"
NFLAGS_DEBUG := $(NFLAGS) -d:debug --passC:"$(CFLAGS_DEBUG)" --passL:"$(LFLAGS_DEBUG)" --debugger:native


release:
	nimble install -d
	nim c $(NFLAGS_RELEASE) $(SRCDIR)/heimdall.nim

debug:
	nimble install -d
	nim c $(NFLAGS_DEBUG) $(SRCDIR)/heimdall.nim
