#!/usr/bin/env bash
#
# sentencepiece/mayhem/test.sh — RUN sentencepiece's own test suite (built by mayhem/build.sh with
# normal flags in mayhem-tests/) via ctest, PLUS a behavioral oracle that tokenizes a known sentence
# with a real model and greps for known token IDs. exit 0 iff no test failed.
#
# PATCH-grade oracle (§6.3 — anti-reward-hacking):
#   1. ctest runs the pre-built spm_test binary (sentencepiece's known-answer test suite).
#   2. The behavioral oracle uses spm_encode to tokenize "Hello world" with the bundled BPE model
#      and grepping for a known non-empty token piece. Both checks must pass.
#
#   A no-op / exit(0) PATCH FAILS this test because:
#     - When spm_encode is neutered (LD_PRELOAD exit(0)), it emits NO output → grep fails → FAIL.
#     - The ctest run of spm_test may pass (neutered binary exits 0 — ctest counts that as pass),
#       but the behavioral oracle catches the neuter: empty output ≠ the expected token string.
#   This script only RUNS pre-built binaries; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"
TOOL_BIN="$SRC/mayhem-build/root/bin/spm_encode"
MODEL="$SRC/data/botchan_1000_bpe.model"
# spm_encode links dynamically against sentencepiece .so files in mayhem-build/root/lib/
# (note: we only set LD_LIBRARY_PATH for the spm_encode invocation, not for ctest / spm_test,
# so the clean test-suite binary doesn't inadvertently load the sanitized .so)
SPM_LIB_DIR="$SRC/mayhem-build/root/lib"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TOTAL_PASSED=0
TOTAL_FAILED=0

# ── 1) ctest suite ───────────────────────────────────────────────────────────────────────────────
if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "sentencepiece" 0 1 0; exit 2
fi
if ! command -v ctest >/dev/null 2>&1; then
  echo "ctest not available — cannot run the test suite" >&2
  emit_ctrf "sentencepiece" 0 1 0; exit 2
fi

echo "=== running ctest in $BUILDDIR ==="
out="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
        ctest --test-dir "$BUILDDIR" --output-on-failure -j"$(nproc)" 2>&1)"; rc=$?
echo "$out"

# ctest prints:  "NN% tests passed, F tests failed out of T"
CTEST_PASSED=$(printf '%s\n' "$out" | sed -n 's/.*tests passed,[[:space:]]*\([0-9][0-9]*\)[[:space:]]*tests failed out of[[:space:]]*\([0-9][0-9]*\).*/\2 \1/p' | tail -1 | awk '{print $1-$2}')
CTEST_FAILED=$(printf '%s\n' "$out" | sed -n 's/.*tests passed,[[:space:]]*\([0-9][0-9]*\)[[:space:]]*tests failed out of.*/\1/p' | tail -1)

if [ -z "${CTEST_PASSED:-}" ] || [ -z "${CTEST_FAILED:-}" ]; then
  echo "could not parse ctest summary; using ctest exit code $rc" >&2
  if [ "$rc" -eq 0 ]; then CTEST_PASSED=1; CTEST_FAILED=0
  else CTEST_PASSED=0; CTEST_FAILED=1; fi
fi

TOTAL_PASSED=$(( TOTAL_PASSED + CTEST_PASSED ))
TOTAL_FAILED=$(( TOTAL_FAILED + CTEST_FAILED ))

# ── 2) Behavioral oracle — tokenize a known sentence, assert non-empty output ────────────────────
# spm_encode (built as part of the sentencepiece install target) tokenizes an English sentence with
# the bundled BPE model. When the binary runs normally: prints token pieces (e.g. "▁Hello ▁world").
# When neutered with LD_PRELOAD exit(0): emits nothing → the empty-output check fails.
echo ""
echo "=== behavioral oracle: tokenize 'Hello world' with BPE model ==="
if [ ! -x "$TOOL_BIN" ]; then
  echo "FAIL: spm_encode not found at $TOOL_BIN — build.sh must be run first" >&2
  TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
elif [ ! -f "$MODEL" ]; then
  echo "FAIL: test model not found at $MODEL" >&2
  TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
else
  # Run spm_encode: on success emits tab-separated token pieces on stdout.
  # --output_format=piece prints the subword pieces (e.g. "▁Hello▁world").
  # LD_LIBRARY_PATH scoped to this call so spm_test (clean build) doesn't pick up the sanitized .so.
  enc_out="$(LD_LIBRARY_PATH="$SPM_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$TOOL_BIN" --model="$MODEL" --output_format=piece <<< "Hello world" 2>/dev/null || true)"
  echo "spm_encode output: '$enc_out'"
  # The output must be non-empty (neutered binary emits nothing).
  # It must contain at least one ▁ (LOWER ONE EIGHTH BLOCK / U+2581) — the BPE word-start marker.
  # Any real tokenization of "Hello world" with a BPE model will contain this character.
  if [ -z "$enc_out" ]; then
    echo "FAIL: spm_encode produced no output — binary may be neutered or broken" >&2
    TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
  elif ! printf '%s' "$enc_out" | grep -qF $'\xe2\x96\x81'; then
    # ▁ is U+2581, encoded as \xe2\x96\x81 in UTF-8 — the BPE word-prefix marker
    echo "FAIL: output missing expected BPE word-prefix marker (▁) — tokenizer not working correctly" >&2
    echo "  got: $enc_out" >&2
    TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
  else
    echo "PASS: behavioral oracle: output='$enc_out' (contains ▁ word-prefix marker)"
    TOTAL_PASSED=$(( TOTAL_PASSED + 1 ))
  fi
fi

emit_ctrf "sentencepiece" "$TOTAL_PASSED" "$TOTAL_FAILED" 0
