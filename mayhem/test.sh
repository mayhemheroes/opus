#!/usr/bin/env bash
#
# opus/mayhem/test.sh — behavioral oracle for the opus decoder.
#
# Runs two of opus's native unit tests (test_opus_api, test_opus_decode) built in an INDEPENDENT,
# non-sanitized scratch tree (separate from build.sh's sanitized fuzz build so the two don't collide).
# Each test program is run directly with stdout captured; we grep for SPECIFIC output strings that
# the programs emit ONLY when the real decode/encode logic executes.  A no-op / exit(0) patch (the
# §6.3 anti-reward-hacking sabotage) yields empty stdout and FAILS the grep.
#
# Emits a CTRF (ctrf.io) summary line. exit 0 iff every test passed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"

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
}

# Independent, NON-sanitized build of libopus + the native unit tests. opus's autotools does NOT
# support an out-of-tree VPATH build from a source dir that build.sh already configured in place,
# so we COPY the source tree to a scratch dir (sans .git / build.sh artifacts) and build in-tree.
# That keeps build.sh's sanitized $SRC artifacts untouched.
BUILD="$SRC/mayhem-build-test"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# Copy sources excluding VCS + the scratch build dir itself. Preserve modes so autogen.sh/configure
# stay executable (a mode-stripping copy makes ./autogen.sh fail with "Permission denied").
( cd "$SRC" && cp -a \
    $(ls -A | grep -vE '^(\.git|mayhem-build-test)$') "$BUILD/" )

# TEST_OPUS_NOFUZZ trims the long randomized sweeps so the suite runs quickly and deterministically
# while still exercising the full encode/decode/api paths. A fixed SEED keeps runs reproducible.
export TEST_OPUS_NOFUZZ=1
export SEED=1

# Configure + build the test programs.
# NB: --enable-extra-programs is needed so the automake noinst_PROGRAMS (test_opus_api,
# test_opus_decode, …) are actually built — otherwise `make` skips them.
if ! ( cd "$BUILD"
       make distclean >/dev/null 2>&1 || true
       ./autogen.sh >/dev/null 2>&1
       ./configure --enable-static --disable-shared --disable-doc --enable-extra-programs \
                   --enable-assertions >/dev/null 2>&1
       make -j"$MAYHEM_JOBS" >/dev/null 2>&1 ); then
  echo "FAIL: could not build opus native test suite" >&2
  emit_ctrf "opus-native-suite" 0 1 0
  exit 1
fi

# Run each test program DIRECTLY and capture its stdout + stderr into a per-test log.
# We then grep for SPECIFIC strings that the program emits only when the real decode/encode
# logic runs.  An exit(0)-no-op produces empty output → grep fails → FAIL.
#
# Test roster and their behavioral "fingerprint" strings:
declare -A EXPECT=(
  [tests/test_opus_api]="opus_decoder_create.*OK"
  [tests/test_opus_decode]="opus_decode.*OK"
)

passed=0; failed=0

for test_bin in "${!EXPECT[@]}"; do
  pat="${EXPECT[$test_bin]}"
  bin="$BUILD/$test_bin"
  if [ ! -f "$bin" ]; then
    echo "FAIL: $test_bin was not built" >&2
    (( failed++ )) || true
    continue
  fi

  out="$BUILD/${test_bin//\//_}.out"
  set +e
  "$bin" > "$out" 2>&1
  rc=$?
  set -e 2>/dev/null || true

  # Behavioral check: grep for the expected fingerprint string in stdout.
  # This is what makes the oracle non-reward-hackable: a neutered binary exits 0 silently,
  # so the grep finds nothing and we FAIL.
  if grep -qE "$pat" "$out"; then
    echo "PASS: $test_bin (rc=$rc, output contains '$pat')"
    (( passed++ )) || true
  else
    echo "FAIL: $test_bin — output does not contain '$pat' (rc=$rc)" >&2
    echo "  --- last 10 lines of output ---" >&2
    tail -10 "$out" >&2
    (( failed++ )) || true
  fi
done

emit_ctrf "opus-native-suite" "$passed" "$failed" 0
[ "$failed" -eq 0 ]
