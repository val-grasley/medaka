#!/bin/sh
# diff_selfhost_doc.sh — `medaka doc` differential gate.
#
# The native `medaka doc <file>` (selfhost/tools/doc.mdk via medaka_cli.mdk) must
# be BYTE-IDENTICAL to the OCaml oracle `_build/default/bin/main.exe doc <file>`
# over the test/doc_fixtures corpus.  doc is single-file (matches OCaml).
#
# Corpus covers: exported value decls + doc comments (values), data decls (data),
# record decls (records), a requires-bearing interface/impl (iface, impl), a decl
# with NO comment (nocomment), a multi-clause function (multiclause), a
# block-comment (`{- … -}`) doc comment (block), a no-exports file → just
# `# module` (noexports), type alias + newtype (aliases), the `export` keyword on
# its own line above a multi-line doc (multiline), a section-gap-breaks-doc case
# (gapbreak), and an explicit-signature value (explicitsig).
#
# Path-stable: the fixture path is the only absolute path that can appear; we
# strip it on BOTH sides (sed s|<path>|<fixture>|) so goldens never bake /Users/.
# No committed goldens — the OCaml oracle is the live reference (like
# diff_selfhost_check_json.sh).
#
# OCaml-free at runtime for the native leg; the oracle leg uses the frozen OCaml
# compiler (soak-period differential oracle).
#
# Usage:  sh test/diff_selfhost_doc.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
ORACLE="$ROOT/_build/default/bin/main.exe"
FIXDIR="$ROOT/test/doc_fixtures"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -x "$ORACLE" ] || { echo "SKIP: OCaml oracle not built — run: dune build --root $ROOT"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

pass=0; fail=0
for mdk in "$FIXDIR"/*.mdk; do
  name="$(basename "$mdk" .mdk)"

  native_out="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" doc "$mdk" 2>&1 | sed "s|$mdk|<fixture>|g")"
  oracle_out="$(perl -e 'alarm 90; exec @ARGV' \
      "$ORACLE" doc "$mdk" 2>&1 | sed "s|$mdk|<fixture>|g")"

  if [ "$native_out" = "$oracle_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  --- native ---\n%s\n  --- ocaml ---\n%s\n' "$native_out" "$oracle_out"
  fi
done

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
