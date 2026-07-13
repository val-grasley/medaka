#!/bin/sh
# test/gen_docs_index.sh — generate docs/README.md from every doc's H1 + Status
# banner. Run via `make docs-index`.
#
# WHY THIS EXISTS: a hand-maintained doc index is exactly what rotted before
# the docs-tree reorg — AGENTS.md's own doc-index table mislabeled
# ARGSTAMP-UNIFY-PLAN.md as "IN PROGRESS" when the doc's own banner said
# COMPLETE, and nothing caught it. This script reads the SAME status banners
# `test/check_doc_links.sh`'s corpus already carries and derives the index
# from them, so the index cannot drift from what each doc says about itself.
#
# docs/README.md is GENERATED — never hand-edit it. Re-run this script
# (`make docs-index`) after moving/adding/renaming a doc; it is idempotent
# (same input -> byte-identical output), so a clean re-run is always a no-op.
#
# Groups (fixed order, matches the docs-tree layout):
#   spec / guide / design / ops / stdlib / compiler internals / archive
#
# Portable POSIX sh + awk. No bash-isms (mirrors check_doc_links.sh — safe on
# both the Linux dev box and macOS smoke-testing, and under dash).

set -eu

# Some doc paths contain spaces (docs/guide/*). Split file lists on newline
# only, never space/tab, so `for f in $FILES` below doesn't shatter those
# paths into extra words.
IFS='
'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="docs/README.md"

# ---------------------------------------------------------------------------
# extract_row FILE — prints "FILE\tH1\tSTATUS" (tab-separated, one line).
# H1: text of the first line matching ^# , prefix stripped.
# STATUS: text after the first "**Status:**" marker, cut at the first
# " — " (em dash) or ". " (sentence end) or 100 chars, whichever comes
# first; "—" (no banner) if the doc has none.
# ---------------------------------------------------------------------------
extract_row() {
  f="$1"
  awk '
    BEGIN { h1 = ""; status = "" }
    h1 == "" && /^# / {
      h1 = $0
      sub(/^# +/, "", h1)
    }
    status == "" && /^\*\*Status:\*\*/ {
      status = $0
      sub(/^\*\*Status:\*\*[ \t]*/, "", status)
    }
    END {
      if (h1 == "") h1 = "(no H1)"
      if (status == "") {
        status = "\xe2\x80\x94"
      } else {
        # Cut at the EARLIEST of: " (" (open paren — avoids an unbalanced
        # trailing paren), " — " (em dash), ". " (sentence end), all only if
        # they occur before char 100; else hard-cut at 100.
        emdash = "\xe2\x80\x94"
        best = 0
        c = index(status, " (");            if (c > 0 && c < 100 && (best == 0 || c < best)) best = c
        c = index(status, " " emdash " ");  if (c > 0 && c < 100 && (best == 0 || c < best)) best = c
        c = index(status, ". ");            if (c > 0 && c < 100 && (best == 0 || c < best)) best = c
        if (best > 0) {
          status = substr(status, 1, best - 1)
        } else if (length(status) > 100) {
          status = substr(status, 1, 100) "..."
        }
      }
      gsub(/\t/, " ", h1)
      gsub(/\t/, " ", status)
      print h1 "\t" status
    }
  ' "$f"
}

# ---------------------------------------------------------------------------
# doc_link ROOT_RELATIVE_PATH — prints the path AS A LINK TARGET FROM
# docs/README.md's own directory (docs/). A root-relative "docs/spec/X.md"
# becomes "spec/X.md"; anything else ("compiler/X.md", "archive/X.md") gets
# a "../" prefix.
# ---------------------------------------------------------------------------
doc_link() {
  case "$1" in
    docs/*) printf '%s' "${1#docs/}" ;;
    *)      printf '../%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# emit_group TITLE BLURB FILE...  — prints a "### TITLE" section + table.
# FILE list must already be sorted; each path is root-relative.
# ---------------------------------------------------------------------------
emit_group() {
  title="$1"; blurb="$2"; shift 2
  printf '### %s\n\n' "$title"
  [ -n "$blurb" ] && printf '%s\n\n' "$blurb"
  printf '| Doc | What it is | Status |\n'
  printf '|-----|------------|--------|\n'
  for f in "$@"; do
    row="$(extract_row "$f")"
    h1="${row%%	*}"
    status="${row#*	}"
    printf '| [`%s`](%s) | %s | %s |\n' "$(basename "$f")" "$(doc_link "$f")" "$h1" "$status"
  done
  printf '\n'
}

# ---------------------------------------------------------------------------
# Collect file lists (sorted, deterministic).
# ---------------------------------------------------------------------------
SPEC_FILES="$(find docs/spec -maxdepth 1 -name '*.md' | sort)"
GUIDE_FILES="$(find docs/guide -maxdepth 1 -name '*.md' | sort)"
DESIGN_FILES="$(find docs/design -maxdepth 1 -name '*.md' | sort)"
OPS_FILES="$(find docs/ops -maxdepth 1 -name '*.md' | sort)"
STDLIB_FILES="$(find docs/stdlib -maxdepth 1 -name '*.md' | sort)"
COMPILER_FILES="$(find compiler -maxdepth 1 -name '*.md' | sort)"
ARCHIVE_FLAT_FILES="$(find archive -maxdepth 1 -name '*.md' ! -name 'README.md' | sort)"
ARCHIVE_DESIGN_FILES="$(find archive/design -maxdepth 1 -name '*.md' | sort)"
ARCHIVE_FINDINGS_FILES="$(find archive/findings -name '*.md' | sort)"

# ---------------------------------------------------------------------------
# Write docs/README.md.
# ---------------------------------------------------------------------------
{
  cat <<'HEADER'
# Docs index

<!-- GENERATED — do not edit by hand; run `make docs-index`
     (test/gen_docs_index.sh). Regenerating after a doc move/add/rename is a
     no-op if nothing changed: same input -> byte-identical output. -->

Fast lookup for an agent (or human) trying to find the right doc. Each row
leads with the doc, then a one-line summary and its current status (pulled
straight from the doc's own `**Status:**` banner — this table cannot drift
from what the doc says about itself). **PARTIAL/OPEN work is live; a doc
under `archive/` is IMPLEMENTED/SUPERSEDED and kept for provenance, not
current guidance.**

Root entry points (not indexed below — always here): [`README.md`](../README.md)
(build/test/CLI), [`AGENTS.md`](../AGENTS.md) (agent orientation, router),
[`PLAN.md`](../PLAN.md) (open roadmap), [`HANDOFF.md`](../HANDOFF.md)
(start-here snapshot — its own banner flags it partly stale; treat as a
pointer to `docs/ops/DISTRIBUTION-DESIGN.md` / `docs/ops/RELEASE-0.1.0-PLAN.md`
for current status, not as live guidance itself).

HEADER

  emit_group "spec — language ground truth" \
    "What parses, what it means, formal semantics. Read here first for \"does X exist / what does X mean\"." \
    $SPEC_FILES

  emit_group "guide — learning path" \
    "Tutorial-style onboarding, not a spec. Not yet cross-linked into this index's status convention (no banners) — this is prose-in-progress, read for teaching order, not ground truth." \
    $GUIDE_FILES

  emit_group "design — open/partial work" \
    "Live design docs: **OPEN** = not started, **PARTIAL** = in progress. Read before touching the area; update the doc when you close it (then it moves to \`archive/design/\`)." \
    $DESIGN_FILES

  emit_group "ops — release, testing, distribution" \
    "Cross-cutting process docs: how the test suite is organized, how a build ships, what's left before 0.1.0." \
    $OPS_FILES

  emit_group "stdlib — library plan" \
    "What's in the standard library, what's planned, module-by-module status." \
    $STDLIB_FILES

  emit_group "compiler internals — stay in compiler/, indexed here for findability" \
    "47 docs live next to the code they describe (compiler/*.md) and are NOT moved by the docs-tree reorg. Listed here so they're still one search away." \
    $COMPILER_FILES

  printf '### archive — closed / historical\n\n'
  printf 'IMPLEMENTED or SUPERSEDED work, kept for provenance. Links inside these docs are NOT rewritten when they narrate a past tree (flat files below + `PLAN-ARCHIVE.md`); `design/` and `findings/` are current archived docs whose links ARE kept live. See [`archive/README.md`](../archive/README.md) for the layout explanation.\n\n'

  emit_group "archive/design — shipped design docs" "" $ARCHIVE_DESIGN_FILES
  emit_group "archive/findings — point-in-time QA/investigation sweeps" "" $ARCHIVE_FINDINGS_FILES
  emit_group "archive/ (flat) — closed conformance audits/roadmaps + the Phase archive" "" $ARCHIVE_FLAT_FILES
} > "$OUT"

echo "wrote $OUT"
