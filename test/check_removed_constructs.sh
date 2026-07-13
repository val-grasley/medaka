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

NCPU="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
JOBS="${JOBS:-$NCPU}"

# ── Deliberate exceptions ───────────────────────────────────────────────────
# Fixtures that intentionally use a removed construct to verify the
# compiler's OWN removal diagnostic (message text / caret location). Keep
# this list SMALL; every entry must say why. One path per line.
is_allowlisted() {
  case "$1" in
    test/run_check_agreement_fixtures/p0_5_let_mut_removed.mdk) return 0 ;; # verifies letMutRemovedMsg fires + its exact wording (P0-5 regression fixture; .expected pins the output)
    test/parse_error_loc_fixtures/backtick_infix.mdk) return 0 ;;           # verifies the backtick-removal diagnostic's caret location (test/diff_compiler_parse_error_loc.sh)
    *) return 1 ;;
  esac
}

# ── Worker mode: classify one file, print one result line ──────────────────
if [ "${1:-}" = "--check-one" ]; then
  f="$2"
  if is_allowlisted "$f"; then
    printf 'ALLOWLISTED\t%s\t-\n' "$f"
    exit 0
  fi
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
  for a in "$@"; do
    case "$a" in
      "$ROOT"/*) rel="${a#"$ROOT"/}" ;;
      /*) rel="$a" ;;
      *) rel="$a" ;;
    esac
    printf '%s\n' "$rel"
  done > "$WORK/files.txt"
else
  (cd "$ROOT" && git ls-files '*.mdk') > "$WORK/files.txt"
fi

total=$(wc -l < "$WORK/files.txt" | tr -d ' ')

xargs -P "$JOBS" -n 1 -I{} sh "$0" --check-one {} < "$WORK/files.txt" > "$WORK/all.txt" 2>/dev/null

tier1=$(grep -c '^TIER1	' "$WORK/all.txt" 2>/dev/null); tier1="${tier1:-0}"
tier2=$(grep -c '^TIER2	' "$WORK/all.txt" 2>/dev/null); tier2="${tier2:-0}"
allow=$(grep -c '^ALLOWLISTED	' "$WORK/all.txt" 2>/dev/null); allow="${allow:-0}"
findings=$((tier1 + tier2))

if [ "$JSON_MODE" = "1" ]; then
  printf '{"total":%s,"allowlisted":%s,"findings":%s,"hits":[' "$total" "$allow" "$findings"
  first=1
  grep -E '^TIER1	|^TIER2	' "$WORK/all.txt" 2>/dev/null | while IFS="$(printf '\t')" read -r tier f key rest; do
    [ "$first" = 1 ] || printf ','
    printf '{"tier":"%s","file":"%s","construct":"%s","detail":"%s"}' "$tier" "$f" "$key" "$rest"
    first=0
  done
  printf ']}\n'
else
  echo "check_removed_constructs: scanned $total file(s), $allow allowlisted, $findings finding(s)"
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
fi

[ "$findings" -eq 0 ]
