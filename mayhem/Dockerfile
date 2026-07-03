# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). The base provides debian + clang/llvm + libFuzzer + the build-contract
# ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC); this only adds the per-commit sentencepiece build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t sentencepiece-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default so an unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# sentencepiece builds with CMake and embeds a generated model via python3; ctest drives its suite.
# Install the toolchain bits as root if the base doesn't ship them, then drop back to the non-root user.
#
# abseil-cpp (CMakeLists.txt FetchContent_Declare(abseil-cpp GIT_TAG 20260817.0)), protobuf
# (GIT_TAG v36.1), and googletest (GIT_TAG v1.18.0, pulled in only when SPM_BUILD_TEST=ON --
# i.e. only build.sh's test-suite cmake invocation) are all fetched via plain
# FetchContent_MakeAvailable. build.sh points CMake's FETCHCONTENT_SOURCE_DIR_<NAME> at these
# pre-clones, so FetchContent treats each as already populated and does no git operations at all --
# air-gapped and idempotent on re-run. --recurse-submodules is required for protobuf (vendors
# third_party/utf8_range as a submodule) -- CMake does ZERO git work on a SOURCE_DIR override, so an
# incomplete submodule would silently break the build the same way a missing clone would.
USER root
RUN if ! command -v cmake >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
      || ! command -v python3 >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then \
      [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true; \
      apt-get update && apt-get install -yq --no-install-recommends \
        cmake make pkg-config build-essential git python3 zip ca-certificates \
      && rm -rf /var/lib/apt/lists/*; \
    fi \
    && git clone --depth 1 --branch 20260817.0 \
         https://github.com/abseil/abseil-cpp.git /opt/abseil-cpp-cache \
    && chmod -R a+rX /opt/abseil-cpp-cache \
    && git clone --depth 1 --branch v36.1 --recurse-submodules --shallow-submodules \
         https://github.com/protocolbuffers/protobuf.git /opt/protobuf-cache \
    && chmod -R a+rX /opt/protobuf-cache \
    && git clone --depth 1 --branch v1.18.0 \
         https://github.com/google/googletest.git /opt/googletest-cache \
    && chmod -R a+rX /opt/googletest-cache
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem; build.sh builds in place. SRC must point at the build tree.
ENV SRC=/mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run sentencepiece's own ctest suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
