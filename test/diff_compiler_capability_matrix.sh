#!/bin/sh
# test/diff_compiler_capability_matrix.sh — capability-coverage gate.
#
# WHY THIS EXISTS (2026-07-13): stdlib/runtime.mdk declares ~134 `extern`
# primitives.  Each of the three execution engines (tree-walking interpreter
# `compiler/eval/eval.mdk`, LLVM backend `compiler/backend/llvm_emit.mdk`,
# WasmGC backend `compiler/backend/wasm_emit.mdk`) must independently
# implement whichever externs it dispatches.  Nothing checked that they
# agree.  The interpreter silently fell 37 externs behind (readFile,
# arraySortBy, exit, ...) after the OCaml reference compiler — the thing
# eval.mdk was originally written to VALUE-oracle against, not to run
# programs — was deleted and eval.mdk got silently promoted to be the
# `medaka run` production engine.  A program using a missing extern
# type-checks GREEN and panics at runtime with "unbound identifier: X".
# This gate is the missing detector.
#
# WHAT IT DOES
#   1. Parses the extern catalog from stdlib/runtime.mdk (`^extern NAME`).
#   2. Parses which externs each engine implements, straight from that
#      engine's own dispatch source (see "PARSING NOTES" below).
#   3. Cross-references against test/CAPABILITY-EXCEPTIONS.txt, the checked-in
#      source of truth for every KNOWN (extern, engine) gap.
#   4. FAILS on any drift in EITHER direction:
#        - an extern missing from an engine with NO exceptions entry
#          ("silent omission" — exactly how the 37-extern gap survived), or
#        - an extern the exceptions file calls unsupported that the engine
#          now actually implements ("accidental fix" — rustc's tests/crashes
#          model: promote it, don't let the exceptions file rot). The
#        same principle is used by test/fuzz_allowlist.txt in this arc.
#   5. Prints the full 3-column capability matrix + a summary.
#
# PARSING NOTES (heuristic, text-only, no compiler build — SEE INDIVIDUAL
# COMMENTS BELOW for exactly what is hardcoded and why):
#   - Interpreter: every `("name", ...)` literal key inside the
#     `externBindings = [ ... ]` list literal in eval.mdk. ONE binding uses a
#     variable key instead of a literal (`fallthroughName`, which resolves to
#     the string "__fallthrough__" per compiler/support/util.mdk:320) and is
#     added explicitly since the literal-key grep can't see it.
#   - LLVM: llvm_emit.mdk dispatches a SATURATED extern application via
#     `isAnyExtern`/`emitExternApplied` (~line 2253), the OR of ~18
#     family predicates (`isStrExtern`, `isFileExtern`, `isNetExtern`, ...).
#     Each predicate's body is a `contains name [ "a", "b", ... ]` literal
#     list; this script extracts that list mechanically per predicate.
#     `isMathUnary`/`isMathBinary` are NESTED inside `isNumExtern`'s OR-chain
#     (not part of `isAnyExtern`'s own OR-chain) so they're listed explicitly
#     too.  A handful of extern names bypass this predicate ladder entirely
#     because they're constant-inlined or specially dispatched earlier in the
#     CApp head ladder — verified by hand 2026-07-13, hardcoded below:
#       pi / e / intMinBound / intMaxBound / charMinBound / charMaxBound
#         → constant-inlined in emitVar (~line 1205-1216)
#       Ref / setRef → dispatched by exact name ahead of isAnyExtern
#         (~line 3252-3254: `fname == "Ref"` / `fname == "setRef"`)
#       arrayMakeWith → dispatched by exact name inside emitExternApplied's
#         ladder (~line 2300), no isXxx predicate of its own
#       __fallthrough__ → compiler-generated sentinel (desugared guard
#         fallthrough), handled by `emitFallthrough`, not the extern ladder
#   - Wasm: wasm_emit.mdk's ref-mode CApp ladder (emitAppRef, ~line 4580-4596)
#     dispatches via `isStrExternW` / `isLeafExternW` / `isArrayExternW`
#     (real implementations), `isNetExternW` (EXPLICIT REJECTION — `gapL`
#     with a "no WasmGC equivalent" message, a deliberate PERMANENT gap, not
#     a bug), and the same `Ref`/`setRef`/`pi`/`e`/`charMinBound`/
#     `charMaxBound`/`__fallthrough__` special-cases as LLVM (verified by
#     hand 2026-07-13). `intMinBound`/`intMaxBound` are present in source but
#     as a TRAP STUB (`["unreachable"]`, ~line 4116) — bound, but a program
#     that actually evaluates them aborts; NOT counted as implemented here,
#     tracked as its own TRAP-STUB category in the exceptions file.
#
# This script never builds the compiler and never runs `./medaka` — pure text
# analysis over checked-in .mdk source, so it is always safe to run and has
# no toolchain dependency (see test/run_gates.sh's LEGIT_SKIP_RE: this gate
# should simply always run and never legitimately SKIP).
#
# Usage:  sh test/diff_compiler_capability_matrix.sh [-v]
#           -v : also print the full per-extern matrix (default: summary +
#                any failures only)
# Exit:   0 if the catalog/engine/exceptions cross-reference is fully
#         consistent, 1 on any drift (see failure messages for the fix).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/stdlib/runtime.mdk"
EVALMDK="$ROOT/compiler/eval/eval.mdk"
LLVMMDK="$ROOT/compiler/backend/llvm_emit.mdk"
WASMMDK="$ROOT/compiler/backend/wasm_emit.mdk"
EXC="$ROOT/test/CAPABILITY-EXCEPTIONS.txt"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

for f in "$RUNTIME" "$EVALMDK" "$LLVMMDK" "$WASMMDK" "$EXC"; do
  [ -f "$f" ] || { echo "FAIL: missing input file $f"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Declared here (not just before step 6) because the int-bounds derivation in
# step 4 can also set it — see the comment there.
FAIL=0

# ── helper: print the body of a top-level `fn name = ...` predicate, from its
# defining line up to (excluding) the next top-level (column-0, letter-first)
# line that is not itself another clause of the same predicate. ────────────
extract_family() {
  file="$1"; fn="$2"
  awk -v fn="$fn" '
    {
      if ($0 ~ "^" fn " ") { grab=1; started=1; print; next }
      if (started && grab) {
        if ($0 ~ /^[A-Za-z]/) { grab=0 } else { print }
      }
    }
  ' "$file"
}

quoted_names() {
  grep -oE '"[A-Za-z_][A-Za-z0-9_]*"' | tr -d '"' | sort -u
}

# ── 1. the catalog ──────────────────────────────────────────────────────────
grep -E '^extern [A-Za-z_][A-Za-z0-9_]*' "$RUNTIME" | awk '{print $2}' | sort -u > "$WORK/all.txt"
N_ALL="$(wc -l < "$WORK/all.txt" | tr -d ' ')"

# ── 2. interpreter ───────────────────────────────────────────────────────────
# Match BOTH `externBindings = [` (a plain value) and `externBindings _ = [` (a
# Unit-taking fn). The latter is what it became when `Value` was made
# effect-polymorphic (`externBindings : Unit -> List (String, Value e)`): a
# constructor application is not generalized by this typechecker, so the table
# had to become a function to stay polymorphic in `e`.
# The interpreter has MORE THAN ONE binding table, and the gate must union them
# all or it under-reports (the dangerous direction: it would keep a fixed extern
# filed as a BUG and never demand promotion).
#   externBindings    — the pure/deterministic base. The differential oracle
#                       installs ONLY this, which is what keeps its goldens
#                       byte-identical.
#   ioExternBindings  — the host-installed capability table (the "host is the
#                       handler" seam, docs/spec/EFFECTS-SEMANTICS.md §7). `medaka run`
#                       installs it; the oracle entries do not.
# Any NEW table must be added here. The guard below is the backstop if one is
# forgotten... but it only catches a total parse failure, not a missed table,
# so keep this list honest.
sed -n -e '/^externBindings\( _\)\? = \[/,/^\]/p' \
       -e '/^ioExternBindings\( _\)\? = \[/,/^\]/p' "$EVALMDK" \
  | grep -oE '\("[A-Za-z_][A-Za-z0-9_]*"' | sed -E 's/^\(//' | tr -d '"' | sort -u > "$WORK/interp_impl.txt"

# GUARD: a parse failure must NOT masquerade as "every extern is missing".
# This gate reads eval.mdk as TEXT, so any refactor of the table's shape can
# silently zero it out — and the gate would then report ~100 bogus SILENT
# OMISSIONs (which is exactly what happened when the decl gained its `_` param).
# A real table has ~100 entries; anything tiny means the sed pattern stopped
# matching, which is a GATE bug, not a compiler bug. Say so, loudly, and exit
# distinctly rather than emitting a wall of false accusations.
N_PARSED="$(wc -l < "$WORK/interp_impl.txt" | tr -d ' ')"
if [ "$N_PARSED" -lt 50 ]; then
  echo "FAIL: could not parse eval.mdk's externBindings table — got only $N_PARSED entries (expected ~100)." >&2
  echo "      This is a GATE bug, not a missing-extern bug: the table's declaration shape probably changed." >&2
  echo "      Fix the sed pattern at $0 (§2) to match the current shape of:" >&2
  grep -nE '^externBindings' "$EVALMDK" | sed 's/^/        /' >&2
  exit 1
fi

# fallthroughName resolves to "__fallthrough__" (support/util.mdk:320) but is
# bound via a variable key, not a string literal — the grep above can't see
# it, so add it explicitly (see PARSING NOTES above).
echo "__fallthrough__" >> "$WORK/interp_impl.txt"
sort -u -o "$WORK/interp_impl.txt" "$WORK/interp_impl.txt"

# ── 3. LLVM ──────────────────────────────────────────────────────────────────
: > "$WORK/llvm_impl.txt"
for fam in isStrExtern isNumExtern isMathUnary isMathBinary isIoExtern isAbortExtern \
           isArrIntrinsic isArrLeafExtern isCharExtern isStrCharExtern isUnicodeExtern \
           isAdtExtern isEnvExtern isFileExtern isNetExtern isRngExtern isPerfExtern \
           isBitExtern isHashExtern isDebugLitExtern; do
  extract_family "$LLVMMDK" "$fam" | quoted_names >> "$WORK/llvm_impl.txt"
done
# Hardcoded bypasses of the isXxxExtern ladder — see PARSING NOTES above.
printf '%s\n' pi e intMinBound intMaxBound charMinBound charMaxBound Ref setRef \
  arrayMakeWith __fallthrough__ >> "$WORK/llvm_impl.txt"
sort -u -o "$WORK/llvm_impl.txt" "$WORK/llvm_impl.txt"

# ── 4. Wasm ──────────────────────────────────────────────────────────────────
: > "$WORK/wasm_impl.txt"
for fam in isStrExternW isLeafExternW isArrayExternW; do
  extract_family "$WASMMDK" "$fam" | quoted_names >> "$WORK/wasm_impl.txt"
done
# Comment-only quoted examples that are NOT extern names leak into the
# isStrExternW body (a doc comment literally says `("hi" / 'a')`) — strip any
# harvested name that isn't in the real catalog before it's used.
grep -Fxf "$WORK/all.txt" "$WORK/wasm_impl.txt" > "$WORK/wasm_impl.filtered.txt" || true
mv "$WORK/wasm_impl.filtered.txt" "$WORK/wasm_impl.txt"
printf '%s\n' Ref setRef pi e charMinBound charMaxBound __fallthrough__ >> "$WORK/wasm_impl.txt"
sort -u -o "$WORK/wasm_impl.txt" "$WORK/wasm_impl.txt"

extract_family "$WASMMDK" "isNetExternW" | quoted_names > "$WORK/wasm_net.txt"

# int bounds (intMinBound/intMaxBound): DERIVE trap-stub-vs-real from the
# ACTUAL dispatch line instead of hardcoding the verdict (#461 — the old code
# here was `printf '%s\n' intMinBound intMaxBound > wasm_trap.txt`, a file
# that was never even read again: the gate ENCODED "these two always trap on
# wasm" as a constant and could never notice when that stopped being true —
# which is exactly what happened when the 63-bit tagged-word box made them
# representable and wasm_emit.mdk started emitting real `i64.const` values).
# Instead: pull each name's own `x == "..."` dispatch line out of wasm_emit.mdk
# and test whether ITS OWN RHS still contains `unreachable`. If it does, it's
# a genuine trap stub (matches a TRAP-STUB row — nothing to report). If it
# doesn't, the name IS implemented on wasm, so add it to wasm_impl.txt: the
# existing "ACCIDENTAL FIX" check in step 6 below then fires on its own and
# fails the gate until the stale TRAP-STUB row is deleted/promoted — no
# separate bookkeeping needed, and the check re-derives every run instead of
# trusting a remembered verdict.
INTBOUND_MISSING=0
for b in intMinBound intMaxBound; do
  b_line="$(grep -E "x == \"$b\"" "$WASMMDK" | head -1)"
  if [ -z "$b_line" ]; then
    echo "FAIL: could not find wasm dispatch line for '$b' in wasm_emit.mdk (grep 'x == \"$b\"' found nothing) — the int-bounds derivation in $0 broke, not the compiler. Fix the pattern." >&2
    INTBOUND_MISSING=1
    continue
  fi
  if ! printf '%s' "$b_line" | grep -q 'unreachable'; then
    echo "$b" >> "$WORK/wasm_impl.txt"
  fi
done
if [ "$INTBOUND_MISSING" = 1 ]; then
  FAIL=1
fi
sort -u -o "$WORK/wasm_impl.txt" "$WORK/wasm_impl.txt"

# Same comment-example contamination guard on the LLVM side (cheap, in case a
# future doc comment adds a quoted non-extern word to one of the families).
grep -Fxf "$WORK/all.txt" "$WORK/llvm_impl.txt" > "$WORK/llvm_impl.filtered.txt" || true
mv "$WORK/llvm_impl.filtered.txt" "$WORK/llvm_impl.txt"

# ── 5. load the exceptions file ─────────────────────────────────────────────
# Format (tab-separated, '#'-prefixed comment/blank lines ignored):
#   extern<TAB>engine<TAB>category<TAB>reason[<TAB>pattern]
# engine  ∈ interp | llvm | wasm
# category ∈ BUG | DEAD | TODO | PERMANENT | TRAP-STUB | WASM-GAP | FROZEN-CONSTANT
# `pattern` (FROZEN-CONSTANT rows only): a literal substring expected to
# still be present in eval.mdk — see the drift check in step 7.
grep -v '^[[:space:]]*#' "$EXC" | grep -v '^[[:space:]]*$' > "$WORK/exc_rows.txt" || true

# Hygiene: every exceptions-file row must name a real extern and a real engine.
BAD=0
while IFS="$(printf '\t')" read -r ext eng cat rest; do
  [ -n "$ext" ] || continue
  if ! grep -qFx "$ext" "$WORK/all.txt"; then
    echo "FAIL: CAPABILITY-EXCEPTIONS.txt references unknown extern '$ext' (not declared in stdlib/runtime.mdk)"
    BAD=1
  fi
  case "$eng" in interp|llvm|wasm) ;; *)
    echo "FAIL: CAPABILITY-EXCEPTIONS.txt row for '$ext' has unknown engine '$eng' (want interp|llvm|wasm)"
    BAD=1 ;;
  esac
done < "$WORK/exc_rows.txt"

# Hygiene: no duplicate (extern, engine) rows.
DUPES="$(awk -F'\t' '{print $1"\t"$2}' "$WORK/exc_rows.txt" | sort | uniq -d)"
if [ -n "$DUPES" ]; then
  echo "FAIL: CAPABILITY-EXCEPTIONS.txt has duplicate (extern, engine) rows:"
  printf '%s\n' "$DUPES" | sed 's/^/  /'
  BAD=1
fi

# ── 6. per-engine, per-extern cross-reference ───────────────────────────────
: > "$WORK/matrix.txt"
for eng in interp llvm wasm; do
  case "$eng" in
    interp) impl="$WORK/interp_impl.txt" ;;
    llvm)   impl="$WORK/llvm_impl.txt" ;;
    wasm)   impl="$WORK/wasm_impl.txt" ;;
  esac
  while IFS= read -r ext; do
    if grep -qFx "$ext" "$impl"; then
      is_impl=Y
    else
      is_impl=N
    fi
    exc_line="$(awk -F'\t' -v e="$ext" -v g="$eng" '$1==e && $2==g {print; exit}' "$WORK/exc_rows.txt")"
    if [ -n "$exc_line" ]; then
      cat="$(printf '%s' "$exc_line" | awk -F'\t' '{print $3}')"
    else
      cat=""
    fi
    if [ "$is_impl" = Y ]; then
      if [ -n "$exc_line" ] && [ "$cat" != "FROZEN-CONSTANT" ]; then
        echo "FAIL: ACCIDENTAL FIX — '$ext' is now IMPLEMENTED by $eng, but CAPABILITY-EXCEPTIONS.txt still lists it as unsupported ($cat). Promote it: delete this row from test/CAPABILITY-EXCEPTIONS.txt."
        FAIL=1
      fi
    else
      if [ -z "$exc_line" ]; then
        echo "FAIL: SILENT OMISSION — '$ext' is NOT implemented by $eng and has no CAPABILITY-EXCEPTIONS.txt entry. Either implement it, or add a row with an honest reason."
        FAIL=1
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$ext" "$eng" "$is_impl" "$cat" >> "$WORK/matrix.txt"
  done < "$WORK/all.txt"
done

# ── 7. FROZEN-CONSTANT drift check ──────────────────────────────────────────
# These externs ARE bound (implemented=Y above) but to a fabricated/no-op
# value — worse than a panic because it's silent. Track them and verify the
# hardcoded literal each one grep-matches is still present; if the source no
# longer contains it, something changed (a real fix, or an unrelated
# refactor) and a human needs to look, not let this rot silently either.
FROZEN_ROWS="$(awk -F'\t' '$3=="FROZEN-CONSTANT" && $2=="interp"' "$WORK/exc_rows.txt")"
if [ -n "$FROZEN_ROWS" ]; then
  printf '%s\n' "$FROZEN_ROWS" | while IFS="$(printf '\t')" read -r ext eng cat reason pat; do
    [ -n "$pat" ] || continue
    if ! grep -qF "$pat" "$EVALMDK"; then
      echo "FAIL: FROZEN-CONSTANT DRIFT — expected literal pattern for '$ext' not found in eval.mdk: \"$pat\". Either it was genuinely fixed (great — remove/relabel this row) or the code shape changed (update the pattern). Either way, review before this rots silently again."
    fi
  done > "$WORK/frozen_check.txt"
  if [ -s "$WORK/frozen_check.txt" ]; then
    cat "$WORK/frozen_check.txt"
    FAIL=1
  fi
fi

# ── 8. report ────────────────────────────────────────────────────────────────
n_interp_y="$(awk -F'\t' '$2=="interp" && $3=="Y"' "$WORK/matrix.txt" | wc -l | tr -d ' ')"
n_llvm_y="$(awk -F'\t' '$2=="llvm" && $3=="Y"' "$WORK/matrix.txt" | wc -l | tr -d ' ')"
n_wasm_y="$(awk -F'\t' '$2=="wasm" && $3=="Y"' "$WORK/matrix.txt" | wc -l | tr -d ' ')"

if [ "$VERBOSE" = 1 ]; then
  echo "=== capability matrix ($N_ALL externs) ==="
  printf '%-26s %-8s %-8s %-8s\n' "extern" "interp" "llvm" "wasm"
  while IFS= read -r ext; do
    i="$(awk -F'\t' -v e="$ext" '$1==e && $2=="interp"{print $3}' "$WORK/matrix.txt")"
    l="$(awk -F'\t' -v e="$ext" '$1==e && $2=="llvm"{print $3}' "$WORK/matrix.txt")"
    w="$(awk -F'\t' -v e="$ext" '$1==e && $2=="wasm"{print $3}' "$WORK/matrix.txt")"
    printf '%-26s %-8s %-8s %-8s\n' "$ext" "$i" "$l" "$w"
  done < "$WORK/all.txt"
  echo
fi

echo "=== capability-matrix summary ==="
echo "externs in catalog (stdlib/runtime.mdk): $N_ALL"
echo "implemented — interp: $n_interp_y/$N_ALL   llvm: $n_llvm_y/$N_ALL   wasm: $n_wasm_y/$N_ALL"
echo "exceptions on file, by engine + category:"
awk -F'\t' '{print $2"\t"$3}' "$WORK/exc_rows.txt" | sort | uniq -c \
  | awk '{printf "  %-6s %-6s %-16s %s\n", "count="$1, $2, $3, ""}'

if [ "$BAD" = 1 ] || [ "$FAIL" = 1 ]; then
  echo
  echo "FAIL: capability matrix / exceptions file drift detected (see FAIL lines above)."
  exit 1
fi
echo
echo "PASS: catalog, engines, and CAPABILITY-EXCEPTIONS.txt agree."
exit 0
