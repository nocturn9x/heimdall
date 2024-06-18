.SUFFIXES:

CC := clang
GDB := gdb
LD := lld
SRCDIR := src
BUILDDIR := bin
CFLAGS := -flto -Ofast -mtune=native -march=native
LFLAGS := -flto -fuse-ld=$(LD)
NFLAGS := --cc:$(CC) --mm:arc -d:useMalloc -o:$(BUILDDIR)/heimdall --passC:"$(CFLAGS)" --passL:"$(LFLAGS)"


release:
	nim c $(NFLAGS) -d:danger heimdall/heimdall

debug:
	nim c $(NFLAGS) -d:debug heimdall/heimdall
