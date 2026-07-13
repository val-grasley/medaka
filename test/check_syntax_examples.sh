#!/bin/sh
# check_syntax_examples.sh — turns SYNTAX.md from a claim into a tested artifact.
#
# SYNTAX.md is documented (AGENTS.md) as "every construct the current binary
# accepts... one minimal example each", but nothing ever checked that. This
# gate extracts every fenced code example and runs it through `medaka check`,
# so a stale/wrong example fails CI instead of silently rotting.
#
# Fence-tagging convention (the info string right after the opening ```):
#   ```medaka             a COMPLETE, self-contained, checkable file. Checked
#                          verbatim with `medaka check`.
#   ```medaka-project     a multi-file example. Content is split on lines of
#                          the exact form `-- file: NAME.mdk` into that many
#                          files inside one synthetic project (with a
#                          generated medaka.toml); every file matching
#                          `main*.mdk` is checked as an entry point.
#   ```medaka-nocheck: reason
#                          genuinely not checkable as a standalone example
#                          (a bare grammar fragment / type-signature-only
#                          illustration). SKIPPED, but the reason is printed
#                          so a skip is visible, not silent. As of this
#                          writing SYNTAX.md uses none of these — every
#                          example was made checkable instead.
#   ```  / ```sh / ...    anything else (plain fence, `sh`, prose) is not a
#                          Medaka example and is ignored.
#
# A block with NO exact closing ``` fence would leave `in_block` set at EOF;
# that block is silently dropped rather than mis-checked. This has not
# happened in practice (every block in SYNTAX.md is well-formed) but is
# documented here in case a future edit introduces one — grep this file's
# own SYNTAX.md-adjacent fence count against the checked/skipped total if
# that is ever suspected.
#
# MUST NOT SILENTLY NO-OP: if zero examples are found/checked, that is a
# FAILURE (exit 1), not a quiet pass — see the `checked -eq 0` guard below.
#
# Usage: sh test/check_syntax_examples.sh
# Exit:  0 if every checked example passed (and at least one was checked)
#        1 otherwise (including "found nothing to check" and "binary missing")

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
DOC="$ROOT/SYNTAX.md"

if [ ! -x "$MEDAKA" ]; then
  echo "check_syntax_examples: native binary not found/executable at $MEDAKA" >&2
  echo "check_syntax_examples: build it first (make medaka) — refusing to skip-and-exit-0" >&2
  exit 1
fi

if [ ! -f "$DOC" ]; then
  echo "check_syntax_examples: SYNTAX.md not found at $DOC" >&2
  exit 1
fi

WORK="$(mktemp -d)" || { echo "check_syntax_examples: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

FENCE='```'

checked=0
failed=0
skipped=0
fail_report=""

# ── check one self-contained ```medaka block ────────────────────────────────
check_medaka_block() {
  f="$1"
  ln="$2"
  checked=$((checked + 1))
  out="$("$MEDAKA" check "$f" --json 2>&1)"
  rc=$?
  errs=$(printf '%s\n' "$out" | grep -c '"severity":1')
  if [ "$rc" -ne 0 ] || [ "$errs" -gt 0 ]; then
    failed=$((failed + 1))
    fail_report="$fail_report
=== FAIL: SYNTAX.md:$ln (medaka block) ===
$out"
  fi
}

# ── check one ```medaka-project (multi-file) block ─────────────────────────
check_project_block() {
  f="$1"
  ln="$2"
  pdir="$WORK/proj_$ln"
  mkdir -p "$pdir"
  printf '[project]\nname = "syntax_check_%s"\n' "$ln" > "$pdir/medaka.toml"

  cur=""
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      "-- file: "*)
        cur="${l#-- file: }"
        : > "$pdir/$cur"
        ;;
      *)
        if [ -n "$cur" ]; then
          printf '%s\n' "$l" >> "$pdir/$cur"
        fi
        ;;
    esac
  done < "$f"

  any_main=0
  for mf in "$pdir"/main*.mdk; do
    [ -e "$mf" ] || continue
    any_main=1
    checked=$((checked + 1))
    out="$("$MEDAKA" check "$mf" --json 2>&1)"
    rc=$?
    errs=$(printf '%s\n' "$out" | grep -c '"severity":1')
    if [ "$rc" -ne 0 ] || [ "$errs" -gt 0 ]; then
      failed=$((failed + 1))
      fail_report="$fail_report
=== FAIL: SYNTAX.md:$ln (medaka-project, entry $(basename "$mf")) ===
$out"
    fi
  done
  if [ "$any_main" -eq 0 ]; then
    failed=$((failed + 1))
    fail_report="$fail_report
=== FAIL: SYNTAX.md:$ln (medaka-project has no main*.mdk entry point) ==="
  fi
}

blockfile="$WORK/block.mdk"
in_block=0
tag=""
block_start=0
lineno=0

while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  if [ "$in_block" -eq 0 ]; then
    case "$line" in
      ${FENCE}medaka-nocheck*)
        reason="$(printf '%s\n' "$line" | sed 's/^```medaka-nocheck[: ]*//')"
        echo "SKIPPED (nocheck) SYNTAX.md:$lineno: ${reason:-no reason given}"
        skipped=$((skipped + 1))
        in_block=1
        tag="nocheck"
        ;;
      ${FENCE}medaka-project)
        in_block=1
        tag="project"
        block_start=$lineno
        : > "$blockfile"
        ;;
      ${FENCE}medaka)
        in_block=1
        tag="medaka"
        block_start=$lineno
        : > "$blockfile"
        ;;
      *)
        ;;
    esac
  else
    if [ "$line" = "$FENCE" ]; then
      in_block=0
      case "$tag" in
        medaka) check_medaka_block "$blockfile" "$block_start" ;;
        project) check_project_block "$blockfile" "$block_start" ;;
        nocheck) ;;
      esac
      tag=""
    else
      if [ "$tag" != "nocheck" ]; then
        printf '%s\n' "$line" >> "$blockfile"
      fi
    fi
  fi
done < "$DOC"

echo "---"
echo "checked $checked examples ($skipped skipped, $failed failed)"

if [ -n "$fail_report" ]; then
  printf '%s\n' "$fail_report"
fi

if [ "$checked" -eq 0 ]; then
  echo "check_syntax_examples: FAILURE — checked 0 examples; a gate that runs nothing must never report green" >&2
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  echo "check_syntax_examples: FAILED ($failed/$checked)" >&2
  exit 1
fi

echo "check_syntax_examples: PASSED ($checked/$checked)"
exit 0
