#!/bin/sh
# test/diff_compiler_references_tool.sh — golden JSON-RPC transcript gate for
# the `medaka_references` MCP tool (#254 Stage 1: MCP tool + LSP
# `textDocument/references`, both sharing `tools.lsp.referencesResult`, which
# in turn sits on Stage 0's `compiler/tools/refindex.mdk` index).
#
# Feeds a canned newline-delimited JSON-RPC request stream to `./medaka mcp`
# on stdin (same protocol/harness shape as test/diff_compiler_mcp.sh — see
# that gate for the wire format), captures stdout, and diffs it against a
# committed golden.
#
# FIXTURE-DIR LOOP (same extensibility idiom as diff_compiler_mcp.sh): each
# fixture is a pair under test/references_fixtures/query/:
#   <name>.jsonl   — the request stream (one JSON-RPC message per line)
#   <name>.golden  — the exact expected stdout
# A NEW subdir, never touching test/references_fixtures/correctness/ (that
# corpus belongs to diff_compiler_references_correctness.sh's Stage-0 dump —
# a shared-corpus edit there would perturb ITS golden instead of adding one
# here; see compiler/AGENTS.md's fixture-corpus trap).
#
# WHAT THE cross_file.jsonl FIXTURE PROVES (query/{defs,main,other,reexport}.mdk)
# ---------------------------------------------------------------------------
# All three queries click inside query/main.mdk. NOTE (#254 Stage 1.1):
# `medaka_references` now builds a TRUE WHOLE-PROJECT index (recursive
# `listDir` enumeration under `findProjectRoot`, `buildRefIndexProject` in
# compiler/tools/refindex.mdk) rather than walking only the clicked file's
# own import closure — so every fixture `.mdk` under this directory is
# indexed regardless of which file the click lands in. `main.mdk` is kept as
# the click target for Q1-Q3 below only because it is where the interesting
# uses (alias/re-export/shadowing) live, not because clicking elsewhere would
# miss anything; `leaf_def_to_importer.jsonl` and `two_hop_reexport.jsonl`
# below deliberately click OTHER files precisely to prove that.
#
#   Q1 (id 2): click on `helper` in main.mdk's `usesDirect = helper 3 + shared`
#     (line 15 0-based, col 13) — includeDeclaration defaults true. Proves
#     CROSS-FILE (defs.mdk's own internal use), ALIAS IMPORT (`D.helper` on
#     line 18), and RE-EXPORT CHAIN (`rHelper`, imported from `reexport.mdk`,
#     whose own `export import defs.{helper}` re-exports defs' true origin —
#     line 21) all collapse onto the SAME BinderKey as the def in defs.mdk.
#     Expect 6 locations: defs.mdk def (6:0-6 1-based) + defs.mdk use
#     (12:25-31) + via2.mdk's two-hop-reexport use (11:13-21 — see
#     two_hop_reexport.jsonl below; it lands in THIS result too because the
#     index is whole-project) + main.mdk uses at 16:13-19 (the click site)
#     and 22:15-22 (rHelper — a plain EVar, so its own precise ELoc span).
#     The 6th, for `D.helper` (main.mdk line 19), is a hand-verified SURPRISE:
#     refindex's alias-qualified-field-access walk (`walkFieldAccess`'s alias
#     branch, compiler/tools/refindex.mdk) records the reference at whatever
#     `curLoc` was last set by an ENCLOSING atom's `ELoc` — neither `EApp`
#     nor `EFieldAccess` refresh it — so for a body that's `D.helper 4` with
#     no other located atom ahead of it, that's still the WHOLE DECL's own
#     name Loc from `walkDeclBody`'s initial `loc`, i.e. `usesAlias` itself
#     (19:0-9, NOT a span touching "D.helper" at all). The BinderKey is still
#     exactly right (this use groups under the SAME key as every other
#     `helper` hit below) — only the reported RANGE is imprecise for this one
#     shape. Verified against `compiler/tools/refindex.mdk`'s source, not
#     guessed; NOT a bug in this stage's wiring (refindex.mdk is Stage 0's
#     substrate, out of this stage's scope) — flagged as a residual in the
#     handoff report.
#
#   Q2 (id 3): click on the LOCAL `shared` inside `topG`'s body (line 12
#     0-based, col 2 — `  shared + shared`), includeDeclaration=false. Proves
#     SHADOWING: `let shared = x + 1` in `topG` mints a DISTINCT `local`
#     BinderKey from the imported top-level `defs.shared`, so this query
#     returns ONLY the 2 in-function uses (main.mdk 1-based line 13, cols
#     2-8 and 11-17) — never defs.mdk's `shared`, never `usesDirect`'s
#     top-level use on line 16.
#
#   Q3 (id 4): click on the top-level `shared` in `usesDirect` (SAME line as
#     Q1, col 24), includeDeclaration=true. Proves SAME-NAME-IN-TWO-MODULES
#     non-contamination: `other.mdk` defines its OWN `shared` (loaded into
#     the SAME project graph via main's `import other as O`) — a regression
#     that keyed by spelling instead of (module, namespace, name) would pull
#     other.mdk's 2 `shared` occurrences into this result. Expect exactly 3
#     locations: defs.mdk def (9:0-6) + defs.mdk use (12:16-22) + main.mdk's
#     own use (16:24-30, the click site) — other.mdk's `shared` and topG's
#     LOCAL `shared` (Q2) are BOTH absent.
#
# WHAT leaf_def_to_importer.jsonl PROVES (#254 Stage 1.1's decisive fixture)
# ---------------------------------------------------------------------------
# Clicks defs.mdk's `shared` DEFINITION (line 9 1-based / 8 0-based, col 2) —
# a LEAF module with no imports of its own, so the OLD entry-rooted scope
# (Stage 1) would only ever have seen defs.mdk itself from here. Expect
# exactly 3 locations: def (9:0-6) + defs.mdk's own use (12:16-22) + main.mdk's
# `usesDirect` use (16:24-30) — the IMPORTER's use, only reachable because the
# index now covers the whole project, not one entry's closure. `shared` (no
# parameters) was chosen over `helper` deliberately: `helper x = x + 1` has a
# param `x` whose local-binder def Loc COLLIDES with `helper`'s own name Loc
# (both come from `walkDeclBody`'s single `loc` argument — a pre-existing
# Stage-0 imprecision, not this stage's bug), so clicking `helper`'s def
# resolves to `x`'s key instead. `shared` has no params, so no collision.
#
# WHAT two_hop_reexport.jsonl PROVES (PR #912 review: transitivity, not just
# one hop) -- query/{reexport2,via2}.mdk
# ---------------------------------------------------------------------------
# cross_file.jsonl's re-export case is ONE hop: reexport.mdk directly
# re-exports defs.helper. This fixture adds a SECOND hop: reexport2.mdk
# re-exports `helper` from reexport.mdk (which itself re-exports defs.mdk),
# and via2.mdk imports `helper as rHelper2` from reexport2.mdk — so resolving
# `rHelper2` correctly requires the whole-project topo-sort
# (`buildRefIndexProject`'s dependency-first ordering pass,
# compiler/tools/refindex.mdk) to have indexed reexport.mdk BEFORE
# reexport2.mdk, which in turn must be indexed BEFORE via2.mdk — i.e. it
# proves the ordering is TRANSITIVE across a chain, not just correct for a
# single dependency edge (the shape a less careful "does this file's ONE
# direct import already have an origin" fix could still get wrong for a
# longer chain even after the one-hop regression this stage's first cut hit
# was patched — see the commit message for that bug). Click `rHelper2` in
# via2.mdk (line 11 1-based / 10 0-based, col 13 — `usesTwoHop = rHelper2 9`),
# includeDeclaration defaults true. Expect 6 locations, EXACTLY the same set
# Q1 above resolves to (defs def + defs use + via2's own use, the click site,
# + main.mdk's 3 uses) — proving `rHelper2` merges under the IDENTICAL
# BinderKey as every direct/aliased/one-hop-reexported use of `helper`.
#
# All (line, col) pairs above were hand-derived from the fixture source with
# a Python regex scan (word-boundary
# `\b(helper|shared|rHelper|rHelper2|usesTwoHop)\b`), not guessed —
# re-derive with the same scan if the fixtures ever change:
#   python3 -c "$(cat <<'PY'
# import re
# for fn in ('defs.mdk','main.mdk','other.mdk','via2.mdk','reexport2.mdk'):
#     for i,l in enumerate(open(fn),1):
#         for m in re.finditer(r'\b(helper|shared|rHelper|rHelper2|usesTwoHop)\b', l.rstrip()):
#             print(fn, i, m.start(), m.end(), m.group())
# PY
# )"
#
# To regenerate a golden: CAPTURE=1 sh test/diff_compiler_references_tool.sh
# (regenerates ALL fixtures' goldens in this dir's FIXDIR loop — diff the
# result before committing, same as any other CAPTURE=1 gate.)
#
# Usage: sh test/diff_compiler_references_tool.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/references_fixtures/query"

[ -x "$MEDAKA" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

# Fixed cwd = repo root, exactly like diff_compiler_mcp.sh, so a fixture's
# repo-relative `file` argument (e.g. test/references_fixtures/query/main.mdk)
# resolves the same way regardless of where this gate was invoked from, and
# no `medaka.toml` sits above the fixture dir, so `findProjectRoot` falls
# back to the fixture dir itself as the project root (same as the Stage-0
# correctness gate's `roots=[FIXDIR]`).
cd "$ROOT" || { echo "FAIL: cannot cd to $ROOT"; exit 1; }

pass=0; fail=0

for req in "$FIXDIR"/*.jsonl; do
  [ -f "$req" ] || continue
  name="$(basename "$req" .jsonl)"
  golden="$FIXDIR/$name.golden"

  tmpout="$(mktemp)"
  perl -e 'alarm 30; exec @ARGV' "$MEDAKA" mcp < "$req" > "$tmpout" 2>/dev/null
  rc=$?
  self_out="$(cat "$tmpout")"
  rm -f "$tmpout"

  if [ "${CAPTURE:-0}" = "1" ]; then
    printf '%s\n' "$self_out" > "$golden"
    printf 'CAPTURE %s\n' "$golden"
    continue
  fi

  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
  fi
  want_out="$(cat "$golden")"

  # Exit code checked too (not just output match) — a tool that emits correct
  # response lines and THEN crashes before EOF must not read as a pass (same
  # rationale as diff_compiler_mcp.sh).
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s: medaka mcp exited %d\n' "$name" "$rc"
    printf '  self:   %s\n' "$self_out"
  elif [ "$self_out" = "$want_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  self:   %s\n' "$self_out"
    printf '  golden: %s\n' "$want_out"
  fi
done

if [ "${CAPTURE:-0}" = "1" ]; then
  exit 0
fi

echo ""
total=$((pass+fail))
printf 'checked %d fixture(s): %d ok, %d failing\n' "$total" "$pass" "$fail"

# A gate that silently compares zero fixtures must FAIL, not report green.
if [ "$total" -eq 0 ]; then
  echo "FAIL: no fixtures found under $FIXDIR (checked 0 — treating as failure)"
  exit 1
fi

[ "$fail" -eq 0 ]
