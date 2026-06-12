.DEFAULT_GOAL := openbench

.SUFFIXES:

ECHO = $(if $(filter 1,$(SKIP_DEPS)),@,)

CC := clang
EXE_BASE := bin/heimdall
EXE := $(EXE_BASE)$(if $(OS),.exe,)
EVALFILE := ../morelayers-v1.bin
NET_NAME := $(notdir $(EVALFILE))
NET_ID := $(basename $(NET_NAME))
LD := lld
SRCDIR := src

ifeq ($(OS),Windows_NT)
  SETENV = set GIT_LFS_SKIP_SMUDGE=1 && 
else
  SETENV = GIT_LFS_SKIP_SMUDGE=1 
endif


LFLAGS := -flto -fuse-ld=$(LD)

ifeq ($(OS),Windows_NT)
  # Windows' default stack size of 1MiB causes stack overflows as soon as the engine
  # enters UCI mode, so bump it to 8MiB
  LFLAGS += -Wl,--stack,8388608
endif

HINTSFLAG = $(if $(filter 1,$(SKIP_DEPS)),--hints:off,)

INPUT_BUCKETS := 16
OUTPUT_BUCKETS := 8
MERGED_KINGS := 0
EVAL_NORMALIZE_FACTOR := 292
HORIZONTAL_MIRRORING := 1
VERBATIM_NET := 0
FT_SIZE := 768
L1_SIZE := 1536
L2_SIZE := 16
L3_SIZE := 32
EVAL_SCALE := 322
FT_QUANT_BITS := 8
L1_QUANT_BITS := 7
QUANT_BITS := 6
FT_SCALE_BITS := 7
DUAL_ACTIVATION := 1
ENABLE_TUNING := 0
IS_RELEASE := 0
IS_BETA := 0
IS_DEBUG := 0
IS_TEST := 0
DBG_SYMBOLS := 0
MAJOR_VERSION := 1
MINOR_VERSION := 4
PATCH_VERSION := 3
THP_PAGE_ALIGNMENT := 2097152


CFLAGS := -flto -static
CUSTOM_FLAGS := -d:outputBuckets=$(OUTPUT_BUCKETS) \
				-d:inputBuckets=$(INPUT_BUCKETS) \
                -d:ftSize=$(FT_SIZE) \
                -d:l1Size=$(L1_SIZE) \
				-d:l2Size=$(L2_SIZE) \
                -d:l3Size=$(L3_SIZE) \
				-d:evalScale=$(EVAL_SCALE) \
				-d:ftQuantBits=$(FT_QUANT_BITS) \
				-d:l1QuantBits=$(L1_QUANT_BITS) \
				-d:quantBits=$(QUANT_BITS) \
				-d:ftScaleBits=$(FT_SCALE_BITS) \
				-d:evalNormalizeFactor=$(EVAL_NORMALIZE_FACTOR) \
				-d:majorVersion=$(MAJOR_VERSION) \
				-d:minorVersion=$(MINOR_VERSION) \
				-d:patchVersion=$(PATCH_VERSION) \
				-d:evalFile=$(EVALFILE) \
				-d:netID=$(NET_ID) \
				-d:thpPageAlignment:$(THP_PAGE_ALIGNMENT) \
				-d:esc_exit_editing

ifeq ($(MERGED_KINGS),1)
    CUSTOM_FLAGS += -d:mergedKings=true
else
	CUSTOM_FLAGS += -d:mergedKings=false
endif

ifeq ($(DUAL_ACTIVATION),1)
    CUSTOM_FLAGS += -d:dualActivation
else
	CUSTOM_FLAGS += -d:dualActivation=false
endif

ifeq ($(VERBATIM_NET),1)
    CUSTOM_FLAGS += -d:verbatimNet=true
else
	CUSTOM_FLAGS += -d:verbatimNet=false
endif

ifeq ($(PAIRWISE_NET),1)
    CUSTOM_FLAGS += -d:pairwiseNet=true
else
	CUSTOM_FLAGS += -d:pairwiseNet=false
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
else ifeq ($(IS_TEST),1)
	CUSTOM_FLAGS += -d:release
else
	CUSTOM_FLAGS += -d:danger
endif

ifeq ($(DBG_SYMBOLS),1)
    CUSTOM_FLAGS += --debugger:native
	CFLAGS += -fno-omit-frame-pointer -ggdb
endif

NFLAGS := --path:src --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) $(HINTSFLAG) $(CUSTOM_FLAGS) --deepcopy:on --cc:$(CC) --passL:"$(LFLAGS)"


CFLAGS_AVX512 := $(CFLAGS) -mtune=znver4 -march=x86-64-v4
NFLAGS_AVX512 := $(NFLAGS) --passC:"$(CFLAGS_AVX512)" -d:simd -d:avx512

CFLAGS_VNNI := $(CFLAGS_AVX512) -mavx512vnni
NFLAGS_VNNI := $(NFLAGS) --passC:"$(CFLAGS_VNNI)" -d:simd -d:avx512 -d:vnni

CFLAGS_MODERN := $(CFLAGS) -mtune=haswell -march=haswell
NFLAGS_MODERN := $(NFLAGS) --passC:"$(CFLAGS_MODERN)" -d:simd -d:avx2

CFLAGS_ZEN2 := $(CFLAGS) -march=znver2 -mtune=znver2
NFLAGS_ZEN2 := $(NFLAGS) --passC:"$(CFLAGS_ZEN2)" -d:simd -d:avx2

CFLAGS_NATIVE := $(CFLAGS) -mtune=native -march=native
NFLAGS_NATIVE := $(NFLAGS) --passC:"$(CFLAGS_NATIVE)" -d:simd -d:avx2

CFLAGS_LEGACY := $(CFLAGS) -mtune=core2 -march=core2
NFLAGS_LEGACY := $(NFLAGS) --passC:"$(CFLAGS_LEGACY)" -u:simd -u:avx2

OS_TAG := $(if $(OS),windows,linux)

COMMIT := $(shell git rev-parse --short=6 HEAD 2>/dev/null || echo unknown)
RELEASE_BASE := heimdall-$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-$(OS_TAG)-amd64
PRERELEASE_BASE := heimdall-dev-$(COMMIT)-$(OS_TAG)-amd64


ifeq ($(SKIP_DEPS),)
avx512: deps net
vnni: deps net
modern: deps net
zen2: deps net
legacy: deps net
native: deps net
endif


avx512:
	@echo Building AVX512 binary
	$(ECHO) nim c $(NFLAGS_AVX512) $(SRCDIR)/heimdall.nim

vnni:
	@echo Building AVX512 VNNI binary
	$(ECHO) nim c $(NFLAGS_VNNI) $(SRCDIR)/heimdall.nim

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
	$(ECHO) $(SETENV)git submodule update --init --recursive
	$(ECHO) git -C networks lfs install --local
	$(ECHO) git -C networks lfs fetch --include="files/$(NET_NAME)" && git -C networks lfs checkout "files/$(NET_NAME)"


ARCH_DEFINES := $(shell echo | $(CXX) -march=native -E -dM -)
AVX512_SUPPORTED := 0
VNNI_SUPPORTED := 0
ifneq ($(findstring __AVX512F__, $(ARCH_DEFINES)),)
  ifneq ($(findstring __AVX512BW__, $(ARCH_DEFINES)),)
    AVX512_SUPPORTED := 1
    ifneq ($(findstring __AVX512VNNI__, $(ARCH_DEFINES)),)
      VNNI_SUPPORTED := 1
    endif
  endif
endif


ifeq ($(VNNI_SUPPORTED),1)
define NATIVE_BUILD_CMD
	@echo "Building native target (AVX512 VNNI)"
	$(ECHO) nim c $(NFLAGS_VNNI) $(SRCDIR)/heimdall.nim
	@echo Native target built
endef
else ifeq ($(AVX512_SUPPORTED),1)
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

test:
	$(MAKE) -s native SKIP_DEPS=1 IS_TEST=1 EXE_BASE=bin/testdall
	./bin/testdall bench 9

test-suite:
	$(MAKE) -s native SKIP_DEPS=1 IS_TEST=1 EXE_BASE=bin/testdall
	./bin/testdall bench 15
	python tests/suite.py -d 6 -b -p -s -f tests/all.txt --heimdall bin/testdall
	python tests/suite.py -d 7 -b -p -s -f tests/standard_heavy.txt --heimdall bin/testdall
 
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

ifeq ($(VNNI_SUPPORTED),1)
define VNNI_RELEASES_CMD
	@echo AVX512 VNNI support detected
	$(MAKE) -s vnni SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-vnni
	@echo Finished AVX-512 VNNI build
endef
else
VNNI_RELEASES_CMD =
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
	$(VNNI_RELEASES_CMD)
	@echo All platform targets built

ci-releases: deps net
	@echo Building CI release platform targets
	$(MAKE) -s legacy SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-core2
	@echo Finished Core 2 build
	$(MAKE) -s modern SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-haswell
	@echo Finished Haswell build
	$(MAKE) -s zen2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-zen2
	@echo Finished Zen 2 build
	$(MAKE) -s avx512 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx512
	@echo Finished AVX-512 build
	$(MAKE) -s vnni SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-vnni
	@echo Finished AVX-512 VNNI build
	@echo All CI release platform targets built

prereleases: deps net
	@echo Building prerelease platform targets
	$(MAKE) -s legacy SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-core2
	@echo Finished Core 2 build
	$(MAKE) -s modern SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-haswell
	@echo Finished Haswell build
	$(MAKE) -s zen2 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-zen2
	@echo Finished Zen 2 build
	$(MAKE) -s avx512 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-avx512
	@echo Finished AVX-512 build
	$(MAKE) -s vnni SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-vnni
	@echo Finished AVX-512 VNNI build
	@echo All prerelease platform targets built

openbench: deps
	$(NATIVE_BUILD_CMD)
