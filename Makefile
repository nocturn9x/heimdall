.DEFAULT_GOAL := openbench

.SUFFIXES:

# Define a variable to conditionally prefix commands with "@".
ECHO = $(if $(filter 1,$(SKIP_DEPS)),@,)

CC := clang
EXE_BASE := bin/heimdall
EXE := $(EXE_BASE)$(if $(OS),.exe,)
EVALFILE := ../networks/files/mistilteinn-v2.bin
NET_NAME := $(notdir $(EVALFILE))
LD := lld
SRCDIR := src

LFLAGS := -flto -fuse-ld=$(LD)

HINTSFLAG = $(if $(filter 1,$(SKIP_DEPS)),--hints:off,)

INPUT_BUCKETS := 16
OUTPUT_BUCKETS := 8
MERGED_KINGS := 1
EVAL_NORMALIZE_FACTOR := 259
HORIZONTAL_MIRRORING := 1
HL_SIZE := 1536
FT_SIZE := 704
ENABLE_TUNING :=
IS_RELEASE :=
IS_BETA :=
IS_DEBUG :=
MAJOR_VERSION := 1
MINOR_VERSION := 3
PATCH_VERSION := 1

# Append conditional flags
CUSTOM_FLAGS := -d:outputBuckets=$(OUTPUT_BUCKETS) \
				-d:inputBuckets=$(INPUT_BUCKETS) \
                -d:hlSize=$(HL_SIZE) \
                -d:ftSize=$(FT_SIZE) \
				-d:evalNormalizeFactor=$(EVAL_NORMALIZE_FACTOR) \
				-d:majorVersion=$(MAJOR_VERSION) \
				-d:minorVersion=$(MINOR_VERSION) \
				-d:patchVersion=$(PATCH_VERSION) \
				-d:evalFile=$(EVALFILE)

ifeq ($(MERGED_KINGS),1)
    CUSTOM_FLAGS += -d:mergedKings
endif

ifeq ($(HORIZONTAL_MIRRORING),1)
    CUSTOM_FLAGS += -d:horizontalMirroring
endif

ifneq ($(ENABLE_TUNING),)
    CUSTOM_FLAGS += -d:enableTuning
endif

ifneq ($(IS_RELEASE),)
    CUSTOM_FLAGS += -d:isRelease
endif

ifneq ($(IS_BETA),)
    CUSTOM_FLAGS += -d:isBeta
endif

ifneq ($(IS_DEBUG),)
    CUSTOM_FLAGS += -d:debug
else
	CUSTOM_FLAGS += -d:danger
endif

NFLAGS := --path:src --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) $(HINTSFLAG) $(CUSTOM_FLAGS) --deepcopy:on --cc:$(CC) --passL:"$(LFLAGS)"

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
NFLAGS_LEGACY := $(NFLAGS) --passC:"$(CFLAGS_LEGACY)"

OS_TAG := $(if $(OS),windows,linux)

ifeq ($(SKIP_DEPS),)
avx512: deps net
modern: deps net
zen2: deps net
legacy: deps net
native: deps net
endif

avx512:
	@echo Building AVX512 binary
	$(ECHO) nim c $(NFLAGS_AVX512) $(SRCDIR)/heimdall.nim

modern:
	@echo Building Haswell binary
	$(ECHO) nim c $(NFLAGS_MODERN) $(SRCDIR)/heimdall.nim

zen2:
	@echo Building Zen 2 binary
	$(ECHO) nim c $(NFLAGS_ZEN2) $(SRCDIR)/heimdall.nim

legacy:
	@echo Building Core 2 binary
	$(ECHO) nim c $(NFLAGS_LEGACY) $(SRCDIR)/heimdall.nim

deps:
	@echo Verifying dependencies
	$(ECHO) nimble install -d

net:
	@echo Preparing neural network
	$(ECHO) git submodule update --init --recursive
	$(ECHO) git -C networks lfs fetch --include $(NET_NAME)

# Check if AVX-512 is supported (cross-platform)
ARCH_DEFINES := $(shell echo | $(CXX) -march=native -E -dM -)

AVX512_SUPPORTED := 0

ifneq ($(findstring __AVX512F__, $(ARCH_DEFINES)),)
    ifneq ($(findstring __AVX512BW__, $(ARCH_DEFINES)),)
        AVX512_SUPPORTED := 1
    endif
endif


native:
	@echo Building native target
	@if [ $(AVX512_SUPPORTED) -eq 1 ]; then \
		echo Compiling AVX512 binary; \
		nim c $(NFLAGS_AVX512) $(SRCDIR)/heimdall.nim; \
	else \
		echo Compiling AVX2 binary; \
		nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim; \
	fi
	@echo Native target built


# For builds during development
dev:
	$(MAKE) -s native SKIP_DEPS=1

releases: deps net
	@echo Building platform targets
	$(MAKE) -s legacy SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/heimdall-$(OS_TAG)-amd64-core2
	@echo Finished Core 2 build
	$(MAKE) -s modern SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/heimdall-$(OS_TAG)-amd64-haswell
	@echo Finished Haswell build
	$(MAKE) -s zen2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/heimdall-$(OS_TAG)-amd64-zen2
	@echo Finished Zen 2 build
	@if [ $(AVX512_SUPPORTED) -eq 1 ]; then \
		@echo AVX512 support detected \
		$(MAKE) -s avx512 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/heimdall-$(OS_TAG)-amd64-avx512; \
		@echo Finished AVX-512 build; \
	fi
	@echo All platform targets built

openbench: deps
	@if [ $(AVX512_SUPPORTED) -eq 1 ]; then \
		nim c $(NFLAGS_AVX512) $(SRCDIR)/heimdall.nim; \
	else \
		nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim; \
	fi
