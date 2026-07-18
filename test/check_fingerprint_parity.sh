#!/bin/sh
# check_fingerprint_parity.sh — proves the source-staleness fingerprint mirror
# still agrees with itself (issue #267).
#
# WHY THIS GATE EXISTS. test/build_native_medaka.sh's src_fingerprint_compiler()
# hashes `find compiler -name '*.mdk' -print | LC_ALL=C sort` (names AND contents,
# via a `while read f; do printf ...; cat "$f"; done` shell loop) and bakes the
# result into ./medaka as -DMEDAKA_SRC_FP. compiler/driver/medaka_cli.mdk's
# `liveSourceFingerprint` REIMPLEMENTS that exact same algorithm (same find/sort,
# same hash_stream chain) in a one-shot perl one-liner for speed, and compares its
# live result against the baked value on every `./medaka` invocation
# (`checkSourceStaleness`; MEDAKA_STRICT=1 promotes a mismatch to a hard `exit 1`).
#
# These are TWO HAND-SYNCED IMPLEMENTATIONS of one hashing algorithm, in two
# different languages, in two different files, and NOTHING proved they still
# agree. #182's first attempt broke exactly this mirror (baked compiler+runtime
# while the live side stayed compiler-only) — every ./medaka invocation would
# have warned stale / hard-failed under MEDAKA_STRICT — and it was caught only by
# human review during PR #263, not by any gate. A future edit to either side
# (the shell loop in build_native_medaka.sh, or the perl one-liner in
# medaka_cli.mdk) can silently re-break the mirror the same way.
#
# THE INVARIANT THIS GATE ASSERTS (see the STOP-guardrail note below for why it
# is not a bare "the two hashes are always equal"): on the tree `./medaka` was
# JUST BUILT FROM, the compiler-only fingerprint baked into that binary
# (build_native_medaka.sh's src_fingerprint_compiler(), shell/cat-based) MUST
# equal the live compiler-only fingerprint medaka_cli.mdk's liveSourceFingerprint
# recomputes at runtime (perl-based) over that SAME tree. If the two
# implementations have drifted apart — different hashing, different file set,
# different newline handling, whatever — this is the one place that shows up:
# `MEDAKA_STRICT=1 ./medaka` on its own freshly-built, unmodified source tree
# must NOT warn stale and must NOT exit nonzero. It is deliberately silent about
# WHAT differs (that is a job for whoever edits either side); it only proves that
# TODAY, right now, the two agree.
#
# NOTE this is not "the fingerprint of an unchanged tree equals some fixed
# constant" — it is "the two INDEPENDENT implementations, run over the identical
# bytes, produce the identical hash." That is exactly the property #182 broke:
# both computations still ran fine on their own, they just stopped being the
# SAME computation. A raw comparison of the two, computed by two different tools
# over the same tree, is the only form of this check that actually tests parity
# rather than testing "did the tree change" (which every existing staleness path
# already tests, right down to the mtime-vs-fingerprint fix that fixed #89/#182).
#
# WHY THIS RUNS AS AN UNGUARDED STEP IN `soundness`, NOT A NEW GATE SHARD: it
# needs a freshly-built ./medaka on a tree matching that build (soundness already
# builds one via `make medaka`, cold, on every event) — a new shard would need
# its own ci.yml matrix entry and its own oracle plumbing for no reason, when
# soundness already has exactly the binary and tree state this needs. See
# AGENTS.md "a gate must run where the bug lands."
#
# ⚠️ TREATS A NON-COMPARISON AS FAILURE, NOT A PASS. A missing/non-executable
# ./medaka, a MEDAKA_ROOT that resolves to a tree with no compiler/ directory, or
# any inability to actually exercise checkSourceStaleness is a HARD FAIL here —
# never a silent skip. (checkSourceStaleness itself silently no-ops on a SHIPPED
# binary — no baked fingerprint, or no compiler/ beside it — by design, so that a
# distributed binary never warns about source it was never packaged with. That
# is the right behavior for a shipped binary; it is exactly the wrong behavior
# for a gate, so this script does not rely on the binary's own silence and checks
# every precondition itself before trusting its exit code.)
#
# Usage: sh test/check_fingerprint_parity.sh
# Exit:  0 the two fingerprint implementations agree (checked); 1 otherwise
#          (mismatch, or any precondition failed to hold).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/medaka"

if [ ! -x "$BIN" ]; then
  echo "FAIL: no executable $BIN — build it first (make medaka), then re-run this gate."
  echo "      (A missing binary is a FAILURE here, not a skip: this gate needs to actually"
  echo "       exercise the built binary's own staleness self-check.)"
  exit 1
fi

if [ ! -d "$ROOT/compiler" ]; then
  echo "FAIL: no $ROOT/compiler — cannot compare a live fingerprint against nothing."
  exit 1
fi

command -v perl >/dev/null 2>&1 || {
  echo "FAIL: no perl on PATH — liveSourceFingerprint silently no-ops without it, which"
  echo "      would make this gate pass by never actually comparing anything. Install perl."
  exit 1
}

# Exercise the binary's OWN staleness check (checkSourceStaleness / MEDAKA_STRICT=1),
# on the exact tree it was just built from. This is the parity assertion: the baked
# value came from build_native_medaka.sh's shell/cat-based src_fingerprint_compiler();
# the live value is recomputed right now by medaka_cli.mdk's perl-based
# liveSourceFingerprint. If the two implementations disagree, checkSourceStaleness
# prints the "may be stale" warning and MEDAKA_STRICT=1 turns that into exit 1.
OUT="$(cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$BIN" --version 2>&1)"
STATUS=$?

if [ "$STATUS" -ne 0 ] || printf '%s\n' "$OUT" | grep -q 'may be stale'; then
  echo "FAIL: fingerprint mirror MISMATCH — build_native_medaka.sh's baked"
  echo "      src_fingerprint_compiler() and medaka_cli.mdk's liveSourceFingerprint no"
  echo "      longer agree on the SAME tree. One of the two hand-synced implementations"
  echo "      drifted from the other (issue #267). ./medaka output was:"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
  exit 1
fi

echo "checked: build_native_medaka.sh's baked compiler-fingerprint == medaka_cli.mdk's"
echo "liveSourceFingerprint on $ROOT/compiler — PASS (mirror agrees)."
exit 0
