#!/bin/sh
# diff_compiler_rejection_parity.sh — the REJECTION-PARITY gate (issue #709).
#
# The inverse of diff_compiler_engines.sh. That gate asserts the three engines AGREE
# on a VALUE. A chunk of its old corpus could never do that: prelude-free fixtures that
# REDEFINE a core name (a prelude type or interface). Under the prelude-free llvm_emit
# PROBE gates they emit cleanly (the probe prepends no stdlib/core.mdk); under the
# SHIPPING `medaka build` — which prepends core.mdk — they COLLIDE, and BOTH shipping
# backends (native LLVM and WasmGC) reject them at the front end, identically. In the
# value differential they made ZERO cross-engine comparison (no two arms both `ran`),
# inflating the corpus + ledger while asserting nothing about engine agreement.
#
# So they were moved here (test/rejection_parity_fixtures.txt) to assert the property
# they ACTUALLY carry — identical rejection — WITHOUT pretending to be a value
# comparison. This is a REORGANIZATION: identical-rejection IS real cross-backend
# coverage; it just is not a differential.
#
# ── What this gate asserts, per fixture ───────────────────────────────────────────
#   * native  `medaka build`               MUST FAIL (front end rejects the collision)
#   * wasm    `medaka build --target wasm`  MUST FAIL   (only when the wasm arm is up)
# Both reject → PASS. If EITHER produces a program → HARD FAIL, naming the fixture:
# its rejection was fixed (or the front end changed), so it must be RE-HOMED — promoted
# back into the engines value differential and deleted from the manifest.
#
# ── SELF-DRAINING (the anti-pattern this whole suite exists to prevent) ────────────
#   * a fixture that starts COMPILING          → FAIL ("re-home it")     — never silent
#   * `checked 0` (empty/all-skipped manifest)  → FAIL                    — never green-on-nothing
#   * a manifest key with no fixture file       → FAIL                    — manifest rot
# There is NO golden here (a prelude-collision error message is not pinned — it would be
# a prelude-capturing golden, the exact hazard #709 removes). The assertion is purely
# "does the shipping compiler produce a program?", which moves only on a real front-end
# change, so it cannot rot on an inert prelude edit.
#
# Exit: 0 every fixture rejected on every available backend
#       1 a fixture compiled (re-home it), the manifest is empty, or a key has no file
#       2 genuine toolchain absence (no clang) — a legitimate skip for run_gates.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
WASMBIN="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"
MANIFEST="$ROOT/test/rejection_parity_fixtures.txt"
TIMEOUT="${TIMEOUT:-60}"

run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # portable timeout (no coreutils on mac)

# key → fixture path.  Mirror of diff_compiler_engines.sh's keyfor() inverse; only the
# two prelude-free emitter corpora hold rejection-parity fixtures, but wasm/ + wasmT/ are
# supported so the manifest can grow without touching this gate.
pathfor() {
  case "$1" in
    llvm/*)  echo "$ROOT/test/llvm_fixtures/${1#llvm/}.mdk" ;;
    llvmT/*) echo "$ROOT/test/llvm_fixtures_typed/${1#llvmT/}.mdk" ;;
    wasm/*)  echo "$ROOT/test/wasm/fixtures/${1#wasm/}.mdk" ;;
    wasmT/*) echo "$ROOT/test/wasm/fixtures_typed/${1#wasmT/}.mdk" ;;
    *)       echo "" ;;
  esac
}

# ── Preflight ─────────────────────────────────────────────────────────────────
# No C compiler → a legitimate skip (the assertion needs clang so that a now-VALID
# fixture actually LINKS a program; without it, a fixed fixture would fail at link and
# read as "still rejects" — a false pass that breaks the self-drain). Message worded to
# MATCH run_gates.sh's LEGIT_SKIP_RE.
command -v clang >/dev/null 2>&1 || { echo "no C compiler (clang) on PATH — skipping the rejection-parity gate"; exit 2; }

# A missing compiler is NOT a legitimate skip: message deliberately does NOT match
# LEGIT_SKIP_RE, so run_gates.sh reclassifies exit 2 as FAIL* (phantom skip).
[ -x "$MEDAKA" ] || { echo "the native compiler was never built (missing $MEDAKA) — run: make medaka"; exit 2; }
[ -f "$MANIFEST" ] || { echo "manifest missing: $MANIFEST"; exit 1; }

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

# ── wasm arm (degrades on a dev box, MANDATORY under MEDAKA_REQUIRE_WASM) ──────────
# Same contract as diff_compiler_engines.sh: with no wasm-tools / Node 24 / oracle we
# still assert the NATIVE rejection (the load-bearing half — native:prelude-collision is
# a front-end rejection both backends share). CI's engines shard sets
# MEDAKA_REQUIRE_WASM=1 (it provisions the toolchain), turning an unavailable wasm arm
# into a HARD FAIL so the wasm-rejection coverage can never silently rot away.
WASM_OK=1; WASM_OFF_WHY=""
NODE="${NODE:-node}"
if ! [ -x "$WASMBIN" ]; then
  WASM_OK=0; WASM_OFF_WHY="test/bin/wasm_emit_modules_main not built (sh test/wasm/build_wasm_oracle.sh --modules-only)"
elif ! command -v wasm-tools >/dev/null 2>&1; then
  WASM_OK=0; WASM_OFF_WHY="wasm-tools not on PATH"
else
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "$major" -lt 24 ]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
    major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  fi
  [ "$major" -lt 24 ] && { WASM_OK=0; WASM_OFF_WHY="Node >= 24 required (have $($NODE --version 2>/dev/null))"; }
fi

if [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ] && [ "$WASM_OK" != 1 ]; then
  echo "MEDAKA_REQUIRE_WASM=1 but the wasm arm is unavailable: $WASM_OFF_WHY" >&2
  echo "  the engines shard guarantees wasm-tools + Node 24 + test/bin/wasm_emit_modules_main;" >&2
  echo "  if this fired in CI the toolchain wiring regressed — see .github/workflows/ci.yml (engines shard)." >&2
  exit 1
fi
[ "$WASM_OK" = 1 ] && export MEDAKA_WASM_EMITTER="$WASMBIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Per-fixture: assert both backends reject ──────────────────────────────────────
checked=0; badnative=0; badwasm=0; missing=0; wasm_skipped=0
: >"$WORK/fail.txt"

while IFS= read -r line; do
  key="$(printf '%s\n' "$line" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$key" ] || continue
  case "$key" in \#*) continue ;; esac

  f="$(pathfor "$key")"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    missing=$((missing+1))
    printf 'MISSING  %s\n  no fixture file for this manifest key (got: %s)\n\n' "$key" "${f:-<unmapped prefix>}" >> "$WORK/fail.txt"
    continue
  fi

  checked=$((checked+1))

  # native: MUST reject (no program produced)
  if run_t "$TIMEOUT" "$MEDAKA" build --allow-internal "$f" -o "$WORK/out.bin" >"$WORK/native.err" 2>&1; then
    badnative=$((badnative+1))
    printf 'COMPILED (native)  %s\n  %s\n  → `medaka build` now PRODUCES A PROGRAM — the rejection was fixed.\n  → RE-HOME it: promote back into the engines value differential (add its\n    observed signature to test/engine_divergence.txt) and delete its line from\n    test/rejection_parity_fixtures.txt.\n\n' "$key" "$f" >> "$WORK/fail.txt"
    rm -f "$WORK/out.bin"
  fi

  # wasm: MUST reject too, when the arm is available
  if [ "$WASM_OK" = 1 ]; then
    if run_t "$TIMEOUT" "$MEDAKA" build --target wasm --allow-internal "$f" -o "$WORK/out.wasm" >"$WORK/wasm.err" 2>&1; then
      badwasm=$((badwasm+1))
      printf 'COMPILED (wasm)  %s\n  %s\n  → `medaka build --target wasm` now PRODUCES A MODULE — the rejection was fixed.\n  → RE-HOME it (see the native note above).\n\n' "$key" "$f" >> "$WORK/fail.txt"
      rm -f "$WORK/out.wasm"
    fi
  else
    wasm_skipped=$((wasm_skipped+1))
  fi
done < "$MANIFEST"

echo
echo "══════════════════════════════════════════════════════════════════════"
echo " REJECTION PARITY — both shipping backends reject each fixture identically"
echo "══════════════════════════════════════════════════════════════════════"
printf ' checked                %4d   test/rejection_parity_fixtures.txt\n' "$checked"
if [ "$WASM_OK" = 1 ]; then
  printf ' backends asserted           native + wasm\n'
else
  printf ' backends asserted           native only — wasm arm off: %s\n' "$WASM_OFF_WHY"
fi
printf ' COMPILED on native     %4d   (should be 0 — these must reject)\n' "$badnative"
printf ' COMPILED on wasm       %4d   (should be 0 — these must reject)\n' "$badwasm"
printf ' MISSING fixture file   %4d   (should be 0 — manifest rot)\n' "$missing"
echo "══════════════════════════════════════════════════════════════════════"

# Never report success having checked nothing (the #597 / TESTING-DESIGN §2.3 lie).
if [ "$checked" -eq 0 ]; then
  echo "ZERO-CHECK: the manifest yielded no runnable fixture — the gate asserted nothing" >&2
  exit 1
fi

if [ "$((badnative + badwasm + missing))" -gt 0 ]; then
  echo
  cat "$WORK/fail.txt"
  echo "A rejection-parity fixture stopped rejecting (or a manifest key has no file)."
  echo "That is a GOOD failure — a bug got fixed or the manifest rotted — and a HARD FAIL:"
  echo "re-home the fixture (or fix the manifest), or the coverage silently rots back later."
  exit 1
fi

echo "OK — all $checked fixtures rejected on every available backend."
exit 0
