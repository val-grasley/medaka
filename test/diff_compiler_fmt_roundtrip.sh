#!/bin/sh
# diff_compiler_fmt_roundtrip.sh — AST-FIDELITY gate for `medaka fmt` (issue #130).
#
# `fmt --write` silently dropping parens is a latent S0: a formatter that can change a
# program's PARSE is a silent-wrongness vector, and the pre-commit hook force-runs fmt
# over the compiler's own source on every commit. This gate turns "does fmt preserve
# meaning" into a machine-checked invariant instead of a hope.
#
# Method: for each source file f, compare the parse-stage AST S-expression dump
# (test/bin/parse_main, compiler/entries/parse_main.mdk:15 `programToSexp (parse src)`)
# BEFORE formatting vs AFTER running it through the formatter (test/bin/fmt_main,
# compiler/entries/fmt_main.mdk). If fmt changed what the program PARSES TO, the two
# dumps differ and the gate fails.
#
# The dump is location-insensitive by construction: ELoc/spans are stripped before
# printing (compiler/ir/sexp.mdk:116 `exprSexp (ELoc _ e) = exprSexp e`), so different
# byte offsets after reformatting never show up — the comparison is exact byte-equality
# of the dump text, no span normalization needed. Parens carry no author-record in the
# AST (no EParen node; a paren is a transparent ELoc atom around its inner expr), so
# AST-equality is exactly the right invariant: fmt dropping a REDUNDANT paren is
# AST-equal (PASS, the fix for #130); fmt regrouping a MEANING-changing expression is
# AST-different (FAIL, caught here). This also permanently pins issue #51's bug class
# (any future fmt corruption that changes parse shape, not just the float-literal case).
#
# Corpus: every real .mdk source under compiler/ + stdlib/, plus both format-focused
# fixture corpora (test/fmt_fixtures, test/parse_fixtures) — the broadest round-trip
# sweep any fmt gate in this tree runs.
#
# Usage:  sh test/diff_compiler_fmt_roundtrip.sh [files...]
# Exit:   0 every file's parse-before == parse-after (and at least one file was
#         checked); 1 a mismatch, OR zero files checked (a gate that runs nothing
#         must FAIL, not pass); 2 an oracle binary is missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSE="$ROOT/test/bin/parse_main"
FMT="$ROOT/test/bin/fmt_main"

# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398).
_missing=""
[ -x "$PARSE" ] || _missing="$_missing $PARSE"
[ -x "$FMT" ] || _missing="$_missing $FMT"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi

# NOTE on the sibling gates' "Unit auto-print" convention (test/diff_compiler_fmt.sh,
# and the retired printer gate — now the # PRINTER snapshot section — both piped
# through a `strip_unit` that drops a trailing
# "()"): that convention does NOT apply here, verified empirically against this build —
# parse_main and fmt_main are BOTH `main : <IO> Unit` (a `match args () { ... }` whose
# every arm is Unit-typed: putStr/ePutStrLn), and `shouldAutoPrintMain`
# (compiler/driver/main_autoprint.mdk) explicitly returns False whenever
# `mainTypeIsUnit()` — so the wrap that would emit `println <e>` never fires, and no
# trailing "()" is ever appended to either oracle's stdout (checked via `od -c` on
# fmt_main's raw output for several fixtures: it ends exactly at the source's own last
# byte, never "()"). This matches the MEMORY note "Unit main no auto-print": the
# behavior the sibling gates' `strip_unit` guards against was fixed away upstream, and
# their `strip_unit` is now a harmless no-op for THEIR use (comparing text against a
# golden). It is NOT harmless here: this gate feeds fmt_main's stdout back into a
# re-parse, so blindly stripping a trailing "()" would corrupt any file whose real last
# line legitimately ends in "()" (e.g. `unit = ()`, `replLoop ()`) into unparseable
# source — which is exactly what an earlier version of this gate did, and it is why
# there is no strip_unit call below.

# ── KNOWN-DIVERGENCE LEDGER (self-draining ratchet) ──────────────────────────
# A short checked-in list of fixtures where fmt is KNOWN to change the parse, each
# with a tracking issue (test/fmt_roundtrip_known_divergence.txt). The ratchet runs
# in BOTH directions — this is the whole point, a plain skip-list rots:
#   * a file that diverges and is NOT listed          -> FAIL (a new regression);
#   * a listed file that now ROUND-TRIPS CLEAN         -> FAIL ("now passes — remove
#                                                         it"), so a fix cannot land
#                                                         and leave the ledger stale;
#   * a listed file that STILL diverges                -> tolerated, but COUNTED and
#                                                         NAMED (never silent).
# Paths in the ledger are repo-relative; the corpus paths here are absolute, so we
# compare on the "$ROOT/"-stripped tail.
LEDGER="$ROOT/test/fmt_roundtrip_known_divergence.txt"
known=""
if [ -f "$LEDGER" ]; then
  # First whitespace-delimited token of each non-comment line is the path.
  known="$(sed 's/#.*//' "$LEDGER" | while read -r p _; do
    [ -n "$p" ] && printf '%s\n' "$p"
  done)"
fi
is_known() { case "
$known
" in *"
$1
"*) return 0 ;; *) return 1 ;; esac; }

if [ "$#" -gt 0 ]; then
  files="$*"
  full_run=0
else
  files="$ROOT/compiler/frontend/*.mdk $ROOT/compiler/types/*.mdk $ROOT/compiler/ir/*.mdk \
$ROOT/compiler/backend/*.mdk $ROOT/compiler/eval/*.mdk $ROOT/compiler/driver/*.mdk \
$ROOT/compiler/tools/*.mdk $ROOT/compiler/support/*.mdk $ROOT/compiler/entries/*.mdk \
$ROOT/stdlib/*.mdk $ROOT/test/fmt_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk"
  full_run=1
fi

# Local scratch dir — deliberately NOT named TMPDIR (that is the well-known env var;
# reassigning it would leak into this script's every child process).
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

n=0
pass=0
fail=0
kdiv=0              # ledgered files that STILL diverge (tolerated)
kdiv_names=""
seen_known=""      # ledgered files actually encountered this run
for f in $files; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  rel="${f#"$ROOT"/}"

  # An oracle CRASH must never impersonate a result. Without these checks, a
  # non-zero exit's empty/garbage stdout flows into the AST compare and gets
  # misdiagnosed as "fmt changed the parse" — or, if BOTH parse calls crash on an
  # unparseable file, as a clean PASS. This gate exists to stop a crash looking
  # clean, so a non-zero oracle exit is a hard, labelled failure. ($? right after a
  # $(...) assignment is that command's status — these stay in the MAIN shell so the
  # n/fail counters are not lost to a subshell.)
  before="$("$PARSE" "$f" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: parse_main crashed (exit %d) on the original source\n' "$rel" "$rc"
    exit 1
  fi

  formatted="$WORKDIR/$n.mdk"
  "$FMT" "$f" 2>/dev/null > "$formatted"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: fmt_main crashed (exit %d)\n' "$rel" "$rc"
    exit 1
  fi

  after="$("$PARSE" "$formatted" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: parse_main crashed (exit %d) re-parsing the formatted output\n' "$rel" "$rc"
    exit 1
  fi

  if is_known "$rel"; then
    seen_known="$seen_known $rel"
    if [ "$before" = "$after" ]; then
      # Accidental fix: a ledgered divergence now round-trips clean. FAIL loudly so
      # the ledger cannot silently retain a fixed entry.
      fail=$((fail + 1))
      printf 'FAIL %s — known divergence (#142) now passes: remove it from test/fmt_roundtrip_known_divergence.txt and close the tracking issue\n' "$rel"
    else
      kdiv=$((kdiv + 1))
      kdiv_names="$kdiv_names $rel"
    fi
  elif [ "$before" = "$after" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s (fmt round-trip changed the AST — not in the known-divergence ledger)\n' "$rel"
    printf '%s\n' "$before" > "$WORKDIR/$n.before.sexp"
    printf '%s\n' "$after" > "$WORKDIR/$n.after.sexp"
    diff -u "$WORKDIR/$n.before.sexp" "$WORKDIR/$n.after.sexp" | sed 's/^/    /'
  fi
done

# In a full-corpus run, a ledger entry that was NEVER encountered is stale (the fixture
# was renamed or deleted): it can no longer self-drain, so flag it. Skipped for a
# targeted [files...] run, which legitimately covers only a subset.
if [ "$full_run" -eq 1 ]; then
  for k in $known; do
    case " $seen_known " in
      *" $k "*) ;;
      *) fail=$((fail + 1)); printf 'FAIL %s — ledgered in test/fmt_roundtrip_known_divergence.txt but not present in the corpus (stale entry; remove it)\n' "$k" ;;
    esac
  done
fi

printf 'checked %d files\n' "$n"
if [ "$n" -eq 0 ]; then
  echo "NOTHING COMPARED — the corpus globs matched zero files (this is not a pass)"
  exit 1
fi
if [ "$kdiv" -gt 0 ]; then
  printf '%d known-divergence(s):%s\n' "$kdiv" "$kdiv_names"
fi
printf '%d matched, %d ledgered divergence(s), %d unexpected failure(s)\n' \
  "$pass" "$kdiv" "$fail"
[ "$fail" -eq 0 ]
