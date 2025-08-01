.DEFAULT_GOAL := openbench

.SUFFIXES:

ECHO = $(if $(filter 1,$(SKIP_DEPS)),@,)

CC := clang
EXE_BASE := bin/heimdall
EXE := $(EXE_BASE)$(if $(OS),.exe,)
EVALFILE := ../networks/files/mistilteinn-v3-verbatim.bin
NET_NAME := $(notdir $(EVALFILE))
NET_ID := $(basename $(NET_NAME))
LD := lld
SRCDIR := src

LFLAGS := -flto -fuse-ld=$(LD)

HINTSFLAG = $(if $(filter 1,$(SKIP_DEPS)),--hints:off,)

INPUT_BUCKETS := 16
OUTPUT_BUCKETS := 8
MERGED_KINGS := 0
EVAL_NORMALIZE_FACTOR := 337
HORIZONTAL_MIRRORING := 1
VERBATIM_NET := 1
HL_SIZE := 1536
FT_SIZE := 768
ENABLE_TUNING := 0
IS_RELEASE := 1
IS_BETA := 0
IS_DEBUG := 0
DBG_SYMBOLS := 0
MAJOR_VERSION := 1
MINOR_VERSION := 4
PATCH_VERSION := 0


CUSTOM_FLAGS := -d:outputBuckets=$(OUTPUT_BUCKETS) \
				-d:inputBuckets=$(INPUT_BUCKETS) \
                -d:hlSize=$(HL_SIZE) \
                -d:ftSize=$(FT_SIZE) \
				-d:evalNormalizeFactor=$(EVAL_NORMALIZE_FACTOR) \
				-d:majorVersion=$(MAJOR_VERSION) \
				-d:minorVersion=$(MINOR_VERSION) \
				-d:patchVersion=$(PATCH_VERSION) \
				-d:evalFile=$(EVALFILE) \
				-d:netID=$(NET_ID)

ifeq ($(MERGED_KINGS),1)
    CUSTOM_FLAGS += -d:mergedKings
else
	CUSTOM_FLAGS += -d:mergedKings=false
endif

ifeq ($(VERBATIM_NET),1)
    CUSTOM_FLAGS += -d:verbatimNet=true
else
	CUSTOM_FLAGS += -d:verbatimNet=false
endif

ifeq ($(HORIZONTAL_MIRRORING),1)
    CUSTOM_FLAGS += -d:horizontalMirroring=true
else
	CUSTOM_FLAGS += -d:horizontalMirroring=false
endif

ifeq ($(ENABLE_TUNING),1)
    CUSTOM_FLAGS += -d:enableTuning
endif

ifeq ($(IS_RELEASE),1)
    CUSTOM_FLAGS += -d:isRelease
endif

ifeq ($(IS_BETA),1)
    CUSTOM_FLAGS += -d:isBeta
endif

ifeq ($(IS_DEBUG),1)
    CUSTOM_FLAGS += -d:debug
else
	CUSTOM_FLAGS += -d:danger
endif

CFLAGS := -flto -static

ifeq ($(DBG_SYMBOLS),1)
    CUSTOM_FLAGS += --debugger:native
	CFLAGS += -fno-omit-frame-pointer -ggdb
endif

NFLAGS := --path:src --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) $(HINTSFLAG) $(CUSTOM_FLAGS) --deepcopy:on --cc:$(CC) --passL:"$(LFLAGS)"


CFLAGS_AVX512 := $(CFLAGS) -mtune=znver4 -march=x86-64-v4
NFLAGS_AVX512 := $(NFLAGS) --passC:"$(CFLAGS_AVX512)" -d:simd -d:avx512

CFLAGS_MODERN := $(CFLAGS) -mtune=haswell -march=haswell
NFLAGS_MODERN := $(NFLAGS) --passC:"$(CFLAGS_MODERN)" -d:simd -d:avx2

CFLAGS_ZEN2 := $(CFLAGS) -march=znver2 -mtune=znver2
NFLAGS_ZEN2 := $(NFLAGS) --passC:"$(CFLAGS_ZEN2)" -d:simd -d:avx2

CFLAGS_NATIVE := $(CFLAGS) -mtune=native -march=native
NFLAGS_NATIVE := $(NFLAGS) --passC:"$(CFLAGS_NATIVE)" -d:simd -d:avx2

CFLAGS_LEGACY := $(CFLAGS) -mtune=core2 -march=core2
NFLAGS_LEGACY := $(NFLAGS) --passC:"$(CFLAGS_LEGACY)" -u:simd -u:avx2

OS_TAG := $(if $(OS),windows,linux)

RELEASE_BASE := heimdall-$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-$(OS_TAG)-amd64


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


ARCH_DEFINES := $(shell echo | $(CXX) -march=native -E -dM -)
AVX512_SUPPORTED := 0
ifneq ($(findstring __AVX512F__, $(ARCH_DEFINES)),)
  ifneq ($(findstring __AVX512BW__, $(ARCH_DEFINES)),)
    AVX512_SUPPORTED := 1
  endif
endif


ifeq ($(AVX512_SUPPORTED),1)
define NATIVE_BUILD_CMD
	@echo "Building native target (AVX512)"
	$(ECHO) nim c $(NFLAGS_AVX512) $(SRCDIR)/heimdall.nim
	@echo Native target built
endef
else
define NATIVE_BUILD_CMD
	@echo "Building native target (AVX2)"
	$(ECHO) nim c $(NFLAGS_NATIVE) $(SRCDIR)/heimdall.nim
	@echo Native target built
endef
endif

native:
	$(NATIVE_BUILD_CMD)

dev:
	$(MAKE) -s native SKIP_DEPS=1

bench: dev
	$(EXE) bench


ifeq ($(AVX512_SUPPORTED),1)
define AVX512_RELEASES_CMD
	@echo AVX512 support detected
	$(MAKE) -s avx512 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx512
	@echo Finished AVX-512 build
endef
else
AVX512_RELEASES_CMD =
endif

releases: deps net
	@echo Building platform targets
	$(MAKE) -s legacy SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-core2
	@echo Finished Core 2 build
	$(MAKE) -s modern SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-haswell
	@echo Finished Haswell build
	$(MAKE) -s zen2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-zen2
	@echo Finished Zen 2 build
	$(AVX512_RELEASES_CMD)
	@echo All platform targets built

openbench: deps
	$(NATIVE_BUILD_CMD)
