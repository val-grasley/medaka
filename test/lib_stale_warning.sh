# test/lib_stale_warning.sh — shared helper for gates that capture ./medaka's
# combined stdout+stderr (2>&1) and compare it to a golden. #482: the CLI's
# source-staleness self-check (checkSourceStaleness, compiler/driver/
# medaka_cli.mdk) prints a WARNING on stderr on every invocation where the
# binary's baked-in compiler fingerprint no longer matches the sources on
# disk -- correctly (editing compiler/**/*.mdk without a `make medaka`
# really does make the binary stale). But a `2>&1` capture folds that
# warning into the text a gate compares, and turns "you forgot to rebuild"
# into an opaque "FAIL differing sections: CRASH" / raw byte-diff that reads
# exactly like a real regression.
#
# Fix shape (#482 option 3, the owner's pick): do NOT strip the warning
# before comparing -- that would silently tolerate OTHER stderr noise too,
# which is exactly the rejected option 1 -- and do NOT suppress it, it is a
# real signal for humans (rejected option 2). Compare the RAW captured text
# first, exactly as before; only if that disagrees, check whether the
# disagreement IS (or contains) the warning, and if so say so in the FAIL
# message instead of leaving an opaque CRASH/raw-diff to be bisected.
#
# The marker is DERIVED from medaka_cli.mdk's own source at test time, not
# hand-copied, so a wording change to the sentence does not rot this file --
# it just changes what gets read out live (and if the source no longer has
# the expected shape, mdk_stale_marker returns "" rather than a stale
# guess, so every function below degrades to "can't tell", never "wrong").
#
# Usage: source AFTER ROOT is set --  . "$ROOT/test/lib_stale_warning.sh"

# mdk_stale_marker
# Echoes the fixed (non-variable) PREFIX of the staleness warning, read live
# from compiler/driver/medaka_cli.mdk's:
#   let msg = "warning: this ./medaka was built ... differs from " ++ compilerDir ++ " ..."
# i.e. everything up to where the variable compilerDir is spliced in.
# Echoes "" if that source no longer has this shape.
mdk_stale_marker() {
  _mdk_cli="${MDK_CLI_SRC:-${ROOT:-.}/compiler/driver/medaka_cli.mdk}"
  [ -f "$_mdk_cli" ] || return 0
  sed -n 's/.*let msg = "\([^"]*\)" ++ compilerDir.*/\1/p' "$_mdk_cli" | head -1
}

# mdk_is_stale <text>
# True (exit 0) iff <text> contains the marker.
mdk_is_stale() {
  _is_marker="$(mdk_stale_marker)"
  [ -n "$_is_marker" ] && printf '%s\n' "$1" | grep -qF "$_is_marker"
}

# mdk_strip_stale <text>
# <text> with any line containing the marker removed. For MATCHING/TESTING
# convenience only (e.g. a prefix-anchored `case` pattern that never meant to
# assert anything about a leading stderr banner) -- never use this ahead of a
# byte-exact comparison, which must see the raw text so it still catches a
# real regression that happens to land in the same output.
mdk_strip_stale() {
  _ss_marker="$(mdk_stale_marker)"
  if [ -n "$_ss_marker" ]; then
    printf '%s\n' "$1" | grep -vF "$_ss_marker"
  else
    printf '%s\n' "$1"
  fi
}

# mdk_stale_suffix <text>
# "" normally; a short bracketed note if <text> contains the marker, meant to
# be appended (via %s) to an existing FAIL/ok printf so the warning is never
# silently present-but-unremarked-on.
mdk_stale_suffix() {
  if mdk_is_stale "$1"; then
    printf " [ALSO: this ./medaka reports itself stale -- rebuild with 'make medaka' and retry]"
  fi
}

# mdk_classify_diff <actual> <golden>
# Echoes one word:
#   MATCH            actual == golden, byte for byte
#   STALE_ONLY       they differ, but ONLY because actual has one extra line
#                    containing the stale-binary marker -- remove that line
#                    and they match exactly
#   STALE_PLUS_DIFF  actual has the marker AND still differs after removing
#                    it (a real difference, possibly ALSO stale -- never
#                    silently swallowed into either bucket alone)
#   DIFF             plain difference, marker not involved
mdk_classify_diff() {
  _cd_a="$1"; _cd_g="$2"
  if [ "$_cd_a" = "$_cd_g" ]; then echo MATCH; return 0; fi
  _cd_marker="$(mdk_stale_marker)"
  if [ -n "$_cd_marker" ] && printf '%s\n' "$_cd_a" | grep -qF "$_cd_marker"; then
    _cd_stripped="$(printf '%s\n' "$_cd_a" | grep -vF "$_cd_marker")"
    if [ "$_cd_stripped" = "$_cd_g" ]; then echo STALE_ONLY; else echo STALE_PLUS_DIFF; fi
  else
    echo DIFF
  fi
}

# mdk_stale_fail_line <name>
# The one-line message for the STALE_ONLY case -- #482's chosen wording.
mdk_stale_fail_line() {
  printf "FAIL %s -- output contains the stale-binary warning; run 'make medaka' and retry\n" "$1"
}

# mdk_stale_note
# One-line addendum for the STALE_PLUS_DIFF case: the warning is present but
# does not fully explain the divergence -- surface both, pick neither.
mdk_stale_note() {
  printf "  note: output ALSO contains the stale-binary warning -- run 'make medaka' and retry (a real difference remains below)\n"
}

# mdk_snapshot_section_stale_reason <medaka-bin> <root> <fixture.mdk> <stages> <golden.md> <section-name>
# Only meaningful right after a `medaka snapshot --check` reports fixture
# <fixture.mdk> FAIL on <section-name> against <golden.md>. The tool's own
# --check verdict never exposes the actual differing text (only "FAIL
# differing sections: CRASH"), and that text is rendered IN-PROCESS -- there
# is no compiler-source change in scope here that could make it do so. So:
# re-render just this one fixture into a THROWAWAY --new scratch dir (never
# touches the real corpus; --new never overwrites), pull <section-name> out
# of both the fresh render and the committed golden with the same `# NAME`
# header grammar the tool itself uses, and classify via mdk_classify_diff.
# Echoes MATCH/STALE_ONLY/STALE_PLUS_DIFF/DIFF, or UNKNOWN if the golden or
# the fresh render is missing (never guesses).
mdk_snapshot_section_stale_reason() {
  _sr_bin="$1"; _sr_root="$2"; _sr_fixture="$3"; _sr_stages="$4"; _sr_golden="$5"; _sr_sec="$6"
  [ -f "$_sr_golden" ] || { echo UNKNOWN; return 0; }
  _sr_scratch="$(mktemp -d)"
  "$_sr_bin" snapshot --new --root "$_sr_root" --out "$_sr_scratch" --stages "$_sr_stages" "$_sr_fixture" >/dev/null 2>&1
  _sr_fresh="$_sr_scratch/$(basename "$_sr_fixture" .mdk).md"
  if [ ! -f "$_sr_fresh" ]; then rm -rf "$_sr_scratch"; echo UNKNOWN; return 0; fi
  _sr_want="$(awk -v s="# $_sr_sec" '$0==s{g=1;next} /^# /{g=0} g{print}' "$_sr_golden")"
  _sr_got="$(awk -v s="# $_sr_sec" '$0==s{g=1;next} /^# /{g=0} g{print}' "$_sr_fresh")"
  rm -rf "$_sr_scratch"
  mdk_classify_diff "$_sr_got" "$_sr_want"
}
