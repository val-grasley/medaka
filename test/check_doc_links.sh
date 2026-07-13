#!/bin/sh
# test/check_doc_links.sh — doc-link rot gate.
#
# WHY THIS EXISTS: the compiler was restructured into subfolders
# (compiler/typecheck.mdk -> compiler/types/typecheck.mdk,
# compiler/llvm_emit.mdk -> compiler/backend/llvm_emit.mdk, etc.) and NOTHING
# NOTICED that it broke the docs. A repo-wide sweep found 42 of 128 distinct
# compiler/*.mdk paths cited across this repo's markdown were DEAD — a
# third. Some are paths the docs instruct an agent to *run*. Docs also link
# to each other, and those links rot the same way. This gate makes that rot
# LOUD instead of silent.
#
# WHAT IT CHECKS (pure text analysis — no compiler build, no toolchain, safe
# to run anywhere, always):
#   1. Relative markdown links: [text](some/path.md) / (some/path.md#anchor).
#      Resolved relative to the CITING file's own directory (the actual
#      markdown-link semantics), except a leading "/" which is root-relative.
#      http(s):// / mailto: / bare "#anchor" targets are ignored (nothing to
#      resolve on disk). A trailing ":NNN" pseudo-anchor (this repo's
#      informal "see file.mdk:1175" convention, e.g. compiler/STAGE2-DESIGN.md)
#      is stripped like a fragment before checking.
#   2. Bare cited source paths in prose/backticks: compiler/… stdlib/… test/…
#      runtime/… playground/… with a real extension (.mdk .sh .c .md .txt
#      .toml .yml). These are cited ROOT-relative by convention throughout
#      this repo (verified by inspection — e.g. AGENTS.md cites
#      "compiler/backend/llvm_emit.mdk" from the repo root regardless of
#      which doc is doing the citing).
#
# Both checks are text-only against the CURRENT source tree — a dead
# reference means the file genuinely does not exist on disk right now.
#
# THE EXCEPTIONS FILE IS A RATCHET, NOT A SKIP-LIST (test/DOC-LINK-EXCEPTIONS.txt):
# some dead references are legitimate HISTORY (PLAN-ARCHIVE.md, archive/**,
# bootstrap logs narrating a past where compiler/typecheck.mdk genuinely
# existed) and must be allowed. But an exceptions file that never gets
# checked itself just becomes a landfill (see test/CAPABILITY-EXCEPTIONS.txt's
# "accidental fix" principle, and how test/ported/ + diff_compiler_lint_multi
# sat silently skipped-and-failing for months). So:
#   - a REF exception (a specific dead target path) that NOW EXISTS on disk
#     is a FAILURE: the maintainer must delete that line.
#   - a FILE exception naming one exact citing file that NO LONGER EXISTS is
#     a FAILURE for the same reason (mirrors
#     diff_compiler_ci_shard_coverage.sh's "ledger names a gate that doesn't
#     exist" check).
#
# NEVER SILENTLY NO-OP: this gate prints how many references it checked, and
# checking ZERO references is a FAILURE (exit 1), not a quiet pass — exactly
# the "0 failed on a fresh clone" bug class this repo has been bitten by
# before (a bash-only gate that dash couldn't parse; an empty fixture glob).
# Run BOTH `sh` and `dash` explicitly against this script — dash is what
# /bin/sh actually is on this box, and a previous gate here sat "skipped"
# for months because it silently only ever ran under bash.
#
# Usage:  sh test/check_doc_links.sh
# Exit:   0 every reference resolves (modulo test/DOC-LINK-EXCEPTIONS.txt);
#         1 a dead reference with no exception, a stale exception, or zero
#           references checked (harness bug).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXC="$ROOT/test/DOC-LINK-EXCEPTIONS.txt"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v git >/dev/null 2>&1 || { echo "FAIL: git not found (needed to enumerate tracked markdown files)"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FAIL: awk not found"; exit 2; }

# ── 1. Enumerate every tracked markdown file. ───────────────────────────────
# git ls-files (not `find`) so gitignored/generated trees (playground/dist,
# node_modules, …) never enter the corpus, and so filenames containing
# spaces (yes, this repo has them: docs/guide/"0. Introduction.md") come
# through as whole lines, not word-split.
#
# test/snapshots/** is EXCLUDED: it is the diff_compiler_snapshot_frontend.sh
# golden corpus — literal `.mdk` SOURCE dumped verbatim inside a "# SOURCE"
# fenced section per file (see AGENTS.md's snapshot-check target), not prose
# documentation. It is a real hazard for this gate specifically: single
# lines up to 15KB, at repo-wide-source-code density of `[`/`]`/`(`/`)`, which
# turned the tier-1/tier-2 extraction loops' substr-and-continue scan
# quadratic on THAT corpus alone (2+ CPU-minutes measured, still climbing,
# on a single 15KB line) — a real, reproduced hang, not a hypothetical.
git ls-files '*.md' ':!:test/snapshots/**' > "$WORK/md_files.txt"

if [ ! -s "$WORK/md_files.txt" ]; then
  echo "FAIL: git ls-files '*.md' found NOTHING (harness bug — wrong cwd, or repo has no markdown)"
  exit 1
fi

# ── 2. Extract every reference (link + bare cited path) from every file. ────
# One pass, in awk, reading filenames from md_files.txt via getline (NOT as
# ARGV — filenames with spaces would word-split there). Output TSV:
#   citing_file <TAB> line <TAB> kind <TAB> raw_target <TAB> resolved_path
# resolved_path is always relative to $ROOT, normalized (./ and ../ collapsed).
awk -v LISTFILE="$WORK/md_files.txt" '
function dirnameOf(p,    n, parts, i, res) {
  n = split(p, parts, "/")
  if (n <= 1) return "."
  res = parts[1]
  for (i = 2; i < n; i++) res = res "/" parts[i]
  return res
}

function normalize(p,    n, parts, out, oi, i, res) {
  n = split(p, parts, "/")
  oi = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") {
      if (oi > 0 && out[oi] != "..") { oi--; } else { out[++oi] = ".."; }
    } else {
      out[++oi] = parts[i]
    }
  }
  res = ""
  for (i = 1; i <= oi; i++) res = (res == "" ? out[i] : res "/" out[i])
  return res
}

function emit(fname, lineno, kind, target, resolved) {
  printf "%s\t%d\t%s\t%s\t%s\n", fname, lineno, kind, target, normalize(resolved)
}

function handleLink(fname, lineno, target,    frag, dir) {
  if (target ~ /^https?:\/\//) return
  if (target ~ /^mailto:/) return
  if (target ~ /^#/) return
  # A raw SPACE in a link target means this is not a link. Markdown requires a
  # space to be %20-escaped or the target wrapped in <>, so a "](...)" span with
  # a bare space is prose that merely LOOKS like a link — in this repo that is
  # the math notation in DICT-SEMANTICS.md (two spans, both with a space). Excusing
  # those in the exceptions file would be excusing a PARSING BUG; drop them here
  # instead. (Verified against the corpus: these two spans are the ONLY
  # space-bearing link targets, and nothing links to the three space-named
  # docs/guide/ files, so this exclusion loses no real reference.)
  if (target ~ /[ \t]/) return
  # An ellipsis-elided path ("compiler/.../resolve.mdk") is prose shorthand for
  # "somewhere under compiler/", not a citation of a real file. Same reasoning.
  if (target ~ /\.\.\./) return
  frag = index(target, "#")
  if (frag > 0) target = substr(target, 1, frag - 1)
  if (match(target, /:[0-9]+$/)) target = substr(target, 1, RSTART - 1)
  if (target == "") return
  if (target ~ /^\//) {
    emit(fname, lineno, "LINK", target, substr(target, 2))
  } else {
    dir = dirnameOf(fname)
    emit(fname, lineno, "LINK", target, (dir == "." ? target : dir "/" target))
  }
}

function handleBare(fname, lineno, target) {
  # Same ellipsis rule as handleLink: "compiler/.../resolve.mdk" is prose.
  if (target ~ /\.\.\./) return
  emit(fname, lineno, "BARE", target, target)
}

function processLine(fname, lineno, line,    work, target, scrub, work2, mstart, mlen) {
  # ---- tier 1: relative markdown links ----
  # RSTART/RLENGTH are GLOBAL awk specials, clobbered by ANY nested match()
  # call — and handleLink() below makes one (for the trailing ":NNN" strip).
  # Save them to locals BEFORE calling out, or the advance below
  # (`work = substr(work, RSTART + RLENGTH)`) reads the INNER matches
  # RSTART/RLENGTH instead of the outer ones: a failed inner match() sets
  # RSTART=0/RLENGTH=-1, so `work` never shrinks and this spins forever.
  # (Reproduced: 99%-CPU infinite loop, millions of duplicate rows, on the
  # very first file with 2+ markdown links across different lines.)
  work = line
  while (match(work, /\]\([^)]+\)/)) {
    mstart = RSTART; mlen = RLENGTH
    target = substr(work, mstart + 2, mlen - 3)
    handleLink(fname, lineno, target)
    work = substr(work, mstart + mlen)
  }

  # ---- tier 2: bare cited source paths ----
  # Scrub out link-parens targets (already checked above, and resolved by a
  # DIFFERENT rule — dir-relative, not root-relative — so re-matching them
  # here would apply the wrong resolution and could double-report) and full
  # URLs (a github.com/.../compiler/foo.mdk fragment inside an http(s) link
  # is not a citation of OUR compiler/foo.mdk).
  scrub = line
  gsub(/\]\([^)]*\)/, "]", scrub)
  gsub(/https?:\/\/[^ \t)]+/, "", scrub)

  # Require a non-path char (or start-of-string) immediately before the
  # match, or "sqlite/test/overflow_oracle.sh" mis-truncates into a false
  # match on "test/overflow_oracle.sh" (a DIFFERENT, real path) since
  # "sqlite" is not one of our five tracked prefixes — reproduced against
  # sqlite/findings/overflow-write.md. On a bad boundary, retry one
  # character later (work2 still strictly shrinks every iteration, so this
  # cannot loop forever).
  work2 = scrub
  while (length(work2) > 0 && match(work2, /(compiler|stdlib|test|runtime|playground)\/[A-Za-z0-9_.\/-]+\.(mdk|sh|c|md|txt|toml|yml)/)) {
    mstart = RSTART; mlen = RLENGTH
    if (mstart > 1 && substr(work2, mstart - 1, 1) ~ /[A-Za-z0-9_.\/-]/) {
      work2 = substr(work2, mstart + 1)
      continue
    }
    target = substr(work2, mstart, mlen)
    handleBare(fname, lineno, target)
    work2 = substr(work2, mstart + mlen)
  }
}

BEGIN {
  while ((getline fname < LISTFILE) > 0) {
    lineno = 0
    while ((getline line < fname) > 0) {
      lineno++
      processLine(fname, lineno, line)
    }
    close(fname)
  }
}
' > "$WORK/refs.tsv"

TOTAL_REFS="$(wc -l < "$WORK/refs.tsv" | tr -d ' ')"
TOTAL_FILES="$(wc -l < "$WORK/md_files.txt" | tr -d ' ')"

if [ "$TOTAL_REFS" -eq 0 ]; then
  echo "FAIL: checked ZERO references across $TOTAL_FILES markdown files — this is a HARNESS failure"
  echo "      (extraction found nothing at all; a fresh clone must never report 0 checked as a pass)."
  exit 1
fi

# ── 3. Load the exceptions ledger. ──────────────────────────────────────────
# Two kinds, TAB-separated:  KIND <TAB> pattern <TAB> reason
#   FILE  pattern is a citing-file shell glob (matched against the file's
#         git-relative path with `case`) — every dead reference found while
#         scanning a MATCHING file is excused. Use for whole historical docs.
#   REF   pattern is an exact resolved target path (root-relative, as this
#         gate normalizes it) — every citation of that exact dead target, in
#         any file, is excused. Use for one-off stale paths in living docs.
: > "$WORK/exc_file.tsv"
: > "$WORK/exc_ref.tsv"
if [ -f "$EXC" ]; then
  while IFS="$(printf '\t')" read -r kind pattern reason; do
    case "$kind" in
      ''|'#'*) continue ;;
    esac
    [ -z "${pattern:-}" ] && continue
    if [ -z "${reason:-}" ]; then
      echo "FAIL: $EXC has a $kind entry for '$pattern' with NO reason — every exception needs one"
      exit 1
    fi
    case "$kind" in
      FILE) printf '%s\t%s\n' "$pattern" "$reason" >> "$WORK/exc_file.tsv" ;;
      REF)  printf '%s\t%s\n' "$pattern" "$reason" >> "$WORK/exc_ref.tsv" ;;
      *)
        echo "FAIL: $EXC has an unknown exception kind '$kind' (want FILE or REF): $pattern"
        exit 1
        ;;
    esac
  done < "$EXC"
fi
N_EXC_FILE="$(wc -l < "$WORK/exc_file.tsv" | tr -d ' ')"
N_EXC_REF="$(wc -l < "$WORK/exc_ref.tsv" | tr -d ' ')"

# Every exception that actually excuses a real dead reference gets its key
# recorded here. Anything in the ledger that never shows up in this file is an
# ORPHAN — see step 5b.
: > "$WORK/exc_hits.tsv"

is_file_excused() {
  # $1 = citing file path. Prints "<pattern>\t<reason>" and returns 0 if excused.
  citing="$1"
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    case "$citing" in
      $pat) printf '%s\t%s\n' "$pat" "$reason"; return 0 ;;
    esac
  done < "$WORK/exc_file.tsv"
  return 1
}

is_ref_excused() {
  # $1 = resolved target path. Prints "<pattern>\t<reason>" and returns 0 if excused.
  awk -F '\t' -v want="$1" '$1 == want { print $1 "\t" $2; found=1; exit } END { exit !found }' "$WORK/exc_ref.tsv"
}

# ── 4. Check every reference against disk, applying exceptions. ─────────────
DEAD=0
LIVE=0
EXCUSED_HISTORY=0
EXCUSED_TODO=0

while IFS="$(printf '\t')" read -r fname lineno kind target resolved; do
  if [ -e "$resolved" ]; then
    LIVE=$((LIVE + 1))
    continue
  fi
  hit=""
  if hit="$(is_file_excused "$fname")"; then
    hitkind=FILE
  elif hit="$(is_ref_excused "$resolved")"; then
    hitkind=REF
  else
    hit=""
  fi
  if [ -n "$hit" ]; then
    # hit is "<pattern>\t<reason>"; record the key so step 5b can tell which
    # ledger lines actually earned their place on THIS run.
    hitpat="${hit%%	*}"
    reason="${hit#*	}"
    printf '%s\t%s\n' "$hitkind" "$hitpat" >> "$WORK/exc_hits.tsv"
    case "$reason" in
      TODO\(docs-cleanup\)*) EXCUSED_TODO=$((EXCUSED_TODO + 1)) ;;
      *)                     EXCUSED_HISTORY=$((EXCUSED_HISTORY + 1)) ;;
    esac
    continue
  fi
  DEAD=$((DEAD + 1))
  echo "$fname:$lineno: DEAD -> $resolved (cited as \`$target\`)"
done < "$WORK/refs.tsv"

# ── 5. Ratchet: a stale exception is an ERROR, not a free pass forever. ─────
STALE=0

# REF exceptions: if the path now exists on disk, the reference is no longer
# dead — the exception line is stale and must be deleted, or it will hide a
# FUTURE real regression at that same path forever.
if [ -s "$WORK/exc_ref.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    if [ -e "$pat" ]; then
      echo "FAIL: STALE REF EXCEPTION — '$pat' now EXISTS on disk (reason on file: $reason)"
      echo "      Delete this line from $EXC — the reference it excused is no longer dead."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_ref.tsv"
fi

# FILE exceptions naming one exact file (no glob metacharacters): if that
# file no longer exists at all, the ledger entry outlived the doc it was
# excusing and is dead weight (mirrors diff_compiler_ci_shard_coverage.sh's
# "ledger names a gate that doesn't exist" check).
if [ -s "$WORK/exc_file.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    case "$pat" in
      *'*'*|*'?'*|*'['*) continue ;;  # glob pattern, not a single file — skip
    esac
    if [ ! -e "$pat" ]; then
      echo "FAIL: STALE FILE EXCEPTION — '$pat' no longer exists (reason on file: $reason)"
      echo "      Delete this line from $EXC — the doc it excused is gone."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_file.tsv"
fi

# ── 5b. Ratchet, second half: an exception that excuses NOTHING is an ORPHAN. ─
#
# "The path now exists" is only HALF of "this exception is no longer needed".
# The other half is "NO DOCUMENT CITES THAT PATH ANYMORE" — and without this
# check the ledger cannot notice it. This has already bitten: a docs-cleanup PR
# fixed the add-language-feature skill by REMOVING its citation of
# test/diff_compiler_roundtrip.sh. The file still does not exist, so the
# "now exists" check above stays silent — yet the ledger still carried a line
# whose reason string said "cited by the live add-language-feature skill",
# which had become a LIE that nothing would ever report.
#
# That is precisely the skip-list rot this ledger exists to prevent: as the
# docs-cleanup work drains these paths, EVERY drained entry would become a
# silent orphan and most of the ledger would end up fiction. So an exception
# must ACTIVELY EARN ITS PLACE on every run: the path is still dead AND
# something still cites it. When either stops being true, the line must go.
if [ -s "$WORK/exc_ref.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    [ -e "$pat" ] && continue   # already reported as STALE above; don't double-report
    if ! awk -F '\t' -v want="$pat" '$1 == "REF" && $2 == want { found=1; exit } END { exit !found }' "$WORK/exc_hits.tsv"; then
      echo "FAIL: ORPHAN REF EXCEPTION — '$pat' is no longer cited by ANY document (reason on file: $reason)"
      echo "      Delete this line from $EXC — nothing references that path anymore, so the"
      echo "      exception excuses nothing and its reason string is now fiction."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_ref.tsv"
fi

# The same principle applies to a whole-file exception: if the doc it names no
# longer contains a SINGLE dead reference, the blanket excuse is dead weight —
# and worse, it would silently keep excusing any FUTURE rot in that file.
if [ -s "$WORK/exc_file.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    if ! awk -F '\t' -v want="$pat" '$1 == "FILE" && $2 == want { found=1; exit } END { exit !found }' "$WORK/exc_hits.tsv"; then
      echo "FAIL: ORPHAN FILE EXCEPTION — '$pat' no longer has a single dead reference (reason on file: $reason)"
      echo "      Delete this line from $EXC — the blanket excuse is unnecessary, and leaving it"
      echo "      in place would silently excuse any FUTURE rot in that file."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_file.tsv"
fi

# ── 6. Report. ────────────────────────────────────────────────────────────
echo
echo "checked $TOTAL_REFS references across $TOTAL_FILES markdown files"
echo "  live:    $LIVE"
echo "  excused: $((EXCUSED_HISTORY + EXCUSED_TODO))  ($EXCUSED_HISTORY legitimate history, $EXCUSED_TODO TODO(docs-cleanup) stale paths)"
echo "  dead:    $DEAD"
if [ "$STALE" -gt 0 ]; then
  echo "  stale exceptions: $STALE"
fi

if [ "$DEAD" -gt 0 ] || [ "$STALE" -gt 0 ]; then
  echo
  echo "FAIL: $DEAD dead reference(s), $STALE stale exception(s). See above."
  exit 1
fi

echo
echo "PASS: every reference resolves (modulo $((N_EXC_FILE + N_EXC_REF)) exception(s) in $EXC)."
exit 0
