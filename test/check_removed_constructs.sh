#!/bin/sh
# check_removed_constructs.sh — tree-wide gate for STALE uses of language
# constructs REMOVED from Medaka's surface syntax (roadmap item #24). Covers
# the WHOLE git-tracked *.mdk tree, including test/ fixtures — the fmt/lint
# pre-commit hook deliberately excludes test/, so a removed construct can rot
# there unnoticed (this is exactly how test/construct_fixtures/let_else.mdk
# went stale — its golden still records the OLD passing output; see report).
#
# Removed constructs covered:
#   1. the `record` keyword                (data X = { … } replaces it)
#   2. the `function` keyword              (point-free match)
#   3. backtick infix application          (`` `f` ``)
#   4. `let mut`                           (bindings are immutable; use `Ref`)
#   5. `let-else`                          (`let PAT = EXPR else DEFAULT`)
#   6. named impls                         (`impl name of Iface`)
#   7. `default impl` / `@Name` impl-hints (multi-instance selection, removed
#      together with named impls — commit f2e1f859)
#
# ── WHY THIS SHAPE (read before "simplifying") ──────────────────────────────
#
# `medaka lint` is NOT viable: it walks the post-parse AST, but every one of
# the 7 constructs above no longer parses at all (verified empirically, one
# fixture per construct). A lint Rule never gets a chance to see one — the
# file dies at parse first. Worse, `medaka lint` does not degrade gracefully
# on a parse error: it PANICS (`runtime error [E-PANIC]: parse error`)
# instead of emitting a diagnostic, so there is no post-parse hook to add a
# rule to.
#
# `medaka check --json <file>` DOES handle a parse failure gracefully (the
# diagnostics-accumulator design — AGENTS.md "Errors accumulate"), and for 6
# of the 7 constructs the PARSER ITSELF already carries a dedicated, located
# "has been removed" / "is not a keyword" / "is not supported" diagnostic
# (grep compiler/frontend/parser.mdk for letMutRemovedMsg / recordRemovedMsg
# / functionRemovedMsg / backtickInfixMsg / defaultImplRemovedMsg /
# namedImplRemovedMsg). These strings are precise BY CONSTRUCTION — the
# parser only ever emits them when that exact removed construct is used, so
# substring-matching the `--json` diagnostic message has ZERO false-positive
# risk. This is TIER 1, and it is the sole mechanism for 6 of the 7
# constructs.
#
# The 7th, `let-else`, has NO dedicated parser diagnostic — it fails with a
# GENERIC message ("unexpected `else`; expected a dedent") that unrelated
# broken code can also produce (verified: a bare stray `else` typo with no
# `let` anywhere on the line produces the identical message). A raw
# source-text regex is even LESS reliable on its own for the other
# constructs — a naive backtick regex false-positives inside Markdown-style
# code-span comments (verified: dozens of files in this tree match one,
# purely from doc-comment code spans), and a naive `else` regex
# false-positives on legitimate `let x = if c then a else b`. So TIER 2
# below is a narrow, line-level heuristic applied ONLY to files that ALREADY
# failed to parse with an unclassified error — it can only ever LABEL an
# existing failure, never manufacture a new one — keyed on the literal
# surface form `let PAT = EXPR else DEFAULT` (a line containing `else` but no
# `then`; if-then-else always pairs with `then`, `let-else` never did).
#
# `@Name` impl-hints are grouped with named impls in the original removal
# (commit f2e1f859 removed "named-impl + @Name selection + default-impl" as
# one unit): a stale `@Name` almost always accompanies a stale named-impl
# declaration in the same file, which Tier 1 already catches directly. As a
# second Tier-2 heuristic (same "only labels an already-broken file"
# discipline) this gate also flags a bare ` @Upper`/` @lower` token in
# expression position — excluding glued `x@pat` as-patterns (still legal)
# and line-leading `@attrib` declarations (still legal).
#
# Usage:  sh test/check_removed_constructs.sh [--json] [file.mdk ...]
# Exit:   0 if no findings (outside the documented ALLOWLIST below), else 1.
#         2 if ./medaka isn't built yet.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
LEDGER="$ROOT/test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt"

NCPU="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
JOBS="${JOBS:-$NCPU}"

# ── Worker mode: classify one file, print one result line ──────────────────
# NOTE: every file is actually run through `medaka check --json`, including
# files with a ledger entry below — there is no early-exit "allowlisted"
# shortcut. That's deliberate: a ledger entry pins an EXPECTED finding, and
# the only way to notice that finding has stopped happening (fixture
# deleted, diagnostic accidentally fixed) is to keep checking it every run.
if [ "${1:-}" = "--check-one" ]; then
  f="$2"
  case "$f" in
    /*) abs="$f" ;;
    *) abs="$ROOT/$f" ;;
  esac
  json="$("$MEDAKA" check --json "$abs" 2>/dev/null)"

  case "$json" in
    *'`let mut` has been removed'*) printf 'TIER1\t%s\tlet_mut\n' "$f"; exit 0 ;;
    *'`record` is not a keyword'*) printf 'TIER1\t%s\trecord_keyword\n' "$f"; exit 0 ;;
    *'`function` is not a keyword'*) printf 'TIER1\t%s\tfunction_keyword\n' "$f"; exit 0 ;;
    *'backtick infix application'*) printf 'TIER1\t%s\tbacktick_infix\n' "$f"; exit 0 ;;
    *'`default impl` has been removed'*) printf 'TIER1\t%s\tdefault_impl\n' "$f"; exit 0 ;;
    *'named impls (`impl name of Iface`) have been removed'*) printf 'TIER1\t%s\tnamed_impl\n' "$f"; exit 0 ;;
  esac

  # Tier 2 only fires if this file already has an unclassified parse error —
  # it never turns a clean file into a finding.
  case "$json" in
    *'"code":"P-PARSE"'*)
      src="$abs"
      letelse_line=$(awk '
        /^[[:space:]]*let[[:space:]]/ {
          if ($0 ~ /[[:space:]]else([[:space:]]|$)/ && $0 !~ /[[:space:]]then([[:space:]]|$)/) {
            print NR; exit
          }
        }
      ' "$src" 2>/dev/null)
      if [ -n "$letelse_line" ]; then
        printf 'TIER2\t%s\tlet_else\tline %s\n' "$f" "$letelse_line"
        exit 0
      fi
      atname_line=$(awk '
        {
          line = $0
          c = index(line, "--")
          if (c > 0) line = substr(line, 1, c - 1)
          if (match(line, /[^[:space:]][[:space:]]+@[A-Za-z_][A-Za-z0-9_]*/)) {
            print NR; exit
          }
        }
      ' "$src" 2>/dev/null)
      if [ -n "$atname_line" ]; then
        printf 'TIER2\t%s\tat_name_hint\tline %s\n' "$f" "$atname_line"
        exit 0
      fi
      ;;
  esac
  printf 'CLEAN\t%s\t-\n' "$f"
  exit 0
fi

# ── Driver mode ──────────────────────────────────────────────────────────
JSON_MODE=0
if [ "${1:-}" = "--json" ]; then
  JSON_MODE=1
  shift
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$#" -gt 0 ]; then
  full_run=0
  for a in "$@"; do
    case "$a" in
      "$ROOT"/*) rel="${a#"$ROOT"/}" ;;
      /*) rel="$a" ;;
      *) rel="$a" ;;
    esac
    printf '%s\n' "$rel"
  done > "$WORK/files.txt"
else
  full_run=1
  (cd "$ROOT" && git ls-files '*.mdk') > "$WORK/files.txt"
fi

total=$(wc -l < "$WORK/files.txt" | tr -d ' ')

xargs -P "$JOBS" -n 1 -I{} sh "$0" --check-one {} < "$WORK/files.txt" > "$WORK/all.txt" 2>/dev/null

tier1=$(grep -c '^TIER1	' "$WORK/all.txt" 2>/dev/null); tier1="${tier1:-0}"
tier2=$(grep -c '^TIER2	' "$WORK/all.txt" 2>/dev/null); tier2="${tier2:-0}"
findings=$((tier1 + tier2))

# ── Ledger diff (the whole point of this gate) ──────────────────────────────
# actual   = the (path, construct) pairs really found scanning the tree
# ledger   = the (path, construct) pairs test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt
#            EXPECTS to find (comments/blanks stripped)
# unexpected = actual - ledger  -> a NEW use of a removed construct: FAIL
# stale      = ledger - actual  -> a ledgered fixture that no longer produces
#                                   its expected finding (deleted, or the
#                                   diagnostic got accidentally fixed): FAIL.
#                                   This is the direction a skip-list cannot see.
#
# "stale" is only meaningful against the WHOLE tracked tree: on a targeted
# (file-args) run, every ledger entry whose fixture wasn't among the named
# files would look "stale" even though it's untouched — a false failure about
# a file the caller never named (#537's defect, same shape). So the stale
# check runs ONLY on a full (no-arguments) scan; a targeted run still catches
# real "unexpected" findings in the files it actually looked at.
grep -E '^TIER1	|^TIER2	' "$WORK/all.txt" 2>/dev/null \
  | awk -F'\t' '{print $2"\t"$3}' | sort -u > "$WORK/actual.txt"
awk -F'\t' '!/^[[:space:]]*#/ && NF>=2 && $1!="" {print $1"\t"$2}' "$LEDGER" \
  | sort -u > "$WORK/ledger.txt"
comm -23 "$WORK/actual.txt" "$WORK/ledger.txt" > "$WORK/unexpected.txt"
if [ "$full_run" -eq 1 ]; then
  comm -13 "$WORK/actual.txt" "$WORK/ledger.txt" > "$WORK/stale.txt"
else
  : > "$WORK/stale.txt"
fi

unexpected=$(wc -l < "$WORK/unexpected.txt" | tr -d ' ')
stale=$(wc -l < "$WORK/stale.txt" | tr -d ' ')
ledger_total=$(wc -l < "$WORK/ledger.txt" | tr -d ' ')

if [ "$JSON_MODE" = "1" ]; then
  printf '{"total":%s,"findings":%s,"ledger_total":%s,"unexpected":%s,"stale":%s,"hits":[' \
    "$total" "$findings" "$ledger_total" "$unexpected" "$stale"
  first=1
  grep -E '^TIER1	|^TIER2	' "$WORK/all.txt" 2>/dev/null | while IFS="$(printf '\t')" read -r tier f key rest; do
    [ "$first" = 1 ] || printf ','
    printf '{"tier":"%s","file":"%s","construct":"%s","detail":"%s"}' "$tier" "$f" "$key" "$rest"
    first=0
  done
  printf '],"unexpected_hits":['
  first=1
  while IFS="$(printf '\t')" read -r f key; do
    [ -z "$f" ] && continue
    [ "$first" = 1 ] || printf ','
    printf '{"file":"%s","construct":"%s"}' "$f" "$key"
    first=0
  done < "$WORK/unexpected.txt"
  printf '],"stale_ledger_entries":['
  first=1
  while IFS="$(printf '\t')" read -r f key; do
    [ -z "$f" ] && continue
    [ "$first" = 1 ] || printf ','
    printf '{"file":"%s","construct":"%s"}' "$f" "$key"
    first=0
  done < "$WORK/stale.txt"
  printf ']}\n'
else
  echo "check_removed_constructs: scanned $total file(s), $findings finding(s), $ledger_total ledger entries"
  echo
  echo "LEDGER (expected findings — test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt, printed every run):"
  if [ "$ledger_total" -gt 0 ]; then
    awk -F'\t' '!/^[[:space:]]*#/ && NF>=2 && $1!="" {printf "  %-16s %s  -- %s\n", $2, $1, $3}' "$LEDGER"
  else
    echo "  (empty)"
  fi

  if [ "$findings" -gt 0 ]; then
    echo
    echo "TIER 1 (dedicated parser diagnostic — precise):"
    grep '^TIER1	' "$WORK/all.txt" 2>/dev/null | while IFS="$(printf '\t')" read -r _ f key; do
      printf '  %-16s %s\n' "$key" "$f"
    done
    echo
    echo "TIER 2 (heuristic label on an already-unparseable file):"
    grep '^TIER2	' "$WORK/all.txt" 2>/dev/null | while IFS="$(printf '\t')" read -r _ f key detail; do
      printf '  %-16s %s (%s)\n' "$key" "$f" "$detail"
    done
  fi

  if [ "$unexpected" -gt 0 ]; then
    echo
    echo "UNEXPECTED (actual finding NOT in the ledger — a real regression; fix it, or"
    echo "if it's a deliberate removal-diagnostic fixture, add it to"
    echo "test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt with a reason):"
    while IFS="$(printf '\t')" read -r f key; do
      [ -z "$f" ] && continue
      printf '  %-16s %s\n' "$key" "$f"
    done < "$WORK/unexpected.txt"
  fi

  if [ "$stale" -gt 0 ]; then
    echo
    echo "STALE LEDGER ENTRIES (ledgered but NOT an actual finding — the fixture was"
    echo "deleted or the diagnostic got fixed; remove the entry from"
    echo "test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt):"
    while IFS="$(printf '\t')" read -r f key; do
      [ -z "$f" ] && continue
      printf '  %-16s %s\n' "$key" "$f"
    done < "$WORK/stale.txt"
  fi
fi

[ "$unexpected" -eq 0 ] && [ "$stale" -eq 0 ]
