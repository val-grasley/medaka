#!/usr/bin/env bash
# Re-verify every VERIFIED bug in COMPILER-BUGS.md against the CURRENT compiler.
#
# WHY THIS EXISTS: bug lists in this repo go stale faster than anyone updates them
# (AGENTS.md / ORCHESTRATING.md both say so). A compiler orchestrator is actively
# fixing some of these. So do not trust COMPILER-BUGS.md — RUN THIS. It prints
# OPEN or FIXED per bug against whatever ./medaka you point it at, and exits 0
# regardless: it is a status report, not a gate.
#
#   MEDAKA_ROOT=$PWD bash sqlite/findings/verify_compiler_bugs.sh
#
# When a bug prints FIXED, mark it closed in COMPILER-BUGS.md (and ideally move
# its repro into a real regression fixture so it stays closed).
set -u

ROOT="${MEDAKA_ROOT:-$PWD}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
[ -x "$MEDAKA" ] || { echo "no medaka binary at $MEDAKA (set MEDAKA/MEDAKA_ROOT)"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
open=0; fixed=0

# report <id> <verdict OPEN|FIXED> <one-line detail>
report () {
  if [ "$2" = "OPEN" ]; then open=$((open+1)); printf '  %-4s OPEN   %s\n' "$1" "$3"
  else fixed=$((fixed+1)); printf '  %-4s FIXED  %s\n' "$1" "$3"; fi
}

echo "Re-verifying COMPILER-BUGS.md against: $MEDAKA"
echo "  compiler commit: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo

# --- B1: partially-applied data constructor miscompiles under build --------
cat > "$TMP/b1.mdk" <<'EOF'
data Op = OAdd | OSub
data Ex = Num Int | Bin Op Ex Ex
apply2 : (Ex -> Ex -> Ex) -> Ex -> Ex -> Ex
apply2 f a b = f a b
describe : Ex -> String
describe (Bin OAdd (Num a) (Num b)) = "add \{a} \{b}"
describe _ = "OTHER"
main : <IO> Unit
main = println (describe (apply2 (Bin OAdd) (Num 1) (Num 2)))
EOF
if "$MEDAKA" build "$TMP/b1.mdk" -o "$TMP/b1" >/dev/null 2>&1; then
  got="$("$TMP/b1" 2>&1)"
  [ "$got" = "add 1 2" ] && report B1 FIXED "PAP constructor builds correctly (LLVM)" \
                         || report B1 OPEN  "PAP ctor -> build printed '$got' (want 'add 1 2')"
else
  report B1 OPEN "PAP ctor -> build failed outright"
fi
# B1w: the SAME bug on the OTHER backend. main's ced6342d fixed the LLVM emitter
# and did NOT reach the WasmGC one — so "B1 is fixed" was true and misleading.
# ALWAYS check both backends; a one-backend fix is a half fix.
if "$MEDAKA" build --target wasm "$TMP/b1.mdk" -o "$TMP/b1.wat" >/dev/null 2>&1; then
  report B1w FIXED "PAP constructor emits under --target wasm too"
else
  report B1w OPEN "PAP ctor -> WasmGC emitter still fails (LLVM is fixed; the fix did not reach wasm)"
fi

# --- B2: cross-module record update writes the wrong slot -------------------
mkdir -p "$TMP/b2/lib"
cat > "$TMP/b2/lib/a.mdk" <<'EOF'
public export data Sel = Sel { tag : String, groupBy : List Int }
export mkSel : Sel
mkSel = Sel { tag = "sel", groupBy = [7] }
EOF
cat > "$TMP/b2/main.mdk" <<'EOF'
import lib.a.{Sel, mkSel}
data Agg = Agg { groupBy : List Int, n : Int }
withGroupBy : List Int -> Agg -> Agg
withGroupBy cols q = { q | groupBy = cols }
main : <IO> Unit
main =
  let a = withGroupBy [3] (Agg { groupBy = [], n = 1 })
  println "\{debug mkSel.groupBy} \{debug a.groupBy}"
EOF
if "$MEDAKA" build "$TMP/b2/main.mdk" -o "$TMP/b2bin" >/dev/null 2>&1; then
  got="$("$TMP/b2bin" 2>&1)"
  [ "$got" = "[7] [3]" ] && report B2 FIXED "cross-module record update writes the right slot" \
                         || report B2 OPEN  "record update -> build printed '$got' (want '[7] [3]')"
else
  report B2 OPEN "record update -> build failed outright"
fi

# --- B3: multi-module run does not gate on TYPE errors ----------------------
mkdir -p "$TMP/b3/lib"
printf 'public export data Foo = Foo Int\n' > "$TMP/b3/lib/t.mdk"
printf 'import lib.t.{Foo}\n\nmain : <IO> Unit\nmain = println "\\{Foo 1}"\n' > "$TMP/b3/main.mdk"
out="$("$MEDAKA" run "$TMP/b3/main.mdk" 2>&1)"
case "$out" in
  *"No impl of Display"*) report B3 FIXED "multi-module run reports the type error" ;;
  *) report B3 OPEN "run executed the ill-typed program: $(printf '%s' "$out" | head -1)" ;;
esac

# --- B4: run discards buffered stdout on panic (build does not) -------------
cat > "$TMP/b4.mdk" <<'EOF'
boom : Int -> Int
boom 0 = panic "deliberate"
boom n = n
main : <IO> Unit
main =
  println "PRINTED BEFORE PANIC"
  println "\{boom 0}"
EOF
out="$("$MEDAKA" run "$TMP/b4.mdk" 2>/dev/null)"
case "$out" in
  *"PRINTED BEFORE PANIC"*) report B4 FIXED "run flushes stdout before the panic" ;;
  *) report B4 OPEN "run lost the pre-panic stdout (build does not)" ;;
esac

# --- B5: deriving (Eq) on a type with an Array field cannot be built --------
cat > "$TMP/b5.mdk" <<'EOF'
data Blob = Blob (Array Int) deriving (Eq)
main : <IO> Unit
main = println "\{Blob (arrayMake 2 0) == Blob (arrayMake 2 0)}"
EOF
chk="$("$MEDAKA" check "$TMP/b5.mdk" 2>&1)"
if "$MEDAKA" build "$TMP/b5.mdk" -o "$TMP/b5" >/dev/null 2>&1 && [ -x "$TMP/b5" ]; then
  report B5 FIXED "deriving(Eq) over an Array field builds"
else
  case "$chk" in
    *"No impl"*|*"Eq"*[Aa]"rray"*) report B5 FIXED "now rejected at CHECK (the other valid fix)" ;;
    *) report B5 OPEN "check accepts, build fails (no Eq (Array a) impl; deriving unchecked)" ;;
  esac
fi

# --- B6: `exit` unbound under run, works under build ------------------------
cat > "$TMP/b6.mdk" <<'EOF'
main : <IO, Panic> Unit
main = exit 3
EOF
out="$("$MEDAKA" run "$TMP/b6.mdk" 2>&1)"
case "$out" in
  *"unbound identifier: exit"*) report B6 OPEN "run: 'unbound identifier: exit' (build works)" ;;
  *) report B6 FIXED "exit is implemented in eval" ;;
esac

# --- B7: Float cannot round-trip through display ----------------------------
cat > "$TMP/b7.mdk" <<'EOF'
main : <IO> Unit
main = println "\{0.1 + 0.2}"
EOF
out="$("$MEDAKA" run "$TMP/b7.mdk" 2>&1)"
if [ "$out" = "0.30000000000000004" ]; then
  report B7 FIXED "Float prints shortest-round-trip"
else
  report B7 OPEN "0.1 + 0.2 prints '$out' (want 0.30000000000000004) — truncated to ~12 sig digits"
fi

# --- B8: a Markdown blockquote in a doc comment is run as a doctest ---------
cat > "$TMP/b8.mdk" <<'EOF'
-- | Adds one.
--
-- > inc 1
-- 2
--
-- Note:
--
-- > This is prose in a Markdown blockquote, not a doctest.
--
export inc : Int -> Int
inc n = n + 1
EOF
out="$("$MEDAKA" test "$TMP/b8.mdk" 2>&1)"
case "$out" in
  *"parse error"*) report B8 OPEN "prose blockquote parsed as a doctest -> unlocated E-PANIC, aborts the file" ;;
  *) report B8 FIXED "prose blockquotes are not treated as doctests" ;;
esac

# --- B10: `fmt --write` CORRUPTS source (float literal >= 1e15) -------------
# The printer emits scientific notation; the lexer cannot read ANY exponent
# form back. fmt runs in the pre-commit hook, so this destroys the file.
cat > "$TMP/b10.mdk" <<'EOF'
big : Float
big = 9000000000000000.0
main : <IO> Unit
main = println "\{big}"
EOF
if "$MEDAKA" check "$TMP/b10.mdk" >/dev/null 2>&1; then
  "$MEDAKA" fmt --write "$TMP/b10.mdk" >/dev/null 2>&1
  if "$MEDAKA" check "$TMP/b10.mdk" >/dev/null 2>&1; then
    report B10 FIXED "fmt round-trips a >=1e15 float literal"
  else
    report B10 OPEN "fmt --write REWROTE a valid float to '$(grep '^big = ' "$TMP/b10.mdk" | cut -d= -f2 | tr -d ' ')' which no longer parses"
  fi
else
  report B10 OPEN "cannot even check the pre-fmt source (unexpected)"
fi

# --- Mut: is <Mut> a purity guarantee? (spec says yes; binary says no) ------
cat > "$TMP/mut.mdk" <<'EOF'
counter : Ref Int
counter = Ref 0
peek : Unit -> Int
peek _ = counter.value
bump : Unit -> <Mut> Unit
bump _ = setRef counter (counter.value + 1)
main : <IO, Mut> Unit
main =
  let a = peek ()
  bump ()
  println "\{a}\{peek ()}"
EOF
out="$("$MEDAKA" run "$TMP/mut.mdk" 2>&1)"
if [ "$out" = "01" ]; then
  report MUT OPEN "a PURE-typed fn returns 2 answers across a mutation (EFFECTS-SEMANTICS.md:448 says Mut = purity tracking)"
else
  report MUT FIXED "pure-typed reads of mutable state no longer diverge (or are now rejected)"
fi

echo
echo "  $open open, $fixed fixed"

# --- Workarounds in the library, keyed to the bug that forced them -----------
# Every workaround site carries a `WORKAROUND(<id>)` marker. When a bug above
# flips to FIXED, these are the sites to revert — otherwise the library keeps
# paying for a bug that no longer exists, which is how workarounds become
# permanent.
echo
echo "  Workarounds in the library (grep -rn 'WORKAROUND(' sqlite/lib/):"
if command -v grep >/dev/null && [ -d "$ROOT/sqlite/lib" ]; then
  grep -rn "WORKAROUND(" "$ROOT/sqlite/lib" 2>/dev/null \
    | sed -E "s|^$ROOT/||; s|(-- *)?WORKAROUND\(([A-Z0-9]+)\):|[\2]|" \
    | awk -F: '{ file=$1; line=$2; $1=""; $2=""; sub(/^ +/,""); printf "    %-28s %s\n", file ":" line, $0 }' \
    | sed 's/  */ /g' | cut -c1-118
fi
echo
echo "  (status report only — always exits 0)"
exit 0
