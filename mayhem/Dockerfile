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
# Pre-clone abseil-cpp at the pinned tag into /opt/abseil-cpp-cache so build.sh re-runs air-gapped:
# build.sh copies from the cache into third_party/abseil-cpp and sets FETCHCONTENT_FULLY_DISCONNECTED=ON.
USER root
RUN if ! command -v cmake >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
      || ! command -v python3 >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then \
      [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true; \
      apt-get update && apt-get install -yq --no-install-recommends \
        cmake make pkg-config build-essential git python3 zip ca-certificates \
      && rm -rf /var/lib/apt/lists/*; \
    fi \
    && git clone --depth 1 --branch 20260526.0 \
         https://github.com/abseil/abseil-cpp.git /opt/abseil-cpp-cache \
    && chmod -R a+rX /opt/abseil-cpp-cache
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
