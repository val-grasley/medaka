#!/bin/sh
# test/check_agent_doc_symbols.sh — agent-facing doc SYMBOL-claim rot gate.
#
# WHY THIS EXISTS: a repo-wide review of the agent "skill" playbooks
# (.claude/skills/*/SKILL.md — the files agents EXECUTE, not just read) found
# ~44 false concrete claims. `harden-typechecker` taught `pushTypeError` with
# the WRONG ARITY (it takes 2 args, code then message — every call the skill
# taught was a silent-drop partial application) and carried a 20-name "grep
# these names" index that was 19/20 fictional OCaml-era symbols. `extend-stdlib`
# built its whole doctest section on a `Show` typeclass that does not exist
# (it's `Debug`). `add-lsp-capability` named three nonexistent symbols in its
# three wiring steps. ~30 of the ~44 defects were the SAME shape: "this
# backticked symbol resolves nowhere in the tree." A mechanical check would
# have caught nearly all of them. This gate is that check.
#
# WHAT IT CHECKS (pure text analysis — no compiler build, no toolchain, safe
# to run anywhere, always): every INLINE single-backtick span in the
# agent-facing docs (AGENTS.md, .claude/skills/*/SKILL.md,
# .claude/workstreams/*.md, .claude/ORCHESTRATING.md) that is SHAPED like a
# Medaka code identifier — and requires it to appear somewhere in the actual
# compiler/stdlib/runtime source.
#
# THE HARD PART: backticks in these docs are ALSO used for prose, shell
# commands, CLI flags, English words, and type names. A gate that flags all of
# that is a gate everyone disables. So "symbol-shaped" is deliberately narrow:
#
#   - the ENTIRE backtick span must be a bare identifier: ^[A-Za-z_][A-Za-z0-9_]*$
#     (no dots, slashes, spaces, colons, parens — a real Medaka path or type
#     signature never matches this, so `compiler/foo.mdk` and
#     `pushTypeError : String -> String -> <Mut> Unit` are excluded at
#     EXTRACTION, not by exception — mirrors check_doc_links.sh's ellipsis
#     and raw-space exclusions, which is the right place to drop a shape that
#     can never be a bare-identifier claim)
#   - length >= 3 (drops single/double-letter noise: `a`, `id`, `ok`)
#   - MIXED CASE required: the token must contain BOTH an uppercase and a
#     lowercase letter. This is the key precision lever. It keeps camelCase
#     function names (`pushTypeError`, `checkMethodUsages`) and PascalCase
#     type/constructor names (`ImplEntry`, `EMatch`, `Show`) — which is
#     EXACTLY the shape of every fabrication found in the original audit —
#     while dropping: plain lowercase English/shell words (`grep`, `sh`,
#     `main`, `type`), and ALL-CAPS acronyms/env-vars/constants (`JSON`,
#     `GC_INITIAL_HEAP_SIZE`, `JOBS`). The tradeoff is real: an all-lowercase
#     fabricated symbol (e.g. a fake `main`) would NOT be caught. Measured
#     against the current corpus this tradeoff is the right one — see the
#     false-positive count below.
#   - fenced ``` code blocks are SKIPPED entirely (shell commands, type-sig
#     blocks, example programs — too heterogeneous to extract reliably; the
#     "grep these names" index pattern this gate exists to catch is always
#     INLINE prose or a markdown table, never inside a fence, in every
#     instance found in the original audit)
#
# DOTTED SPANS (#94): a bare-identifier-only regex silently DROPS a dotted
# claim like `Method_marker.marked_prelude` (an OCaml module path, for a
# compiler deleted 2026-06-26) at extraction — never reaching the resolver,
# so a gate reporting "0 dead" was actually reporting "0 dead of the ones it
# looked at". A dotted span is now ALSO a symbol claim when:
#   - the WHOLE span matches ^ident(\.ident)+$ (one or more dot-joined bare
#     identifiers, nothing else — so a real filesystem path
#     (`compiler/frontend/ast.mdk`), a hyphenated doc name (`ERROR-QUALITY.md`),
#     a file:line ref (`core.mdk:380`), and any span with a space, `<>`, `*`,
#     or other punctuation still fail this shape and are excluded, same as
#     the bare case above)
#   - AND at least one dot-separated SEGMENT independently satisfies the bare
#     isSymbolShaped rule above (mixed case, length >= 3). This is the
#     precision lever for dotted spans, mirroring the bare-token one: OCaml
#     module paths are `Capitalized_Module.lower_fn` — the module segment
#     alone is mixed-case-shaped (`Method_marker`, `Dict_pass`) even though
#     the function segment (`marked_prelude`, `run`) is plain snake_case. A
#     filename dotted span is EITHER all-lowercase in every segment
#     (`core.mdk`, `core_ir_eval.mdk`, `diff_compiler_engines.sh`) or has an
#     all-caps stem plus a lowercase extension (`AGENTS.md`, `README.md`) —
#     in both cases NO segment individually has both an uppercase and a
#     lowercase letter, so "at least one segment is mixed-case" cleanly
#     separates real dotted symbol claims from file-path mentions. Verified
#     against the current doc corpus: this rule adds ZERO new claims over the
#     existing corpus (no dotted symbol claim is currently live) and is the
#     narrowest rule that still catches the motivating #94 examples.
#   - Resolution reuses is_resolved() UNCHANGED: a dotted token is checked as
#     a literal whole-word fixed string via `grep -wF`, same as a bare token
#     — a dotted OCaml path never appears verbatim in Medaka source, so this
#     is already the right (and simplest) resolution rule; no new grep logic
#     needed.
#
# A token that resolves nowhere in compiler/*.mdk + stdlib/*.mdk + runtime/*.c
# is DEAD unless excused in test/AGENT-DOC-SYMBOL-EXCEPTIONS.txt.
#
# THE EXCEPTIONS FILE IS A RATCHET, NOT A SKIP-LIST — same contract as
# test/DOC-LINK-EXCEPTIONS.txt (read that file's header; this one mirrors it
# exactly). Two kinds, TAB-separated: `SYM<TAB>token<TAB>reason` excuses one
# exact token everywhere it's cited; `FILE<TAB>glob<TAB>reason` excuses EVERY
# dead token found while scanning a matching doc (use for a doc that is, by
# its own stated purpose, a backlog of NOT-YET-BUILT functions — see the
# STDLIB.md entry below for why that is not the same thing as a fabrication).
# Every line must ACTIVELY EARN ITS PLACE on every run:
#   - STALE  SYM  — the token NOW resolves in source (no longer dead; keeping
#                   the line would hide a FUTURE regression at that name)
#   - ORPHAN SYM  — NO document cites that token anymore (the exception
#                   excuses nothing; its reason string has become fiction)
#   - STALE  FILE — the named doc no longer exists
#   - ORPHAN FILE — the named doc no longer has a SINGLE dead token (the
#                   blanket excuse is dead weight and would silently swallow
#                   any FUTURE unrelated fabrication in that file)
# A ledger nobody re-checks is how test/ported/ and diff_compiler_lint_multi
# sat silently skipped-and-failing for months; this file cannot do that,
# because the gate re-verifies every line on every run.
#
# CORPUS SCOPE, DELIBERATE: `git ls-files` (TRACKED only) for BOTH the doc
# corpus and the source-resolution corpus — an uncommitted doc claiming an
# uncommitted symbol is not yet a CI-visible regression, and this keeps both
# sides of the check consistent with each other. Source resolution covers
# `compiler/*.mdk` + `stdlib/*.mdk` (the Medaka source proper) and
# `runtime/*.c` (the C runtime — a doc legitimately cites real runtime
# symbols like `GC_malloc_atomic`) but deliberately EXCLUDES the `*.md`
# design docs that also live under compiler/ (compiler/HELPER-CENSUS.md,
# compiler/MESSAGE-AUDIT.md, …): those are PROSE, and grepping them let a
# naming-CONVENTION mention (`*Msg` builders, described in prose as "Msg")
# resolve a token that is not a real standalone identifier anywhere in actual
# source — a false-negative in the checker's OWN corpus, found and closed
# while building this gate.
#
# NEVER SILENTLY NO-OP: prints "checked N symbol claims across M files", and
# N == 0 is a FAILURE (exit 1), not a quiet pass. Run BOTH `sh` and `dash`
# explicitly — dash is what /bin/sh actually is on this box, and a previous
# gate here sat "skipped" for months because it silently only ran under bash.
#
# Usage:  sh test/check_agent_doc_symbols.sh
# Exit:   0 every symbol claim resolves (modulo the exceptions ledger);
#         1 a dead claim with no exception, a stale/orphan exception, or zero
#           claims checked (harness bug).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXC="$ROOT/test/AGENT-DOC-SYMBOL-EXCEPTIONS.txt"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v git >/dev/null 2>&1 || { echo "FAIL: git not found"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FAIL: awk not found"; exit 2; }
command -v grep >/dev/null 2>&1 || { echo "FAIL: grep not found"; exit 2; }

# ── 1. Enumerate the agent-facing doc corpus. ───────────────────────────────
git ls-files 'AGENTS.md' '.claude/skills/*/SKILL.md' '.claude/workstreams/*.md' '.claude/ORCHESTRATING.md' \
  > "$WORK/doc_files.txt"

if [ ! -s "$WORK/doc_files.txt" ]; then
  echo "FAIL: found NO agent-facing docs (harness bug — wrong cwd, or the corpus moved)"
  exit 1
fi
TOTAL_FILES="$(wc -l < "$WORK/doc_files.txt" | tr -d ' ')"

# ── 2. Extract inline single-backtick, symbol-shaped tokens. ───────────────
# One pass in awk, filenames via getline (not ARGV — see check_doc_links.sh
# for why: a filename containing a space would word-split as an ARGV entry).
# Fenced ``` code blocks are skipped by toggling on any line whose trimmed
# content starts with ``` (see file header for why fences are out of scope).
awk -v LISTFILE="$WORK/doc_files.txt" '
function emit(fname, lineno, tok) { printf "%s\t%d\t%s\n", fname, lineno, tok }

function isSymbolShaped(tok,    i, c, hasLower, hasUpper) {
  if (tok !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return 0
  if (length(tok) < 3) return 0
  hasLower = 0; hasUpper = 0
  for (i = 1; i <= length(tok); i++) {
    c = substr(tok, i, 1)
    if (c ~ /[a-z]/) hasLower = 1
    else if (c ~ /[A-Z]/) hasUpper = 1
  }
  return (hasLower && hasUpper)
}

# #94: a dotted span (`Method_marker.marked_prelude`) — see file header
# "DOTTED SPANS" for the full rationale. Shape: one-or-more dot-joined bare
# identifiers, nothing else (no slash/space/colon/hyphen/angle-bracket), AND
# at least one dot-separated segment independently passes isSymbolShaped
# (mixed case, len >= 3) — this is what separates a real OCaml-style module
# path from a same-shaped filename mention (`core.mdk`, `AGENTS.md`), where
# NO segment ever has both cases.
function isDottedSymbolShaped(tok,    n, i, parts) {
  if (tok !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/) return 0
  n = split(tok, parts, ".")
  for (i = 1; i <= n; i++) {
    if (isSymbolShaped(parts[i])) return 1
  }
  return 0
}

function countTicks(s,    n, i) {
  n = 0
  for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == "`") n++
  return n
}

function processLine(fname, lineno, line,    work, mstart, mlen, tok) {
  work = line
  while (match(work, /`[^`]+`/)) {
    mstart = RSTART; mlen = RLENGTH
    tok = substr(work, mstart + 1, mlen - 2)
    # Advance BEFORE any filtering/continue — the loop must shrink `work`
    # unconditionally every iteration or a rejected token spins forever
    # (see check_doc_links.sh RSTART/RLENGTH clobbering note for the general
    # shape of this hazard; here the fix is simpler: just advance first).
    work = substr(work, mstart + mlen)
    if (isSymbolShaped(tok)) emit(fname, lineno, tok)
    else if (isDottedSymbolShaped(tok)) emit(fname, lineno, tok)
  }
}

BEGIN {
  while ((getline fname < LISTFILE) > 0) {
    lineno = 0
    infence = 0
    pending = ""; pendlno = 0
    while ((getline line < fname) > 0) {
      lineno++
      trimmed = line
      gsub(/^[ \t]+/, "", trimmed)
      if (trimmed ~ /^```/) { infence = !infence; continue }
      if (infence) continue

      # ── A CODE SPAN CAN WRAP ACROSS A LINE BREAK. Join before extracting. ──
      # Markdown reflow happily splits `sh test/build_oracles.sh --build-one
      # <name>` over two lines. Matching /`[^`]+`/ per-line then pairs the OPENING
      # backtick with the next UNRELATED closing one, extracting garbage — and,
      # far worse, making a genuinely-cited symbol later on the line invisible.
      #
      # That is not hypothetical: it made the gate report
      #   "ORPHAN SYM EXCEPTION — 'TaskStop' is no longer cited by ANY document"
      # while TaskStop WAS cited, two lines up. The message points at the LEDGER,
      # not at the real cause, and the fix it invites is to delete a ledger line
      # that is still earning its place. A gate that lies about WHY it failed is
      # worse than one that stays quiet — it launders a wrong action as a fix.
      #
      # An ODD backtick count means a span is still open: hold the line and
      # append the next. Report at the line the span STARTED on.
      if (pending != "") { line = pending " " line; lineno_use = pendlno }
      else               { lineno_use = lineno }
      if (countTicks(line) % 2 == 1) { pending = line; pendlno = lineno_use; continue }
      pending = ""; pendlno = 0
      processLine(fname, lineno_use, line)
    }
    # An unterminated span at EOF: process what we have rather than dropping it.
    if (pending != "") processLine(fname, pendlno, pending)
    close(fname)
  }
}
' > "$WORK/claims.tsv"

TOTAL_CLAIMS="$(wc -l < "$WORK/claims.tsv" | tr -d ' ')"
if [ "$TOTAL_CLAIMS" -eq 0 ]; then
  echo "FAIL: checked ZERO symbol claims across $TOTAL_FILES docs — this is a HARNESS failure"
  echo "      (extraction found nothing at all; a fresh clone must never report 0 checked as a pass)."
  exit 1
fi

# ── 3. Build the source-resolution corpus (tracked source only). ───────────
git ls-files 'compiler/*.mdk' 'stdlib/*.mdk' 'runtime/*.c' > "$WORK/src_files.txt"
if [ ! -s "$WORK/src_files.txt" ]; then
  echo "FAIL: found NO source files under compiler/*.mdk, stdlib/*.mdk, runtime/*.c (harness bug)"
  exit 1
fi

# #620: a MENTION is not a DEFINITION — `grep -w` over the raw file matched a
# symbol named only in a stale `--`/`{- -}`/`/* */` COMMENT just as happily as
# a real definition, so a doc could cite a symbol deleted from code but still
# named in a leftover comment and the gate would call it "resolved". Fix:
# strip whole-line and whole-block comments out of the corpus BEFORE
# resolving, so a comment-only mention no longer counts.
#
# Deliberately NARROW, not a full tokenizer — a `--`/`/*` that is itself part
# of a string literal (`"--json"`, `hasFlag "--json"`, CLI flag help text —
# both this repo's compiler and stdlib have plenty) must NOT be treated as a
# comment opener, or a real definition sharing a line with such a string would
# be silently dropped from the corpus and a LIVE symbol would false-positive
# as dead. So this only ever drops a line whose comment SPANS THE WHOLE LINE:
#   - a `.mdk` line is dropped if its trimmed text starts with `--`, or if it
#     falls inside a `{- … -}` block that itself OPENED at the start of a
#     trimmed line (this repo's own convention — every sampled docstring/
#     header block opens and closes at line-start; verified against
#     stdlib/core.mdk, compiler/frontend/lexer.mdk before relying on it)
#   - a `runtime/*.c` line is dropped the same way for `//` and `/* … */`
# A line with CODE before the comment marker (e.g. `foo x = bar x -- note`,
# `cell[0] = -1; /* PAP sentinel header */`) is left completely untouched —
# so a trailing same-line comment is not stripped. That is a real but narrow
# gap (a symbol named ONLY in a trailing comment on an otherwise-live line
# would still resolve) — accepted deliberately over risking a false-positive
# on a live symbol; see #620 for the false-negative-vs-false-positive tradeoff.
awk -v LISTFILE="$WORK/src_files.txt" '
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }

BEGIN {
  while ((getline fname < LISTFILE) > 0) {
    isC = (fname ~ /\.c$/)
    openTok  = isC ? "/*" : "{-"
    closeTok = isC ? "*/" : "-}"
    lineTok  = isC ? "//" : "--"
    inBlock = 0
    while ((getline line < fname) > 0) {
      if (inBlock) {
        idx = index(line, closeTok)
        if (idx > 0) {
          rest = substr(line, idx + length(closeTok))
          rest = ltrim(rest)
          if (rest != "") print rest
          inBlock = 0
        }
        continue
      }
      trimmed = ltrim(line)
      if (index(trimmed, lineTok) == 1) continue
      if (index(trimmed, openTok) == 1) {
        openIdx = index(line, openTok)
        closeIdx = index(line, closeTok)
        if (closeIdx > openIdx) {
          rest = ltrim(substr(line, closeIdx + length(closeTok)))
          if (rest != "") print rest
        } else {
          inBlock = 1
        }
        continue
      }
      print line
    }
    close(fname)
  }
}
' > "$WORK/stripped_src.txt"

is_resolved() {
  # $1 = token. Word-matched, fixed-string, quiet: exits 0 iff the
  # COMMENT-STRIPPED source corpus contains this exact identifier as a whole
  # word (see #620 header above the awk block for what "stripped" covers).
  grep -qw -F -- "$1" "$WORK/stripped_src.txt" 2>/dev/null
}

# ── 4. Load the exceptions ledger. ──────────────────────────────────────────
: > "$WORK/exc_sym.tsv"
: > "$WORK/exc_file.tsv"
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
      SYM)  printf '%s\t%s\n' "$pattern" "$reason" >> "$WORK/exc_sym.tsv" ;;
      FILE) printf '%s\t%s\n' "$pattern" "$reason" >> "$WORK/exc_file.tsv" ;;
      *)
        echo "FAIL: $EXC has an unknown exception kind '$kind' (want SYM or FILE): $pattern"
        exit 1
        ;;
    esac
  done < "$EXC"
fi
N_EXC_SYM="$(wc -l < "$WORK/exc_sym.tsv" | tr -d ' ')"
N_EXC_FILE="$(wc -l < "$WORK/exc_file.tsv" | tr -d ' ')"

is_sym_excused() {
  # $1 = token. Prints "<pattern>\t<reason>" and returns 0 if excused.
  awk -F '\t' -v want="$1" '$1 == want { print $1 "\t" $2; found=1; exit } END { exit !found }' "$WORK/exc_sym.tsv"
}

is_file_excused() {
  # $1 = citing doc path. Prints "<pattern>\t<reason>" and returns 0 if excused.
  citing="$1"
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    case "$citing" in
      $pat) printf '%s\t%s\n' "$pat" "$reason"; return 0 ;;
    esac
  done < "$WORK/exc_file.tsv"
  return 1
}

# ── 5. Resolve every DISTINCT token once (the resolution grep is the
#      expensive step; the doc corpus can cite the same token many times). ──
cut -f3 "$WORK/claims.tsv" | sort -u > "$WORK/distinct_tokens.txt"
: > "$WORK/resolved_tokens.txt"
: > "$WORK/dead_tokens.txt"
while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  if is_resolved "$tok"; then
    printf '%s\n' "$tok" >> "$WORK/resolved_tokens.txt"
  else
    printf '%s\n' "$tok" >> "$WORK/dead_tokens.txt"
  fi
done < "$WORK/distinct_tokens.txt"
N_DISTINCT="$(wc -l < "$WORK/distinct_tokens.txt" | tr -d ' ')"

# ── 6. Walk every claim occurrence, applying exceptions. ────────────────────
DEAD=0
LIVE=0
EXCUSED=0
: > "$WORK/exc_hits.tsv"

while IFS="$(printf '\t')" read -r fname lineno tok; do
  if grep -qx -F "$tok" "$WORK/resolved_tokens.txt" 2>/dev/null; then
    LIVE=$((LIVE + 1))
    continue
  fi
  hit=""
  if hit="$(is_file_excused "$fname")"; then
    hitkind=FILE
  elif hit="$(is_sym_excused "$tok")"; then
    hitkind=SYM
  else
    hit=""
  fi
  if [ -n "$hit" ]; then
    # hit is "<pattern>\t<reason>" — the PATTERN (glob key for FILE, exact
    # token for SYM) as recorded in the ledger, not the citing filename or
    # the raw token. Step 7c/7d's orphan check needs this exact key.
    hitpat="${hit%%	*}"
    printf '%s\t%s\n' "$hitkind" "$hitpat" >> "$WORK/exc_hits.tsv"
    EXCUSED=$((EXCUSED + 1))
    continue
  fi
  DEAD=$((DEAD + 1))
  echo "$fname:$lineno: DEAD -> \`$tok\` (no such symbol in compiler/*.mdk, stdlib/*.mdk, or runtime/*.c)"
done < "$WORK/claims.tsv"

# ── 7. Ratchet: a stale or orphan exception is an ERROR, not a free pass. ──
STALE=0

# 7a. STALE SYM: the token now resolves — the exception is no longer needed
# and would hide a FUTURE regression at that exact name.
if [ -s "$WORK/exc_sym.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    if is_resolved "$pat"; then
      echo "FAIL: STALE SYM EXCEPTION — '$pat' now resolves in source (reason on file: $reason)"
      echo "      Delete this line from $EXC — the claim it excused is no longer dead."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_sym.tsv"
fi

# 7b. STALE FILE: the named doc (exact filename, no glob metachars) is gone.
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

# 7c. ORPHAN SYM: nothing cites this token anymore.
if [ -s "$WORK/exc_sym.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    is_resolved "$pat" && continue   # already reported as STALE above
    if ! awk -F '\t' -v want="$pat" '$1 == "SYM" && $2 == want { found=1; exit } END { exit !found }' "$WORK/exc_hits.tsv"; then
      echo "FAIL: ORPHAN SYM EXCEPTION — '$pat' is no longer cited by ANY document (reason on file: $reason)"
      echo "      Delete this line from $EXC — nothing references that token anymore, so the"
      echo "      exception excuses nothing and its reason string is now fiction."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_sym.tsv"
fi

# 7d. ORPHAN FILE: the named doc no longer has a single dead symbol claim.
if [ -s "$WORK/exc_file.tsv" ]; then
  while IFS="$(printf '\t')" read -r pat reason; do
    [ -z "$pat" ] && continue
    if ! awk -F '\t' -v want="$pat" '$1 == "FILE" && $2 == want { found=1; exit } END { exit !found }' "$WORK/exc_hits.tsv"; then
      echo "FAIL: ORPHAN FILE EXCEPTION — '$pat' no longer has a single dead symbol claim (reason on file: $reason)"
      echo "      Delete this line from $EXC — the blanket excuse is unnecessary, and leaving it"
      echo "      in place would silently excuse any FUTURE fabrication in that file."
      STALE=$((STALE + 1))
    fi
  done < "$WORK/exc_file.tsv"
fi

# ── 8. Report. ────────────────────────────────────────────────────────────
echo
echo "checked $TOTAL_CLAIMS symbol claims ($N_DISTINCT distinct tokens) across $TOTAL_FILES agent-facing docs"
echo "  live:    $LIVE"
echo "  excused: $EXCUSED  (via $((N_EXC_SYM + N_EXC_FILE)) ledger entries: $N_EXC_SYM SYM, $N_EXC_FILE FILE)"
echo "  dead:    $DEAD"
if [ "$STALE" -gt 0 ]; then
  echo "  stale/orphan exceptions: $STALE"
fi

if [ "$DEAD" -gt 0 ] || [ "$STALE" -gt 0 ]; then
  echo
  echo "FAIL: $DEAD dead symbol claim(s), $STALE stale/orphan exception(s). See above."
  exit 1
fi

echo
echo "PASS: every symbol claim resolves (modulo $((N_EXC_SYM + N_EXC_FILE)) exception(s) in $EXC)."
exit 0
