#!/bin/sh
# diff_compiler_must_fail.sh — the MUST-FAIL suite: make the TRACKER self-drain.
#
# Every fixture here asserts that an OPEN issue's bug STILL REPRODUCES. When someone
# fixes the bug, the pinned observation stops holding, this gate goes RED, and the
# failure message tells them to close the issue and delete the fixture.
#
# ⭐ WHY THIS EXISTS (#547). `needs-repro` marks the claims nobody has confirmed.
# NOTHING marked the ones that silently became FALSE. When the backlog was re-derived
# on 2026-07-14, SIX entries were already fixed — two of them labelled "silent build
# miscompile", one billed as "the best value-to-risk item on the board". #72 had all
# four of its holes fixed and sat open regardless. Every one of those cost a later
# agent a read, several cost a full investigation. A bug list is a statement encoding
# a fact about the code ("this is broken") with NO DERIVATION AND NO EXPIRY — the
# exact disease .claude/ORCHESTRATING.md's "DERIVE, don't encode" section describes.
# This is the expiry.
#
# ── ⚠️ READ THIS BEFORE YOU ADD A FIXTURE: RUN IT, DO NOT REASON ABOUT IT ──────
#
# A FIXTURE IS A CLAIM ABOUT THE BROKEN BUILD, SO ONLY THE BROKEN BUILD CAN CHECK IT.
# You cannot derive a pin by reading the issue title. The agent who built this suite
# reasoned six repros out of six issue titles and THE BINARY CORRECTED TWO OF THEM —
# both had read as self-evidently correct. (One "reproduced" a bug in an interface
# declaration that was really a missing `where`; one's control was a syntax error the
# author had written himself and nearly filed as a finding.) Three non-discriminating
# probes were written in ONE session in this repo, each reading as obviously right.
#
#   Write the fixture. RUN it. Paste the REAL output into claim.txt. Never the reverse.
#
# ── HOW A FIXTURE REFUSES TO CONFUSE "STILL BROKEN" WITH "SOMETHING ELSE BROKE" ──
#
# This is the whole design problem. A fixture that passes because the compiler crashed
# for an UNRELATED reason is WORSE THAN NO FIXTURE — it launders a regression as
# evidence that a bug is still open. Cf. #463: the shadow gate's BUILD_CRASH verdict
# accepts ANY nonzero exit, so an unrelated crash reads as the pinned bug. Hence:
#
#   1. NO ASSERTION IS EVER "NONZERO" OR "IT CRASHED". Every claim pins an EXACT exit
#      code AND an exact observable — stdout bytes, or a diagnostic's stable `code` +
#      `range` + message. An unrelated failure has a different exit or different bytes,
#      so it FAILS rather than matching.
#   2. EVERY FIXTURE SHIPS A CONTROL — a near-identical program isolating the bug's ONE
#      distinguishing feature, which must stay GREEN. #508 pins "a guard in an impl
#      method body is a parse error" and its control is the SAME GUARD standalone, which
#      must parse clean. If the control breaks, the ENVIRONMENT broke, not the bug, and
#      this gate says CONTROL-BROKE — a verdict distinct from both PASS and DRAINED, so
#      "you broke the prelude" can never be read as "you fixed #508".
#      A fixture with no sensible control must say `control: none <reason>` OUT LOUD.
#      Silence is not an option; declining a control is a deliberate, visible act.
#   3. `checked N fixtures` is printed, and N == 0 IS A FAILURE. "This didn't run" must
#      never look like "this passed" — every silent-green bug in this repo is that
#      sentence.
#
# ── ⚠️ CHOOSING A PIN: A PIN THAT MOVES FOR AN UNRELATED REASON IS A FALSE DRAIN ─
#
# A false drain is WORSE THAN NO FIXTURE: the row goes RED, a reader believes the issue
# is fixed, and closes a LIVE BUG on the strength of it. So pin the NARROWEST thing that
# is actually the defect, and nothing else:
#
#   diag:         code + range + FULL MESSAGE. Use when THE MESSAGE IS THE DEFECT —
#                 #532 (never says `test` is reserved), #66/#135 (blames indentation).
#   diag-code:    code + range ONLY. THE DEFAULT per TESTING-DESIGN §4.5 ("the assertion
#                 is on `code` + `range` (stable); the prose can change freely").
#                 Use when the message legitimately varies. #333's message embeds the
#                 ENTIRE stdlib module list — a `diag:` pin there would drain the day
#                 someone adds a stdlib module, an event with no relation to #333.
#   stdout:       exact whole stdout. stdout-bytes: same, no trailing newline appended.
#   stdout-line:  each named EXACT WHOLE LINE must be present. For large dumps no fixture
#                 can pin whole — #93's `check --types` prints every prelude scheme, which
#                 move whenever the prelude does. Literal whole-line, never substring,
#                 never regex (ppx_expect and Dune both shipped regex matchers and then
#                 DELIBERATELY REMOVED them). Pin BOTH the bug's line AND a line proving
#                 the command still ran.
#   file-after:   the fixture's bytes after an in-place rewrite (fmt --write).
#
# Ask of every pin: "what ELSE in this repo could move this string?" If the answer is
# anything at all, pin something narrower.
#
# ── DIAGNOSTIC PINS ARE HAND-WRITTEN AND DELIBERATELY NOT BLESSABLE ─────────────
#
# There is no --bless here, on purpose (docs/ops/TESTING-DESIGN.md §4.5). A must-fail
# row you can rubber-stamp is a skip-list with extra steps, and a skip-list CANNOT
# NOTICE AN ACCIDENTAL FIX, so it rots — that is how test/ported/ died. Pins key on the
# stable `code` from `check --json` (DIAGNOSTIC-CODES-DESIGN.md), so message prose can
# be reworded freely without touching this suite; only the CODE and RANGE are load-bearing.
#
# ── THE MEMBER SET IS DERIVED, NEVER ENCODED ───────────────────────────────────
#
# The fixture set is `ls test/must_fail_fixtures/`. There is NO table in this script and
# NO count in this header. Adding a fixture is adding ONE DIRECTORY — no gate edit,
# nothing to remember, and no coverage self-audit to forget (contrast
# diff_compiler_shadow_semantics.sh, which needs one precisely BECAUSE it encodes a set
# it could have derived). Three issues — #446, #87, #516 — shipped a wrong fixture count,
# one of them while citing the AGENTS.md passage warning against exactly that.
#
# ── WHERE THIS RUNS, AND WHY IT IS NOT IN A GATE SHARD ─────────────────────────
#
# It is a NAMED step in the `soundness` job (.github/workflows/ci.yml), not a shard.
# A gate shard is NARROWED on `pull_request` by test/preflight.sh's path map: a fix to
# compiler/frontend/parser.mdk derives 'diff_compiler_parse*' and would NOT derive this
# gate — so the drain would only fire in the MERGE QUEUE, bouncing the PR after review.
# The alternative — adding this gate to a dozen preflight `add` arms — is a
# hand-maintained map of "which bug lives in which file", i.e. the encoded-fact disease
# this gate exists to cure; it would rot on the first new fixture.
# `soundness` runs FULL on every event, is already REQUIRED, and already builds ./medaka
# under `if: docs_only != 'true'` — and a docs-only PR cannot fix a compiler bug, so that
# guard is exactly right. Being named in a `run:` step satisfies
# diff_compiler_ci_shard_coverage.sh (its `named` set); this basename matches no shard
# pattern, so there is no duplicate either.
#
# Usage:  sh test/diff_compiler_must_fail.sh
# Exit:   0 every pinned bug still reproduces; 1 a bug DRAINED (go close the issue),
#         a control broke, or a claim is malformed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/must_fail_fixtures"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to render check --json)"; exit 2; }

# ── THE clang GUARD (build / build-run verbs only). ────────────────────────────
#
# The build and build-run verbs invoke `medaka build`, which shells out to clang — the
# ONLY verbs here that need a native toolchain. If any SELECTED fixture uses one and clang
# is absent, this gate FAILS LOUDLY (exit 2, infra error), exactly like the missing-binary
# and missing-python3 guards above. A SKIP THAT EXITS 0 IS THE SILENT-GREEN THIS SUITE
# EXISTS TO PREVENT (#590): every wasm gate exited 0 "skipping" for months because
# wasm-tools was missing, and nobody noticed the coverage had evaporated. `soundness` —
# where this suite runs — always has clang.
if grep -lE '^(cmd|control):[[:space:]]*build(-run)?[[:space:]]' "$FIXDIR"/*/claim.txt >/dev/null 2>&1; then
  command -v clang >/dev/null 2>&1 || {
    echo "clang not found, but a fixture uses the build/build-run verb (it needs a real native compile)."
    echo "This is an INFRA ERROR, not a skip: a must-fail suite that silently skipped a build"
    echo "fixture would report GREEN having never checked it — the exact silent-green this suite"
    echo "exists to prevent. Install clang (soundness, where this runs, has it)."
    exit 2
  }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

# Render `check --json` to one stable line per diagnostic: CODE sl:sc-el:ec message
render_diags() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception as e:
    print(f"!!UNPARSEABLE-JSON {e}")
    sys.exit(0)
for f in doc.get("files", []):
    for d in f.get("diagnostics", []):
        r = d.get("range", {})
        s, e = r.get("start", {}), r.get("end", {})
        print("%s %s:%s-%s:%s %s" % (d.get("code"), s.get("line"), s.get("character"),
                                     e.get("line"), e.get("character"), d.get("message")))
PY
}

# claim_get <file> <key>  -> all values for that key, one per line
claim_get() { sed -n "s/^$2:[[:space:]]*//p" "$1"; }
claim_has() { grep -q "^$2:" "$1"; }

# run_verb <verb> <fixture-dir> <file> <outfile>  -> exit code
# fmt-write mutates its input, so it runs against a COPY: a gate must never edit the
# corpus it is grading.
#
# THE VERBS, and WHAT EACH GRADES (its exit code + what lands in <outfile>):
#   check / check-json / check-types  — `medaka check [flag]`: the diagnostics path. Grades
#                                       medaka's exit + stdout.
#   run                               — `medaka run`: the tree-walking interpreter. Grades
#                                       its exit + stdout.
#   fmt-write                         — `medaka fmt --write` on a COPY; grades exit + the
#                                       rewritten bytes (file-after).
#   build                             — `medaka build` ITSELF: grades the EMITTER's exit +
#                                       its combined stdout+stderr. For bugs where a valid
#                                       program REFUSES to build (exit 1, no binary) — e.g.
#                                       #666, #671. This is the ONLY verb that grades a
#                                       build FAILURE as the pinned observation.
#   build-run                         — builds the program to a per-process temp binary,
#                                       then EXECUTES it and grades the BINARY's exit +
#                                       stdout. For bugs where build SUCCEEDS but the binary
#                                       crashes or prints the wrong thing (the run≠build
#                                       class — #670, #672). The graded exit is the
#                                       BINARY's, never `medaka build`'s. If `medaka build`
#                                       itself fails here the fixture is MALFORMED for this
#                                       verb (you cannot run a binary that did not build) —
#                                       run_verb returns 126 with an explanation, a HARD
#                                       error, NEVER silently gradeable as a wrong-binary
#                                       observation.
#
# build / build-run need clang; the guard above fails loudly (exit 2) if it is absent.
# The binary goes to "$_out.bin" — "$_out" is "$TMP/<name>.out" (main) or "$TMP/<name>.ctl"
# (control), both inside the per-run mktemp -d, so no two fixtures ever share an -o basename.
# ⚠️ Keying the -o path on anything but a per-process dir is a documented trap that produced
# a stable-looking WRONG binary 19/20 times — do NOT.
run_verb() {
  _verb="$1"; _dir="$2"; _file="$3"; _out="$4"
  case "$_verb" in
    check)       bound "$MEDAKA" check         "$_dir/$_file" >"$_out" 2>"$_out.err"; return $? ;;
    check-json)  bound "$MEDAKA" check --json  "$_dir/$_file" >"$_out" 2>"$_out.err"; return $? ;;
    check-types) bound "$MEDAKA" check --types "$_dir/$_file" >"$_out" 2>"$_out.err"; return $? ;;
    run)        bound "$MEDAKA" run        "$_dir/$_file" >"$_out" 2>"$_out.err"; return $? ;;
    build)
      # Grade `medaka build` itself: its exit code AND its combined stdout+stderr (the
      # emitter's own failure output IS the pinned observation).
      bound "$MEDAKA" build "$_dir/$_file" -o "$_out.bin" >"$_out" 2>&1; return $? ;;
    build-run)
      # Two-phase: build, then run the produced binary and grade THAT.
      bound "$MEDAKA" build "$_dir/$_file" -o "$_out.bin" >"$_out.buildlog" 2>&1; _brc=$?
      if [ "$_brc" -ne 0 ]; then
        # A build failure under build-run is NOT the pinned observation — it is a malformed
        # fixture (a wrong-binary claim on a program that produced no binary). Surface it as
        # a hard error with a distinctive exit (126, "command cannot execute"), so it can
        # never masquerade as the binary's own exit code.
        { echo "build-run MALFORMED: 'medaka build' itself failed (exit $_brc) — cannot run a"
          echo "binary that did not build. This verb grades the EXECUTED binary; if build"
          echo "fails, use the 'build' verb to pin the build failure instead."
          cat "$_out.buildlog"
        } >"$_out"
        return 126
      fi
      bound "$_out.bin" >"$_out" 2>"$_out.err"; return $? ;;
    fmt-write)
      _work="$TMP/fmtwork"; rm -rf "$_work"; mkdir -p "$_work"
      cp "$_dir/$_file" "$_work/$_file"
      bound "$MEDAKA" fmt --write "$_work/$_file" >"$_out" 2>"$_out.err"; _rc=$?
      cp "$_work/$_file" "$_out.after"
      return $_rc ;;
    *) echo "unknown verb: $_verb" >"$_out"; return 127 ;;
  esac
}

printf '%s\n' "MUST-FAIL suite — every row asserts an OPEN issue's bug STILL reproduces."
printf '%s\n' "A RED run here usually means someone FIXED something. That is a good failure."
echo

# ── ONE FIXTURE PER ISSUE. ─────────────────────────────────────────────────────
#
# ⚠️ THIS IS NOT HYPOTHETICAL, AND IT HAPPENED WITHIN A DAY. Two sessions independently
# pinned #532 twenty-one minutes apart (`532-test-is-reserved-but-unsaid` and
# `532-test-keyword-no-reserved-diagnostic`, 0a76f3e6 + 9337e0d3) and NOTHING NOTICED.
# Deriving the member set from `ls` is right, but it means nothing enforces uniqueness.
#
# Why a duplicate is a real defect and not untidiness:
#   * when the bug is fixed, BOTH rows drain. The fixer deletes the one the message named,
#     and the second reads as a fresh unexplained failure — "didn't I just delete that?";
#   * two claims about one bug CAN SILENTLY DISAGREE about what it does. That is exactly
#     the reasoning that kept #142 out of this suite (it is already covered by the
#     self-draining test/fmt_roundtrip_known_divergence.txt ledger — duplicate machinery
#     in two places that can disagree). The same argument applies inside the corpus.
#
# DERIVED, NOT REGISTERED. The check reads the corpus itself — each claim's own `issue:`
# key — so there is no list of issue numbers to maintain and nothing to forget. A registry
# here would be the encoded-fact disease this whole suite exists to cure.
#
# It keys on the `issue:` FIELD, not the directory prefix: the field is the authoritative
# claim (it is what the drain message tells you to close), and two directories could
# collide on it while their names differ. The prefix is checked separately, below, because
# a directory whose name disagrees with its own claim sends the reader to the wrong issue.
dup_fail=0
for d in "$FIXDIR"/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/claim.txt" ] || continue
  printf '%s\t%s\n' "$(sed -n 's/^issue:[[:space:]]*//p' "$d/claim.txt" | head -1)" "$(basename "$d")"
done | sort > "$TMP/issues"

for n in $(cut -f1 "$TMP/issues" | uniq -d); do
  dup_fail=1
  echo "MALFORMED: issue #$n is pinned by MORE THAN ONE fixture:"
  awk -F'\t' -v n="$n" '$1==n{print "       test/must_fail_fixtures/" $2 "/"}' "$TMP/issues"
  echo "  One fixture per issue. Both will drain when #$n is fixed, and the second will read"
  echo "  as an unexplained failure after the first is deleted. Merge them: keep the claim"
  echo '  with the sharper repro and the better "what:", port anything the other says, and'
  echo "  delete the loser. Decide on the PINS, not on which landed first."
  echo
done

# ── The NOT-PINNABLE ledger's TREE-SIDE drain (#569). ──────────────────────────
#
# test/MUST-FAIL-NOT-PINNABLE.txt lists issues a human judged out of shape for THIS
# harness. It is self-draining in BOTH directions, and each half is checked where it CAN
# be — half a ratchet is a skip-list, and a skip-list cannot notice when it stops earning
# its place:
#
#   * HERE (tree-only, no network): an entry that HAS A FIXTURE after all. The corpus
#     contradicts the exemption — someone found a way to pin it, and the line is now a lie.
#   * test/must_fail_census.sh (nightly, has the API): an entry whose issue is CLOSED —
#     the exemption has no subject left.
#
# This half lives in the gate because it needs nothing but the tree, so it catches the
# contradiction on the very PR that creates it.
_ledger="$ROOT/test/MUST-FAIL-NOT-PINNABLE.txt"
if [ -f "$_ledger" ]; then
  while IFS= read -r _line; do
    case "$_line" in ''|\#*) continue ;; esac
    _n="${_line%% *}"
    case "$_n" in ''|*[!0-9]*)
      dup_fail=1
      echo "MALFORMED: MUST-FAIL-NOT-PINNABLE.txt line does not start with an issue number:"
      echo "       $_line"
      echo
      continue ;;
    esac
    _reason="$(printf '%s' "${_line#"$_n"}" | tr -d '[:space:]')"
    if [ -z "$_reason" ]; then
      dup_fail=1
      echo "MALFORMED: MUST-FAIL-NOT-PINNABLE.txt entry #$_n has NO REASON."
      echo "  A reason is mandatory — name the SHAPE the harness cannot express. An entry"
      echo "  without one is a skip-list line, which is exactly what that ledger exists"
      echo "  not to be."
      echo
    fi
    if awk -F'\t' -v n="$_n" '$1==n{f=1} END{exit !f}' "$TMP/issues" 2>/dev/null; then
      dup_fail=1
      echo "MALFORMED: #$_n is listed in MUST-FAIL-NOT-PINNABLE.txt but IT HAS A FIXTURE:"
      awk -F'\t' -v n="$_n" '$1==n{print "       test/must_fail_fixtures/" $2 "/"}' "$TMP/issues"
      echo "  The exemption is contradicted by the corpus — somebody pinned it after all."
      echo "  DELETE the line. An exemption that outlives its reason silently swallows a"
      echo "  real future finding."
      echo
    fi
  done < "$_ledger"
fi

# A directory whose name disagrees with its own claim's `issue:` points the reader at the
# wrong issue — the drain message says "close #A" while the path says #B.
for d in "$FIXDIR"/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/claim.txt" ] || continue
  _b="$(basename "$d")"
  _claimed="$(sed -n 's/^issue:[[:space:]]*//p' "$d/claim.txt" | head -1)"
  _prefix="${_b%%-*}"
  case "$_prefix" in
    ''|*[!0-9]*)
      dup_fail=1
      echo "MALFORMED: $_b/ does not start with its issue number — name it '<N>-<slug>'."
      echo ;;
    *)
      if [ "$_prefix" != "$_claimed" ]; then
        dup_fail=1
        echo "MALFORMED: $_b/ is named for issue #$_prefix but its claim.txt says 'issue: $_claimed'."
        echo "  The drain message would tell the reader to close #$_claimed while the path says #$_prefix."
        echo
      fi ;;
  esac
done

checked=0; repro=0; drained=0; broke=0; malformed=0

for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  claim="$dir/claim.txt"
  checked=$((checked+1))

  if [ ! -f "$claim" ]; then
    printf 'MALFORMED  %-46s no claim.txt\n' "$name"
    malformed=$((malformed+1)); continue
  fi

  issue="$(claim_get "$claim" issue)"
  what="$(claim_get "$claim" what)"
  cmd="$(claim_get "$claim" cmd)"
  ctl="$(claim_get "$claim" control)"
  exp_exit="$(claim_get "$claim" exit)"

  if [ -z "$issue" ] || [ -z "$cmd" ] || [ -z "$exp_exit" ] || [ -z "$ctl" ]; then
    printf 'MALFORMED  %-46s claim.txt needs issue:, cmd:, exit: and control:\n' "$name"
    printf '           (control: none <reason> is allowed, but must be EXPLICIT)\n'
    malformed=$((malformed+1)); continue
  fi

  verb="${cmd%% *}"; file="${cmd#* }"
  out="$TMP/$name.out"
  run_verb "$verb" "$dir" "$file" "$out"
  got_exit=$?

  fail=""

  # ── exit code: EXACT. Never "nonzero". ──
  [ "$got_exit" = "$exp_exit" ] || \
    fail="$fail\n     exit: expected $exp_exit, got $got_exit"

  # ── stdout: exact, WITH trailing newline ──
  if claim_has "$claim" stdout; then
    claim_get "$claim" stdout | while IFS= read -r l; do printf '%b\n' "$l"; done > "$TMP/$name.want"
    cmp -s "$out" "$TMP/$name.want" || \
      fail="$fail\n     stdout: expected [$(tr '\n' '|' < "$TMP/$name.want")] got [$(tr '\n' '|' < "$out")]"
  fi

  # ── stdout-bytes: exact, NO trailing newline appended (that IS the bug, for #68) ──
  if claim_has "$claim" stdout-bytes; then
    printf '%b' "$(claim_get "$claim" stdout-bytes)" > "$TMP/$name.wantb"
    if ! cmp -s "$out" "$TMP/$name.wantb"; then
      fail="$fail\n     stdout-bytes: expected [$(xxd -p < "$TMP/$name.wantb" | tr -d '\n')]"
      fail="$fail\n                   got      [$(xxd -p < "$out" | tr -d '\n')]"
    fi
  fi

  # ── diag: the FULL ordered diagnostic list must match, exactly. No count field: the
  #    list IS the assertion, so it cannot drift out of sync with a number. ──
  if claim_has "$claim" diag; then
    render_diags "$out" > "$TMP/$name.diags"
    claim_get "$claim" diag > "$TMP/$name.wantdiags"
    if ! cmp -s "$TMP/$name.diags" "$TMP/$name.wantdiags"; then
      fail="$fail\n     diagnostics: expected:"
      while IFS= read -r l; do fail="$fail\n       - $l"; done < "$TMP/$name.wantdiags"
      fail="$fail\n                  actual:"
      if [ -s "$TMP/$name.diags" ]; then
        while IFS= read -r l; do fail="$fail\n       - $l"; done < "$TMP/$name.diags"
      else
        fail="$fail\n       - (none)"
      fi
    fi
  fi

  # ── diag-code: CODE + RANGE only, message NOT asserted. ────────────────────────
  #
  # ⚠️ USE THIS WHEN THE MESSAGE LEGITIMATELY VARIES — and use `diag:` when the MESSAGE
  # IS THE DEFECT. Getting this backwards manufactures a FALSE DRAIN, which is worse
  # than no fixture: the row goes RED, someone reads "issue fixed", and closes a live bug.
  #
  # This verb exists because #333's real message embeds the ENTIRE stdlib module list
  # ("unknown module: X — available modules: array, async, base64, …"). Pinning that with
  # `diag:` would drain the row the day ANYONE ADDS A STDLIB MODULE — an event with no
  # connection whatsoever to #333. The pin would have been an encoded fact about a set
  # that moves for unrelated reasons.
  #
  # It is also what docs/ops/TESTING-DESIGN.md §4.5 prescribes as the DEFAULT: "The
  # assertion is on `code` + `range` (stable); the prose can change freely." `diag:` is
  # the stricter, deliberate exception, for rows where the wording is the bug being
  # pinned (#532: the message never says `test` is reserved; #66: it blames indentation).
  if claim_has "$claim" diag-code; then
    render_diags "$out" | awk '{print $1, $2}' > "$TMP/$name.dcodes"
    claim_get "$claim" diag-code > "$TMP/$name.wantdcodes"
    if ! cmp -s "$TMP/$name.dcodes" "$TMP/$name.wantdcodes"; then
      fail="$fail\n     diagnostic code+range: expected:"
      while IFS= read -r l; do fail="$fail\n       - $l"; done < "$TMP/$name.wantdcodes"
      fail="$fail\n                            actual:"
      if [ -s "$TMP/$name.dcodes" ]; then
        while IFS= read -r l; do fail="$fail\n       - $l"; done < "$TMP/$name.dcodes"
      else
        fail="$fail\n       - (none)"
      fi
    fi
  fi

  # ── stdout-line: each named EXACT LINE must be present in stdout. ──────────────
  #
  # For a command whose output is a large DUMP that no fixture can pin whole — #93's
  # `check --types` prints every scheme in the prelude, ~130 lines that move whenever
  # the prelude does. Pinning all of it with `stdout:` would drain on any prelude edit.
  #
  # This is a LITERAL WHOLE-LINE match, not a substring and not a regex ("normalize the
  # ACTUAL, never the expected" — ppx_expect and Dune both shipped regex matchers and
  # then DELIBERATELY REMOVED them). Discrimination comes from pinning BOTH the bug's
  # line AND a line that proves the command still worked: #93 pins the fabricated
  # `eq : Num b => a -> a -> Bool` AND the real `eq : Num a => a -> a`, so a dump that
  # broke entirely fails as "expected line missing" on BOTH, and its control catches it.
  if claim_has "$claim" stdout-line; then
    claim_get "$claim" stdout-line > "$TMP/$name.wantlines"
    while IFS= read -r want; do
      [ -z "$want" ] && continue
      if ! grep -qxF -- "$want" "$out"; then
        fail="$fail\n     stdout-line: expected this EXACT line in stdout, and it is absent:"
        fail="$fail\n       - $want"
      fi
    done < "$TMP/$name.wantlines"
  fi

  # ── file-after: the fixture's bytes after an in-place rewrite (fmt --write) ──
  if claim_has "$claim" file-after; then
    claim_get "$claim" file-after | while IFS= read -r l; do printf '%b\n' "$l"; done > "$TMP/$name.wantf"
    if [ -f "$out.after" ]; then
      cmp -s "$out.after" "$TMP/$name.wantf" || \
        fail="$fail\n     file-after: expected [$(tr '\n' '|' < "$TMP/$name.wantf")] got [$(tr '\n' '|' < "$out.after")]"
    else
      fail="$fail\n     file-after: claimed, but verb '$verb' rewrites no file"
    fi
  fi

  # ── THE CONTROL. Must be green, or this is not a drain. ──
  ctl_broke=""
  case "$ctl" in
    none*) ;;
    *)
      cverb="${ctl%% *}"; cfile="${ctl#* }"
      cout="$TMP/$name.ctl"
      run_verb "$cverb" "$dir" "$cfile" "$cout"
      crc=$?
      [ "$crc" = 0 ] || ctl_broke="control '$ctl' exited $crc, expected 0"
      if [ -z "$ctl_broke" ] && [ "$cverb" = "check-json" ]; then
        render_diags "$cout" > "$TMP/$name.ctldiags"
        [ -s "$TMP/$name.ctldiags" ] && \
          ctl_broke="control '$ctl' must be diagnostic-free, but emitted: $(head -1 "$TMP/$name.ctldiags")"
      fi ;;
  esac

  if [ -n "$ctl_broke" ]; then
    broke=$((broke+1))
    printf 'CONTROL-BROKE  %-42s (issue #%s)\n' "$name" "$issue"
    printf '  ⚠️  This is NOT a drain — do not close #%s. Your change broke the CONTROL,\n' "$issue"
    printf '      which means the ENVIRONMENT moved, not the bug.\n'
    printf '      %s\n' "$ctl_broke"
    echo
    continue
  fi

  if [ -z "$fail" ]; then
    repro=$((repro+1))
    # ── REPRO asserts ONLY WHAT IT CHECKED: the pin still reproduces (STILL BROKEN). ──
    #
    # It does NOT — and CANNOT — assert the issue is "still open". This gate is OFFLINE by
    # design: it runs on every dev box via `make gates`/preflight (no `gh` auth) and on fork
    # PRs (restricted token), so it has no GitHub API and no way to know the tracker's state.
    # This line USED to print "(issue #N still open, still broken)" — and "still open" was
    # PROSE IT NEVER CHECKED (#581). A live S0 (#567) was closed 2s after its pin merged, and
    # the gate kept asserting "still open" for a bug the tracker said did not exist. A pinned
    # fixture whose issue has been CLOSED is the PINNED-BUT-CLOSED contradiction; reconciling
    # it needs issue state, so it lives in test/must_fail_census.sh (nightly, has the API,
    # fails LOUD on an API blip and never silently). Putting a network read in THIS required
    # merge gate would make it fail OPEN on an api.github.com outage and block every merge —
    # worse than no check, and the exact failure mode the rest of this suite refuses to have.
    printf 'REPRO      %-46s (#%s: pin still reproduces — issue OPEN/CLOSED not checked here; see must_fail_census.sh)\n' "$name" "$issue"
  else
    drained=$((drained+1))
    printf 'DRAINED    %-46s (issue #%s)\n' "$name" "$issue"
    echo
    printf '  ✅ ISSUE #%s APPEARS FIXED — this is a GOOD failure, probably not your bug.\n' "$issue"
    printf '%s\n' "$what" | sed 's/^/     /'
    printf '     test/must_fail_fixtures/%s pinned the BROKEN behavior of:\n' "$name"
    printf '       medaka %s %s\n' "$verb" "$file"
    printf '     ...and that behavior no longer holds:%b\n' "$fail"
    echo
    printf '     Its CONTROL still passes, so this is a real fix, not a broken environment.\n'
    printf '     DO THIS, IN THIS PR:\n'
    printf '       1. gh issue close %s --comment "fixed by <sha>; must-fail fixture drained"\n' "$issue"
    printf '       2. git rm -r test/must_fail_fixtures/%s\n' "$name"
    printf '          (or re-point it at a regression gate asserting the FIXED behavior)\n'
    echo
  fi
done

echo
printf 'checked %d fixtures: %d still reproduce, %d DRAINED, %d control-broke, %d malformed\n' \
  "$checked" "$repro" "$drained" "$broke" "$malformed"
[ "$dup_fail" -eq 0 ] || echo "corpus is MALFORMED: see the one-fixture-per-issue findings above"

# N == 0 must be a FAILURE, not a pass. A must-fail suite that graded nothing and
# printed green would be the exact bug this whole suite exists to prevent.
if [ "$checked" -eq 0 ]; then
  echo
  echo "FAIL: no fixtures found in $FIXDIR — a suite that checked NOTHING must never report green."
  exit 1
fi

if [ "$drained" -gt 0 ]; then
  echo
  echo "⭐ The tracker just drained itself. That is this gate's entire purpose — see the"
  echo "   per-fixture instructions above, close the issue(s), and delete the fixture(s)."
fi

[ $((drained + broke + malformed + dup_fail)) -eq 0 ]
