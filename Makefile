# Copyright 2026 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.DEFAULT_GOAL := openbench

.SUFFIXES:

ECHO = $(if $(filter 1,$(SKIP_DEPS)),@,)

CC := clang
EXE_BASE := bin/heimdall
EXE_EXT := $(if $(OS),.exe,)
EXE := $(EXE_BASE)$(EXE_EXT)
SINGLE_LAYER ?= 0
ifeq ($(SINGLE_LAYER),1)
	EVALFILE := $(CURDIR)/threans.bin
else
	EVALFILE := ../networks/files/tyrfing.bin
ifeq ($(strip $(EVALFILE)),)
	$(error Set EVALFILE to a multilayer TI network when SINGLE_LAYER=0)
endif
endif
NET_NAME := $(notdir $(EVALFILE))
NET_ID := $(basename $(NET_NAME))
LD := lld
SRCDIR := src
MAIN ?= $(SRCDIR)/heimdall.nim
EXTRA_NFLAGS ?=
NIMBLE_FLAGS ?=
# Select an inference backend independently of the build host for testing.
SIMD ?= auto
# CPU tuning for portable targets does not change their instruction-set baseline.
TUNE ?= generic
HOST_ARCH := $(shell $(CC) -dumpmachine)

ifeq ($(OS),Windows_NT)
  SETENV = set GIT_LFS_SKIP_SMUDGE=1 && 
else
  SETENV = GIT_LFS_SKIP_SMUDGE=1 
endif

STACK_SIZE := 8388608
LFLAGS := -flto

# Linux is megabased and grants us 8 MiB of glorious stack by default. Other
# systems might be sad little betas and only give us 1 MiB (or even much less).
# Nothing a few platform-specific linker flags can't fix.
ifeq ($(OS),Windows_NT)
  # PE/COFF: reserve 8 MiB (the optional second value would be the commit size).
  LFLAGS += -fuse-ld=$(LD) -Wl,--stack,$(STACK_SIZE)
else
  UNAME_S ?= $(shell uname -s)
  ifeq ($(UNAME_S),Darwin)
    MACOSX_DEPLOYMENT_TARGET ?= 11.0
    export MACOSX_DEPLOYMENT_TARGET
    # Mach-O's -stack_size requires a hexadecimal value. ld64.lld currently
    # ignores this option, so use Apple's linker for the macOS build.
    LFLAGS += -fuse-ld=ld -Wl,-stack_size,0x800000 -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
  else ifeq ($(UNAME_S),Linux)
    # Record the requested size in the ELF PT_GNU_STACK program header.
    LFLAGS += -fuse-ld=$(LD) -Wl,-z,stack-size=$(STACK_SIZE)
  else
    $(error Unsupported host OS '$(UNAME_S)')
  endif
endif

HINTSFLAG = $(if $(filter 1,$(SKIP_DEPS)),--hints:off,)

ifeq ($(SINGLE_LAYER),1)
INPUT_BUCKETS := 1
OUTPUT_BUCKETS := 1
L1_SIZE := 32
EVAL_SCALE := 400
else
INPUT_BUCKETS := 16
OUTPUT_BUCKETS := 8
L1_SIZE := 512
EVAL_SCALE := 305
endif
MERGED_KINGS := 0
EVAL_NORMALIZE_FACTOR := 292
HORIZONTAL_MIRRORING := 1
VERBATIM_NET := 0
FT_SIZE := 768
L2_SIZE := 16
L3_SIZE := 32
FT_QUANT_BITS := 8
L1_QUANT_BITS := 7
L1_BIAS_SHIFT := 0
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
MINOR_VERSION := 5
PATCH_VERSION := 1
THP_PAGE_ALIGNMENT := 2097152

ifeq ($(IS_RELEASE),1)
ifeq ($(SINGLE_LAYER),1)
$(error The single-layer debug fixture must not be released)
endif
ifeq ($(NET_NAME),threans.bin)
$(error threans must not be released)
endif
endif


ifeq ($(UNAME_S),Darwin)
CFLAGS := -flto -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
else
CFLAGS := -flto -static
endif
CUSTOM_FLAGS := -d:singleLayer=$(if $(filter 1,$(SINGLE_LAYER)),true,false) \
                -d:outputBuckets=$(OUTPUT_BUCKETS) \
				-d:inputBuckets=$(INPUT_BUCKETS) \
                -d:ftSize=$(FT_SIZE) \
                -d:l1Size=$(L1_SIZE) \
				-d:l2Size=$(L2_SIZE) \
                -d:l3Size=$(L3_SIZE) \
				-d:evalScale=$(EVAL_SCALE) \
				-d:ftQuantBits=$(FT_QUANT_BITS) \
				-d:l1QuantBits=$(L1_QUANT_BITS) \
				-d:l1BiasShift=$(L1_BIAS_SHIFT) \
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

NFLAGS := --path:src --panics:on --mm:atomicArc -d:useMalloc -o:$(EXE) $(HINTSFLAG) $(CUSTOM_FLAGS) --deepcopy:on --cc:$(CC) --passL:"$(LFLAGS)" --maxLoopIterationsVM:536870912 $(EXTRA_NFLAGS) -u:simd -u:avx2 -u:avx512 -u:vnni -u:sse2 -u:ssse3 -u:sse41 -u:neon


CFLAGS_AVX512 := $(CFLAGS) -march=x86-64-v4 -mtune=$(TUNE)
NFLAGS_AVX512 := $(NFLAGS) --passC:"$(CFLAGS_AVX512)" -d:simd -d:avx512

CFLAGS_AVX512_VNNI := $(CFLAGS_AVX512) -mavx512vnni
NFLAGS_AVX512_VNNI := $(NFLAGS) --passC:"$(CFLAGS_AVX512_VNNI)" -d:simd -d:avx512 -d:vnni

CFLAGS_AVX2 := $(CFLAGS) -march=x86-64-v3 -mtune=$(TUNE)
NFLAGS_AVX2 := $(NFLAGS) --passC:"$(CFLAGS_AVX2)" -d:simd -d:avx2

ifneq ($(filter aarch64% arm64%,$(HOST_ARCH)),)
NATIVE_ARCH_FLAGS := -mcpu=native
else
NATIVE_ARCH_FLAGS := -mtune=native -march=native
endif
CFLAGS_NATIVE := $(CFLAGS) $(NATIVE_ARCH_FLAGS)
NFLAGS_NATIVE := $(NFLAGS) --passC:"$(CFLAGS_NATIVE)" -d:simd -d:avx2

NFLAGS_SCALAR := $(NFLAGS) --passC:"$(CFLAGS_NATIVE)"

CFLAGS_SSE2 := $(CFLAGS) -march=x86-64 -mtune=$(TUNE)
NFLAGS_SSE2 := $(NFLAGS) --passC:"$(CFLAGS_SSE2)" -d:simd -d:sse2
CFLAGS_SSSE3 := $(CFLAGS) -march=x86-64 -mssse3 -mtune=$(TUNE)
NFLAGS_SSSE3 := $(NFLAGS) --passC:"$(CFLAGS_SSSE3)" -d:simd -d:ssse3
CFLAGS_SSE41 := $(CFLAGS) -march=x86-64 -msse4.1 -mtune=$(TUNE)
NFLAGS_SSE41 := $(NFLAGS) --passC:"$(CFLAGS_SSE41)" -d:simd -d:sse41
CFLAGS_NEON := $(CFLAGS) -march=armv8-a -mtune=$(TUNE)
NFLAGS_NEON := $(NFLAGS) --passC:"$(CFLAGS_NEON)" -d:simd -d:neon

OS_TAG := $(if $(OS),windows,$(if $(filter Darwin,$(UNAME_S)),macos,linux))
ARCH_TAG := $(if $(filter aarch64% arm64%,$(HOST_ARCH)),arm64,amd64)

COMMIT := $(shell git rev-parse --short=6 HEAD 2>/dev/null || echo unknown)
RELEASE_BASE := heimdall-$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-$(OS_TAG)-$(ARCH_TAG)
PRERELEASE_BASE := heimdall-dev-$(COMMIT)-$(OS_TAG)-$(ARCH_TAG)
BENCH_COMMIT ?= HEAD
BENCH_DEPTH ?= 13
BENCH_BIN_GLOB ?= bin/heimdall-*-$(OS_TAG)-$(ARCH_TAG)-*
BENCH_BINARIES ?= $(BENCH_BIN_GLOB)

# Optional profile-guided build; normal dev/OpenBench builds remain unchanged.
PGO ?= 0
PGO_DIR ?= build/pgo
PGO_TRAIN_EXE_BASE ?= $(PGO_DIR)/heimdall-train
PGO_TRAIN_EXE := $(PGO_TRAIN_EXE_BASE)$(EXE_EXT)
PGO_POSITIONS ?= src/heimdall/resources/misc/bench.txt
PGO_TRAIN_ARGS ?= --count 24 --offset 0 --stride 2
PGO_TRAIN_NODES ?= 200000
PGO_TRAIN_MSEC ?= 200
PGO_RAW_NODES := $(abspath $(PGO_DIR)/nodes.profraw)
PGO_RAW_TIME := $(abspath $(PGO_DIR)/time.profraw)
PGO_DATA := $(abspath $(PGO_DIR)/heimdall.profdata)
LLVM_PROFDATA ?= llvm-profdata
PYTHON ?= python

ifeq ($(OS),Windows_NT)
PGO_PREPARE_DIR = if not exist "$(PGO_DIR)" mkdir "$(PGO_DIR)"
PGO_NODE_ENV = set "LLVM_PROFILE_FILE=$(PGO_RAW_NODES)" &&
PGO_TIME_ENV = set "LLVM_PROFILE_FILE=$(PGO_RAW_TIME)" &&
else
PGO_PREPARE_DIR = mkdir -p "$(PGO_DIR)"
PGO_NODE_ENV = LLVM_PROFILE_FILE="$(PGO_RAW_NODES)"
PGO_TIME_ENV = LLVM_PROFILE_FILE="$(PGO_RAW_TIME)"
endif


ifeq ($(SKIP_DEPS),)
avx512: deps net
avx512-vnni: deps net
avx2: deps net
sse2: deps net
ssse3: deps net
sse41: deps net
neon: deps net
scalar: deps net
native: deps net
endif


avx512:
	@echo "Building x86-64-v4 binary (AVX-512)"
	$(ECHO) nim c $(NFLAGS_AVX512) $(MAIN)

avx512-vnni:
	@echo "Building x86-64-v4 binary (AVX-512 VNNI)"
	$(ECHO) nim c $(NFLAGS_AVX512_VNNI) $(MAIN)

avx2:
	@echo "Building x86-64-v3 binary (AVX2)"
	$(ECHO) nim c $(NFLAGS_AVX2) $(MAIN)

sse2:
	@echo "Building x86-64 binary (SSE2)"
	$(ECHO) nim c $(NFLAGS_SSE2) $(MAIN)

ssse3:
	@echo "Building x86-64 binary (SSSE3)"
	$(ECHO) nim c $(NFLAGS_SSSE3) $(MAIN)

sse41:
	@echo "Building x86-64 binary (SSE4.1)"
	$(ECHO) nim c $(NFLAGS_SSE41) $(MAIN)

neon:
	@echo "Building AArch64 binary (NEON)"
	$(ECHO) nim c $(NFLAGS_NEON) $(MAIN)

# Native macOS convenience targets retain the portable feature-set backends.
.PHONY: macos-amd64 macos-arm64
macos-amd64:
ifneq ($(OS_TAG)-$(ARCH_TAG),macos-amd64)
	$(error macos-amd64 requires an Intel macOS compiler; use the matching Mac host)
endif
	$(MAKE) sse2

macos-arm64:
ifneq ($(OS_TAG)-$(ARCH_TAG),macos-arm64)
	$(error macos-arm64 requires an Apple Silicon macOS compiler; use the matching Mac host)
endif
	$(MAKE) neon

scalar:
	@echo Building native scalar binary
	$(ECHO) nim c $(NFLAGS_SCALAR) $(MAIN)

deps:
	@echo Verifying dependencies
	$(ECHO) nimble install -d $(NIMBLE_FLAGS)

net:
	@echo Preparing neural network
	$(ECHO) $(SETENV)git submodule update --init --recursive
	$(ECHO) git -C networks lfs install --local
	$(ECHO) git -C networks lfs fetch --include="files/$(NET_NAME)" && git -C networks lfs checkout "files/$(NET_NAME)"


ARCH_DEFINES := $(shell echo | $(CC) $(NATIVE_ARCH_FLAGS) -E -dM -)
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

AVX2_SUPPORTED := 0
ifneq ($(findstring __AVX2__, $(ARCH_DEFINES)),)
  AVX2_SUPPORTED := 1
endif

SSE2_SUPPORTED := 0
ifneq ($(findstring __SSE2__, $(ARCH_DEFINES)),)
  SSE2_SUPPORTED := 1
endif
SSSE3_SUPPORTED := 0
ifneq ($(findstring __SSSE3__, $(ARCH_DEFINES)),)
  SSSE3_SUPPORTED := 1
endif
SSE41_SUPPORTED := 0
ifneq ($(findstring __SSE4_1__, $(ARCH_DEFINES)),)
  SSE41_SUPPORTED := 1
endif
NEON_SUPPORTED := 0
ifneq ($(findstring __aarch64__, $(ARCH_DEFINES)),)
  ifneq ($(findstring __ARM_NEON, $(ARCH_DEFINES)),)
    NEON_SUPPORTED := 1
  endif
endif

ifeq ($(ARCH_TAG),arm64)
RELEASE_BINARIES := bin/$(RELEASE_BASE)-neon$(EXE_EXT)
CI_RELEASE_BINARIES := $(RELEASE_BINARIES)
PRERELEASE_BINARIES := bin/$(PRERELEASE_BASE)-neon$(EXE_EXT)
else
BASE_RELEASE_BINARIES := bin/$(RELEASE_BASE)-sse2$(EXE_EXT) bin/$(RELEASE_BASE)-ssse3$(EXE_EXT) bin/$(RELEASE_BASE)-sse41$(EXE_EXT) bin/$(RELEASE_BASE)-avx2$(EXE_EXT)
RELEASE_BINARIES := $(BASE_RELEASE_BINARIES)
CI_RELEASE_BINARIES := $(BASE_RELEASE_BINARIES) bin/$(RELEASE_BASE)-avx512$(EXE_EXT) bin/$(RELEASE_BASE)-avx512-vnni$(EXE_EXT)
PRERELEASE_BINARIES := bin/$(PRERELEASE_BASE)-sse2$(EXE_EXT) bin/$(PRERELEASE_BASE)-ssse3$(EXE_EXT) bin/$(PRERELEASE_BASE)-sse41$(EXE_EXT) bin/$(PRERELEASE_BASE)-avx2$(EXE_EXT) bin/$(PRERELEASE_BASE)-avx512$(EXE_EXT) bin/$(PRERELEASE_BASE)-avx512-vnni$(EXE_EXT)

ifeq ($(AVX512_SUPPORTED),1)
RELEASE_BINARIES += bin/$(RELEASE_BASE)-avx512$(EXE_EXT)
endif

ifeq ($(VNNI_SUPPORTED),1)
RELEASE_BINARIES += bin/$(RELEASE_BASE)-avx512-vnni$(EXE_EXT)
endif
endif


ifeq ($(VNNI_SUPPORTED),1)
AUTO_SIMD := avx512-vnni
else ifeq ($(AVX512_SUPPORTED),1)
AUTO_SIMD := avx512
else ifeq ($(AVX2_SUPPORTED),1)
AUTO_SIMD := avx2
else ifeq ($(SSE41_SUPPORTED),1)
AUTO_SIMD := sse41
else ifeq ($(SSSE3_SUPPORTED),1)
AUTO_SIMD := ssse3
else ifeq ($(SSE2_SUPPORTED),1)
AUTO_SIMD := sse2
else ifeq ($(NEON_SUPPORTED),1)
AUTO_SIMD := neon
else
AUTO_SIMD := scalar
endif

SELECTED_SIMD := $(if $(filter auto,$(SIMD)),$(AUTO_SIMD),$(SIMD))
BACKEND_FLAGS_avx512-vnni = $(NFLAGS_AVX512_VNNI)
BACKEND_FLAGS_avx512 = $(NFLAGS_AVX512)
BACKEND_FLAGS_avx2 = $(if $(filter auto,$(SIMD)),$(NFLAGS_NATIVE),$(NFLAGS_AVX2))
BACKEND_FLAGS_ssse3 = $(NFLAGS_SSSE3)
BACKEND_FLAGS_sse41 = $(NFLAGS_SSE41)
BACKEND_FLAGS_sse2 = $(NFLAGS_SSE2)
BACKEND_FLAGS_neon = $(NFLAGS_NEON)
BACKEND_FLAGS_scalar = $(NFLAGS_SCALAR)
ifeq ($(filter $(SELECTED_SIMD),avx512-vnni avx512 avx2 sse2 ssse3 sse41 neon scalar),)
$(error Unknown SIMD backend '$(SIMD)': use auto, scalar, sse2, ssse3, sse41, avx2, avx512, avx512-vnni, or neon)
endif

define NATIVE_BUILD_CMD
	@echo "Building native target ($(SELECTED_SIMD))"
	$(ECHO) nim c $(BACKEND_FLAGS_$(SELECTED_SIMD)) $(MAIN)
	@echo Native target built
endef

native:
	$(NATIVE_BUILD_CMD)

dev:
ifeq ($(PGO),1)
	$(MAKE) -s pgo SKIP_DEPS=1
else
	$(MAKE) -s native SKIP_DEPS=1
endif

.PHONY: pgo
pgo:
ifneq ($(abspath $(MAIN)),$(abspath $(SRCDIR)/heimdall.nim))
	$(error PGO training requires the engine MAIN, not a standalone test)
endif
	@echo Building optional profile-guided native target
	@$(PGO_PREPARE_DIR)
	$(MAKE) -s dev PGO=0 EXE_BASE="$(PGO_TRAIN_EXE_BASE)" EXE="$(PGO_TRAIN_EXE)" CFLAGS="$(CFLAGS) -fprofile-instr-generate" LFLAGS="$(LFLAGS) -fprofile-instr-generate"
	$(PGO_NODE_ENV) $(PYTHON) scripts/uci_workload.py "$(PGO_TRAIN_EXE)" --positions "$(PGO_POSITIONS)" $(PGO_TRAIN_ARGS) --limit-kind nodes --limit $(PGO_TRAIN_NODES)
	$(PGO_TIME_ENV) $(PYTHON) scripts/uci_workload.py "$(PGO_TRAIN_EXE)" --positions "$(PGO_POSITIONS)" $(PGO_TRAIN_ARGS) --limit-kind time --limit $(PGO_TRAIN_MSEC)
	$(LLVM_PROFDATA) merge "$(PGO_RAW_NODES)" "$(PGO_RAW_TIME)" -output="$(PGO_DATA)"
	$(MAKE) -s dev PGO=0 EXE_BASE="$(EXE_BASE)" EXE="$(EXE)" CFLAGS="$(CFLAGS) -fprofile-instr-use=$(PGO_DATA)" LFLAGS="$(LFLAGS) -fprofile-instr-use=$(PGO_DATA)"
	@echo Profile-guided native target built

.PHONY: dev native sse2 ssse3 sse41 avx2 avx512 avx512-vnni neon scalar test-simd
SIMD_TEST_RUNNER ?=
test-simd:
	$(PYTHON) scripts/test_simd.py --backend "$(SELECTED_SIMD)" --runner "$(SIMD_TEST_RUNNER)"

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

check-release-benches:
	@echo Checking built binary benches
	$(ECHO) python scripts/check_binary_benches.py --commit "$(BENCH_COMMIT)" --depth "$(BENCH_DEPTH)" -- $(BENCH_BINARIES)


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
	$(MAKE) -s avx512-vnni SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx512-vnni
	@echo Finished AVX-512 VNNI build
endef
else
VNNI_RELEASES_CMD =
endif

releases: deps net
	@echo Building platform targets
ifeq ($(ARCH_TAG),arm64)
	$(MAKE) -s neon SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-neon
else
	$(MAKE) -s sse2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-sse2
	@echo Finished SSE2 build
	$(MAKE) -s ssse3 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-ssse3
	@echo Finished SSSE3 build
	$(MAKE) -s sse41 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-sse41
	@echo Finished SSE4.1 build
	$(MAKE) -s avx2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx2
	@echo Finished AVX2 build
	$(AVX512_RELEASES_CMD)
	$(VNNI_RELEASES_CMD)
endif
	$(MAKE) -s check-release-benches SKIP_DEPS=1 BENCH_BINARIES="$(RELEASE_BINARIES)"
	@echo All platform targets built and checked

ci-releases: deps net
	@echo Building CI release platform targets
ifeq ($(ARCH_TAG),arm64)
	$(MAKE) -s neon SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-neon
else
	$(MAKE) -s sse2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-sse2
	@echo Finished SSE2 build
	$(MAKE) -s ssse3 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-ssse3
	@echo Finished SSSE3 build
	$(MAKE) -s sse41 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-sse41
	@echo Finished SSE4.1 build
	$(MAKE) -s avx2 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx2
	@echo Finished AVX2 build
	$(MAKE) -s avx512 SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx512
	@echo Finished AVX-512 build
	$(MAKE) -s avx512-vnni SKIP_DEPS=1 IS_RELEASE=1 EXE_BASE=bin/$(RELEASE_BASE)-avx512-vnni
	@echo Finished AVX-512 VNNI build
endif
	$(MAKE) -s check-release-benches SKIP_DEPS=1 BENCH_BINARIES="$(CI_RELEASE_BINARIES)"
	@echo All CI release platform targets built and checked

prereleases: deps net
	@echo Building prerelease platform targets
ifeq ($(ARCH_TAG),arm64)
	$(MAKE) -s neon SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-neon
else
	$(MAKE) -s sse2 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-sse2
	@echo Finished SSE2 build
	$(MAKE) -s ssse3 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-ssse3
	@echo Finished SSSE3 build
	$(MAKE) -s sse41 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-sse41
	@echo Finished SSE4.1 build
	$(MAKE) -s avx2 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-avx2
	@echo Finished AVX2 build
	$(MAKE) -s avx512 SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-avx512
	@echo Finished AVX-512 build
	$(MAKE) -s avx512-vnni SKIP_DEPS=1 EXE_BASE=bin/$(PRERELEASE_BASE)-avx512-vnni
	@echo Finished AVX-512 VNNI build
endif
	$(MAKE) -s check-release-benches SKIP_DEPS=1 BENCH_BINARIES="$(PRERELEASE_BINARIES)"
	@echo All prerelease platform targets built and checked

openbench: deps
	$(NATIVE_BUILD_CMD)
