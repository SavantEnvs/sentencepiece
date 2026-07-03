#!/usr/bin/env bash
#
# sentencepiece/mayhem/build.sh — build google/sentencepiece's OSS-Fuzz harnesses as sanitized
# libFuzzer targets (+ standalone reproducers), AND sentencepiece's own ctest suite for test.sh.
#
# Fuzzed surface (all C++; the library is compiled WITH $SANITIZER_FLAGS so the tokenizer /
# protobuf model loader / normalizer / trainer code — not just the harness — is instrumented):
#   model_load_fuzzer      — feeds arbitrary bytes as a serialized ModelProto to
#                            SentencePieceProcessor::LoadFromSerializedProto, then (if it loads)
#                            exercises Encode/Decode/Normalize/NBest/Sample/vocab lookups.
#   processor_text_fuzzer  — loads a VALID model embedded in the binary (embedded_model.h, generated
#                            at build time by the helper `generate_model`) and fuzzes the text
#                            encode/decode/normalize/sample/entropy paths with arbitrary input.
#   sample_encode_fuzzer   — drives SampleEncodeAsSerializedProto on an unloaded processor (error
#                            paths + arg parsing of nbest_size/alpha from the input).
#   trainer_fuzzer         — drives SentencePieceTrainer::Train over fuzz-derived training sentences
#                            and trainer flags (unigram/bpe/word/char), in-memory (no disk model).
#   generate_model         — build-time helper (also shipped as an OSS-Fuzz artifact) that generates
#                            minimal serialized ModelProto files for seed use.
#
# Build contract comes from the org base ENV: CC/CXX/CXXFLAGS/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/
# SRC/$OUT. $OUT is forced to /mayhem (the contract).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${CXXFLAGS:=}"
# Cap parallelism: unicode_script.cc (large embedded Unicode tables) is memory-heavy to compile
# under ASan+UBSan instrumentation, and enough of these running concurrently OOMs under the
# fleet's fixed 8G container memory cap (§6.2 memory budget) when MAYHEM_JOBS defaults to nproc
# on a many-core host. 4 keeps per-job memory headroom regardless of host core count.
: "${MAYHEM_JOBS:=$(($(nproc) < 4 ? $(nproc) : 4))}"
# DEBUG_FLAGS: DWARF ≤ 3 so Mayhem's triage can read symbols (clang-19 defaults to DWARF-5 with plain -g).
# Comes AFTER $SANITIZER_FLAGS so it wins over any -g already present there.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
OUT=/mayhem
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE CXXFLAGS MAYHEM_JOBS OUT

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# Combine the org sanitizer flags into CXXFLAGS for every compile below. -fsanitize=fuzzer-no-link
# gives the library coverage instrumentation without pulling the libFuzzer main (added at link time
# only for the libFuzzer targets via $LIB_FUZZING_ENGINE).
# DEBUG_FLAGS comes AFTER SANITIZER_FLAGS so -gdwarf-3 overrides any -g from the sanitizer set.
SAN="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
export CXXFLAGS="$CXXFLAGS $SAN $DEBUG_FLAGS"

# ── 1) Build the sentencepiece libraries WITH sanitizers (instrumented tokenizer) ─────────────────
# SPM_ENABLE_SHARED=ON + install gives ./root/lib/libsentencepiece*.a static archives (the shared .so
# is unused by the fuzzers). abseil-cpp (CMakeLists.txt FetchContent_Declare(abseil-cpp ... GIT_TAG
# 20260817.0)) and protobuf (GIT_TAG v36.1) are both fetched via plain FetchContent_MakeAvailable;
# -DFETCHCONTENT_SOURCE_DIR_<NAME> points each at its Dockerfile-baked pre-clone (/opt/abseil-cpp-cache,
# /opt/protobuf-cache) so CMake treats it as already populated and does no git operations at all --
# air-gapped and idempotent on re-run without needing any subbuild-stamp caching.
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"

cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSPM_ENABLE_SHARED=ON \
    -DSPM_BUILD_TEST=OFF \
    -DCMAKE_INSTALL_PREFIX="$BUILD/root" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SAN $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SAN $DEBUG_FLAGS" \
    -DFETCHCONTENT_SOURCE_DIR_PROTOBUF=/opt/protobuf-cache \
    -DFETCHCONTENT_SOURCE_DIR_ABSEIL-CPP=/opt/abseil-cpp-cache
cmake --build "$BUILD" --config Release --target install --parallel "$MAYHEM_JOBS"

ABSL_LIBS=$(find "$BUILD" -path '*abseil-cpp*' -name '*.a' | sort -u)
# protobuf (CMakeLists.txt FetchContent_Declare(protobuf ... GIT_TAG v36.1), fetched from
# /opt/protobuf-cache via -DFETCHCONTENT_SOURCE_DIR_PROTOBUF above -- see mayhem/Dockerfile). Picks up
# libprotobuf/libprotobuf-lite/libupb plus the vendored utf8_range/utf8_validity under
# _deps/protobuf-build/third_party/utf8_range/.
PROTOBUF_LIBS=$(find "$BUILD" -path '*protobuf-build*' -name '*.a' | sort -u)

SPM_LIBS="$BUILD/root/lib/libsentencepiece_train.a $BUILD/root/lib/libsentencepiece.a"
# Include paths:
#   -I$SRC            — "third_party/absl/..." (sentencepiece_processor.h) → /mayhem/third_party/absl/...
#   -I$SRC/third_party — "absl/base/..." (absl headers) → /mayhem/third_party/absl/base/...
#   /opt/protobuf-cache/src — generated *.pb.h now #include real protobuf headers (e.g.
#     google/protobuf/runtime_version.h), not the old vendored third_party/protobuf-lite (removed
#     upstream when it switched to FetchContent'd real protobuf).
INCS="-I$SRC -I$SRC/third_party -I$SRC/src -I$SRC/src/builtin_pb -I/opt/protobuf-cache/src -I/opt/protobuf-cache/third_party/utf8_range -I$BUILD -I$BUILD/root/include"

# ── 2) Helper: generate a minimal embedded model + the model_load seed models ─────────────────────
# generate_model is a plain executable (NOT a fuzzer): sanitized compile, no libFuzzer engine.
$CXX $CXXFLAGS -std=c++17 $INCS \
    "$HARNESS_DIR/generate_model.cc" \
    -Wl,--start-group $SPM_LIBS $ABSL_LIBS $PROTOBUF_LIBS -Wl,--end-group \
    -lpthread \
    -o "$OUT/generate_model"

# Embedded model for processor_text_fuzzer (compiled into the binary as a byte array).
"$OUT/generate_model" /tmp/embedded_model.bin unigram
python3 -c "
data = open('/tmp/embedded_model.bin','rb').read()
with open('$BUILD/embedded_model.h','w') as f:
    f.write('// Auto-generated embedded model data\n#pragma once\n')
    f.write('static const unsigned char kEmbeddedModelData[] = {\n')
    for i in range(0,len(data),16):
        f.write('  '+', '.join('0x%02x'%b for b in data[i:i+16])+',\n')
    f.write('};\n')
    f.write('static const size_t kEmbeddedModelSize = %d;\n'%len(data))
print('embedded_model.h:', len(data),'bytes')
"

# ── 3) Standalone driver object (no libFuzzer runtime) ────────────────────────────────────────────
$CXX $CXXFLAGS -std=c++17 $DEBUG_FLAGS -c "$HARNESS_DIR/standalone_main.cc" -o "$BUILD/standalone_main.o"

# ── 4) Build each harness: libFuzzer target (-> /mayhem/<name>) + standalone reproducer ───────────
for harness in model_load_fuzzer processor_text_fuzzer sample_encode_fuzzer trainer_fuzzer; do
  echo "Building harness: $harness"

  # libFuzzer target
  $CXX $CXXFLAGS -std=c++17 $DEBUG_FLAGS $INCS \
      "$HARNESS_DIR/$harness.cc" $LIB_FUZZING_ENGINE \
      -Wl,--start-group $SPM_LIBS $ABSL_LIBS $PROTOBUF_LIBS -Wl,--end-group \
      -lpthread \
      -o "$OUT/$harness"

  # standalone reproducer (no libFuzzer runtime; uses standalone_main.o)
  $CXX $CXXFLAGS -std=c++17 $DEBUG_FLAGS $INCS \
      "$HARNESS_DIR/$harness.cc" "$BUILD/standalone_main.o" \
      -Wl,--start-group $SPM_LIBS $ABSL_LIBS $PROTOBUF_LIBS -Wl,--end-group \
      -lpthread \
      -o "$OUT/$harness-standalone"
done

# ── 4b) generate_model_fuzzer → shipped as /mayhem/generate_model (OSS-Fuzz parity name). ──────────
# The build-time generate_model helper (plain main) was written to $OUT/generate_model above and has
# already been used to generate the embedded model header (step 2).  Now we overwrite that helper with
# the real libFuzzer harness so the Mayhemfile target `/mayhem/generate_model` finds an instrumented
# fuzzer (not the unarmed helper).  The standalone reproducer is kept under generate_model-standalone.
echo "Building harness: generate_model_fuzzer -> generate_model (OSS-Fuzz parity)"
$CXX $CXXFLAGS -std=c++17 $DEBUG_FLAGS $INCS \
    "$HARNESS_DIR/generate_model_fuzzer.cc" $LIB_FUZZING_ENGINE \
    -Wl,--start-group $SPM_LIBS $ABSL_LIBS $PROTOBUF_LIBS -Wl,--end-group \
    -lpthread \
    -o "$OUT/generate_model"
$CXX $CXXFLAGS -std=c++17 $DEBUG_FLAGS $INCS \
    "$HARNESS_DIR/generate_model_fuzzer.cc" "$BUILD/standalone_main.o" \
    -Wl,--start-group $SPM_LIBS $ABSL_LIBS $PROTOBUF_LIBS -Wl,--end-group \
    -lpthread \
    -o "$OUT/generate_model-standalone"

# ── 5) Build sentencepiece's OWN ctest suite with NORMAL flags (clean tree) so test.sh only RUNS it.
#       SPM_BUILD_TEST=ON builds the self-contained `spm_test` (its own testharness, not gtest) wired
#       as the `sentencepiece_test` ctest. Normal flags keep test.sh an honest patch oracle. ────────
TESTBUILD="$SRC/mayhem-tests"
rm -rf "$TESTBUILD"; mkdir -p "$TESTBUILD"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$TESTBUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSPM_BUILD_TEST=ON \
    -DSPM_ENABLE_SHARED=OFF \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DFETCHCONTENT_SOURCE_DIR_PROTOBUF=/opt/protobuf-cache \
    -DFETCHCONTENT_SOURCE_DIR_ABSEIL-CPP=/opt/abseil-cpp-cache \
    -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/opt/googletest-cache
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$TESTBUILD" --target spm_test --parallel "$MAYHEM_JOBS"
echo "built sentencepiece ctest suite in mayhem-tests/"

echo "build.sh complete:"
ls -la "$OUT"/generate_model \
       "$OUT"/model_load_fuzzer "$OUT"/processor_text_fuzzer \
       "$OUT"/sample_encode_fuzzer "$OUT"/trainer_fuzzer \
       "$OUT"/generate_model-standalone \
       "$OUT"/model_load_fuzzer-standalone "$OUT"/processor_text_fuzzer-standalone \
       "$OUT"/sample_encode_fuzzer-standalone "$OUT"/trainer_fuzzer-standalone 2>&1 || true
