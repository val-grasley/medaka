#!/bin/sh
# banned-oracle-cmd: self-referential
#   ^ opts this file out of test/check_no_banned_oracle_cmd.sh, which forbids any script
#     from PRINTING the bare `sh test/build_oracles.sh` — it builds every oracle and spawns
#     the xargs -P pool AGENTS.md documents as having killed several agents (#527). This
#     file IS the tool, not a caller: its own usage text must name it. Nothing else may.
# build_oracles.sh — compile the compiler STAGE ENTRIES the OCaml-free gates need
# into native binaries under test/bin/<entry>, via the native `./medaka build`.
#
# This is the category-C re-root build step (REROOT-PLAN.md §3b / Phase 2): each
# gate that used to host a compiler entry on the OCaml interpreter
# (`main.exe run compiler/entries/<entry>.mdk …`) instead runs the pre-compiled
# native binary `test/bin/<entry>` with the SAME positional args. Building these
# binaries is the whole OCaml-removal lever for those gates — no OCaml at gate time.
#
# Design:
#   * Idempotent: a binary is rebuilt only if it is older than ANY compiler/**.mdk
#     (or absent). FORCE=1 rebuilds unconditionally.
#   * Bootstraps ./medaka + ./medaka_emitter (warm `make medaka`) if absent — both
#     are OCaml-free (cold path bootstraps from the gz seed).
#   * Opt-in: skips cleanly (exit 2) when clang/libgc are absent, mirroring the
#     other native scripts (build_native_medaka.sh / diff_native_cli.sh).
#
# ENTRIES table below lists every entry a re-rooted gate consumes. Add a row when
# a new gate is re-rooted onto a native oracle.
#
# Usage:   sh test/build_oracles.sh          # build stale/missing oracles
#          FORCE=1 sh test/build_oracles.sh   # rebuild all
#          sh test/build_oracles.sh --list    # list every oracle name this script
#                                              # can build (builds nothing)
#          sh test/build_oracles.sh --build-one <entry>       # build exactly one
#          sh test/build_oracles.sh --for '<gate-pattern>' …  # build only what
#                                              # those gates read (see #398/#183)
# Exit:    0 built/up-to-date; 2 opt-in skip (no clang/libgc); 1 on a build error
#          or an unrecognized flag.
# ⚠️ An UNRECOGNIZED flag is a hard error (exit 1) — it does NOT fall through to
# build-all. Only truly NO ARGS means build-all; that is intentional (#474).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keep the build/test write-storm OUT OF RAM (/tmp is a RAM-backed tmpfs).
. "$ROOT/test/lib_scratch.sh"
mdk_warn_if_tmp_full
BINDIR="$ROOT/test/bin"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
CC="${CC:-clang}"

# ── Parallel worker mode ───────────────────────────────────────────────────────
# The script re-invokes itself as `sh "$0" --build-one <entry>` under an xargs -P
# pool (see the main loop). Each build is collision-free: the emitter reads shared
# source read-only; the per-entry .ll temp is keyed by the entry's unique basename;
# GC detection here uses `brew --prefix` (no shared temp file). So N builds run
# concurrently with no interference. Worker exits 0 on success, 1 on failure.
if [ "${1:-}" = "--build-one" ]; then
  e="$2"
  src="$ROOT/compiler/entries/$e.mdk"
  out="$BINDIR/$e"
  # A fresh worktree/clone has no test/bin (it is not committed). The MAIN path
  # mkdir's it, but this worker path did not — so `--build-one` on a fresh tree died
  # with `cannot create .../test/bin/<e>.buildlog: Directory nonexistent`, and then a
  # SECOND, misleading error (`tail: cannot open ... buildlog`) hid the real cause.
  # Reported by two separate agents who each lost time to it.
  mkdir -p "$BINDIR"
  printf 'building    %s ...\n' "$e"
  if ! ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" MEDAKA_CLANG_OPT="${ORACLE_OPT:--O0}" "$MEDAKA" build --allow-internal "$src" -o "$out" ) >"$BINDIR/$e.buildlog" 2>&1; then
    echo "FAIL: could not native-compile $e:" >&2; tail -8 "$BINDIR/$e.buildlog" >&2; exit 1
  fi
  [ -x "$out" ] || { echo "FAIL: $e build produced no binary" >&2; tail -8 "$BINDIR/$e.buildlog" >&2; exit 1; }
  rm -f "$BINDIR/$e.buildlog"
  exit 0
fi

# ── Entries the step-1 OCaml-free gates need (one per line; no extension) ──────
#   eval_run_main     — diff_compiler_eval_run.sh        (=== EVAL === goldens)
#   eval_run_batch    — diff_compiler_eval_run_batch.sh  (=== EVAL === goldens)
#   core_ir_run_main  — diff_compiler_core_ir_run.sh     (=== EVAL === goldens)
#   ── Phase 2 §2a value gates (eval / core-ir / llvm), goldens = .eval.golden
#      (llvm's own goldens are .native.golden as of #559 — see below) ──
#   eval_main             — diff_compiler_eval.sh
#   eval_prelude_main     — diff_compiler_eval_prelude.sh + diff_compiler_eval_list.sh
#   eval_prelude_batch    — diff_compiler_eval_prelude_batch.sh
#   eval_list_batch       — diff_compiler_eval_list_batch.sh
#   eval_dict_main        — fuzz_diff.sh (differential oracle) + capture_goldens.sh
#                           (regenerates eval_dict_fixtures/*.eval.golden for the batch
#                            gate). Its own single-file gate migrated to the snapshot
#                            # EVAL section (diff_compiler_snapshot_eval.sh), #81 R6.
#   eval_dict_batch       — diff_compiler_eval_dict_batch.sh
#   eval_typed_main       — capture_goldens.sh (regenerates eval_typed_fixtures/
#                            *.eval.golden for the batch gate). Its own single-file gate
#                            migrated to the snapshot # EVAL section
#                            (diff_compiler_snapshot_eval.sh), #81 R6.
#   eval_typed_batch      — diff_compiler_eval_typed_batch.sh
#   eval_typed_modules_main — diff_compiler_eval_typed_modules.sh
#   eval_modules_main     — diff_compiler_eval_modules.sh
#   core_ir_main          — diff_compiler_core_ir.sh
#   core_ir_prelude_main  — diff_compiler_core_ir_prelude.sh + diff_compiler_core_ir_list.sh
#   core_ir_typed_main    — diff_compiler_core_ir_typed.sh
#   core_ir_roundtrip_main — diff_compiler_core_ir_roundtrip.sh
#   core_ir_modules_main  — diff_compiler_core_ir_modules.sh
#   llvm_emit_main        — diff_compiler_llvm.sh        (emit → clang → run vs .native.golden)
#   llvm_emit_typed_main  — diff_compiler_llvm_typed.sh
#   core_ir_dict_pp_main  — diff_compiler_llvm_typed.sh CAPTURE=1 (#485): the typed
#                           Core-IR tree-walker oracle the gate's .eval.golden files
#                           are captured FROM (see STAGE2-DESIGN.md §2.4a; the gate's
#                           own CAPTURE branch cross-checks it against compiled
#                           `self` output before writing, so a known oracle gap —
#                           e.g. a Unit-typed `main`, STAGE2-DESIGN.md 2.4a-9 (ff) —
#                           is reported, never silently written)
#   llvm_emit_modules_main — diff_compiler_llvm_modules.sh
#   eval_autoprint_main   — diff_compiler_engines.sh    (the INTERPRETER arm of the
#                           3-engine differential: `medaka run`'s exact eval path plus
#                           driver/main_autoprint's value-main wrap, so eval honours the
#                           same auto-print contract `medaka build` and wasm_emit do)
#   ── Phase 2 §2b front-end gates, goldens captured from dev probes ──
#   lex_main              — diff_compiler_lex_files.sh / bootstrap_lex.sh / selfcompile_lex.sh
#                           (diff_compiler_lexer.sh MIGRATED to the # TOKENS section of
#                           test/diff_compiler_snapshot_frontend.sh, #81 R4; lex_main
#                           survives because those three still drive it)
#   parse_main            — diff_compiler_parse_errors.sh
#   parse_result_main     — diff_compiler_parse_result.sh
#   (parse/desugar/mark:  MIGRATED to test/diff_compiler_snapshot_frontend.sh — the
#                         snapshot runner calls the stages in-process, so those five
#                         gates need no probe binary at all.  parse_main survives only
#                         because diff_compiler_parse_errors.sh still drives it.)
#   resolve_main          — diff_compiler_resolve.sh
#   resolve_batch         — diff_compiler_resolve_batch.sh
#   resolve_modules_main  — diff_compiler_resolve_modules.sh
#   ── Phase 2 §2b typecheck/check/error gates ──
#   typecheck_main          — diff_compiler_typecheck_errors.sh
#                             (was also _typecheck.sh + _panic_errors.sh — migrated to the
#                              TYPES snapshot family diff_compiler_snapshot_types.sh, #81 R5;
#                              and _golden/_golden_batch — RETIRED #81 Stage B1: the
#                              whole-prelude-inference invariant moved to the single
#                              diff_compiler_snapshot_prelude.sh dump, per-fixture user
#                              schemes to # TYPES_USER; typecheck_golden_batch had no other
#                              consumer, so its oracle + entry source went with them)
#   check_main              — diff_compiler_typecheck_errors.sh (driver B) / diff_compiler_check.sh
#   check_batch             — diff_compiler_check_batch.sh
#   check_modules_main      — diff_compiler_check_modules.sh
#   check_all_main          — diff_compiler_selfproc.sh (LEG A)
#   check_match_main        — diff_compiler_check_match.sh
#   exhaust_main            — diff_compiler_exhaust.sh
#   lint_main               — diff_compiler_lint.sh (added by the lint workstream)
#   diagnostics_main        — diff_compiler_diagnostics.sh
#   diagnostics_project_main — diff_compiler_analyze_project.sh
#   ── Phase 2 §2c tooling gates (fmt/new/test/repl/lsp) ──
#   fmt_main    — diff_compiler_fmt.sh        (native host vs .fmt.golden)
#   new_main    — diff_compiler_new.sh        (native scaffold tree vs golden tree)
#   test_main   — diff_compiler_test.sh       (native test report vs .test.golden)
#   repl_main   — diff_compiler_repl.sh       (SKIPPED re-root; see capture_goldens.sh)
#   (lsp_main is NOT a build target: `medaka build lsp_main.mdk` fails the native G1
#    typecheck gate — tools.lsp imports don't resolve under the build path's roots.
#    The 3 lsp gates stay on the OCaml oracle.  See REROOT-PLAN STOP guardrail.)
ENTRIES="eval_run_main eval_run_batch core_ir_run_main \
eval_main eval_prelude_main eval_prelude_batch eval_list_batch \
eval_dict_main eval_dict_batch eval_typed_main eval_typed_batch \
eval_typed_modules_main eval_modules_main eval_autoprint_main \
core_ir_main core_ir_prelude_main core_ir_typed_main core_ir_roundtrip_main core_ir_modules_main \
core_ir_dict_pp_main \
llvm_emit_main llvm_emit_typed_main llvm_emit_modules_main \
llvm_bootstrap_lex_main \
lex_main parse_main parse_result_main \
resolve_main resolve_batch resolve_modules_main \
typecheck_main check_main check_batch \
check_modules_main check_all_main check_match_main exhaust_main lint_main lint_fix_main \
diagnostics_main diagnostics_project_main \
fmt_main new_main test_main repl_main fuzz_gen_main \
 profile_main profile_modules_main refindex_main"

# ── --list : print every oracle name this script knows how to build ───────────
# Derived from $ENTRIES (the single source of truth a few lines up), never
# hand-maintained — so it cannot drift from what --build-one/--for actually see.
# Needs no clang/libgc (runs before that check) and builds nothing.
if [ "${1:-}" = "--list" ]; then
  printf '%s\n' $ENTRIES
  exit 0
fi

# ── Catch-all: an UNRECOGNIZED first arg is an error, not a silent build-all ───
# (#474). Before this fix, a typo'd or unimplemented flag (`--help`, `--list`
# before this fix existed, any fat-fingered `--build-one`/`--for`) fell through
# every `if` below and landed on the default path: build ALL of $ENTRIES,
# spawning the xargs -P pool that AGENTS.md documents as having killed agents.
# `--build-one` is handled (and exits) above this point; `--for` is handled (and
# does NOT shift $1 away) below — so by the time this case runs, the only
# LEGITIMATE values left for $1 are unset/empty (build-all — must stay that way)
# or `--for` (falls through on purpose to the block that consumes it).
case "${1:-}" in
  ''|--for) ;;
  *)
    echo "FAIL: unknown argument: ${1:-}" >&2
    echo "usage: $0 [--list | --build-one <entry> | --for '<gate-pattern>' ...]" >&2
    echo "       (no args = build all $(printf '%s\n' $ENTRIES | grep -vc '^$') oracles)" >&2
    exit 1
    ;;
esac

# ── Opt-in skip when clang/libgc absent (mirror the other native scripts) ──────
command -v "$CC" >/dev/null 2>&1 || {
  echo "no C compiler ($CC) on PATH — skipping (opt-in)"; exit 2; }
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  :
elif [ -n "${GC_PREFIX:-}" ] && [ -d "${GC_PREFIX}" ]; then
  :
elif [ -d /opt/homebrew/include/gc ] || [ -d /usr/local/include/gc ] || [ -d /usr/include/gc ]; then
  :
else
  echo "libgc (bdw-gc) not found — skipping (opt-in; install bdw-gc or set GC_PREFIX)"; exit 2
fi

mkdir -p "$BINDIR"

# ── Ensure the native compiler exists (OCaml-free; warm make path) ─────────────
if [ ! -x "$MEDAKA" ] || [ ! -x "$EMITTER" ]; then
  echo "native medaka/emitter absent — bootstrapping via 'make medaka' (OCaml-free) ..."
  ( cd "$ROOT" && make medaka ) || { echo "FAIL: could not build ./medaka"; exit 1; }
fi
[ -x "$MEDAKA" ] && [ -x "$EMITTER" ] || { echo "FAIL: ./medaka or ./medaka_emitter still missing"; exit 1; }

# ── newest source mtime across everything an oracle links — any source newer
# than a binary => rebuild it. This MUST cover stdlib/*.mdk and runtime/*.c(.h)
# too: every test/bin/* oracle links stdlib/*.mdk and runtime/medaka_rt.c, so
# scanning only compiler/**.mdk left all 53 oracles silently stale whenever the
# stdlib or C runtime changed (a one-line bug — see AGENTS.md staleness gotcha).
newest_src=0
for f in $(find "$ROOT/compiler" "$ROOT/stdlib" -name '*.mdk'; find "$ROOT/runtime" -name '*.c' -o -name '*.h'); do
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  [ "$m" -gt "$newest_src" ] && newest_src=$m
done

# ── `--for <gate-pattern>...` : build ONLY the oracles those gates actually read ──
#
# Building all 54 oracles is 54 × (medaka build + clang). That is the single most
# expensive thing in the whole test system: measured at ~34s on a 12-core box but
# **18+ minutes on a 2-core CI runner**, where it was 93% of the build job (the
# cold bootstrap from seed, by contrast, is only 80s).
#
# But no gate needs all 54. A gate names its oracle as `test/bin/<name>`, so the
# set is derivable from the gate scripts themselves — no hand-maintained mapping to
# drift. Per-shard need: engines 2, frontend 14, types 10, eval 19, backend 6,
# tools 6. So CI shards build ~19 max, concurrently, instead of 54 serially; and
# `test/preflight.sh` uses the same derivation so an agent touching the parser
# builds 9, not 54.
#
#   sh test/build_oracles.sh --for 'diff_compiler_parse*' 'diff_compiler_fmt'
#
# The derivation is intentionally shared with preflight.sh and the CI matrix: ONE
# source of truth for "which oracle does this gate read".
if [ "${1:-}" = "--for" ]; then
  shift
  [ "$#" -gt 0 ] || { echo "usage: $0 --for '<gate-pattern>' ..."; exit 1; }
  # A pattern resolves against BOTH $ROOT/test/ and $ROOT/ — same rule as
  # run_gates.sh and diff_compiler_ci_shard_coverage.sh, so a shard pattern naming a
  # gate outside test/ (e.g. 'sqlite/test/*_oracle') selects the same gate set in all
  # three. A bare 'diff_compiler_*' matches nothing at the repo root, so this is
  # backwards-compatible. (Gates outside test/ read no test/bin oracle, so they
  # simply contribute none — but they must still RESOLVE, or --for would report
  # "matched no gates" for a shard whose patterns are all outside test/.)
  _gates=""
  for _pat in "$@"; do
    for _g in "$ROOT"/test/$_pat.sh "$ROOT"/$_pat.sh; do
      [ -f "$_g" ] || continue
      case " $_gates " in *" $_g "*) ;; *) _gates="$_gates $_g" ;; esac
    done
  done
  [ -n "$_gates" ] || { echo "FAIL: --for matched no gates: $*"; exit 1; }
  _sel=""
  _foreign=""
  for _g in $_gates; do
    for _o in $(grep -ohE 'test/bin/[a-z_0-9]+' "$_g" 2>/dev/null | sed 's|test/bin/||' | sort -u); do
      # only accept names that are real entries — a gate may mention a path we
      # don't build, and silently "building" a non-entry would be a lie.
      case " $ENTRIES " in
        *" $_o "*) case " $_sel " in *" $_o "*) ;; *) _sel="$_sel $_o" ;; esac ;;
        # A test/bin/<name> this script does NOT know how to build. Until 2026-07-13 we
        # DROPPED these silently — and that is a phantom-FAIL generator, because the gate
        # still READS them. The emit probes (llvm_emit_main, wasm_emit_main,
        # wasm_emit_modules_main) are not in ENTRIES at all; they are built by
        # test/wasm/build_wasm_oracle.sh. So the documented fresh-worktree recipe
        # (`--for 'diff_compiler_*'`) left diff_compiler_tmc_parity with no probes and it
        # failed with "missing test/bin/wasm_emit_modules_main" — a red gate for no reason,
        # on a clean tree, following the instructions. An agent lost time to exactly this.
        #
        # Dropping is still the right behavior (we genuinely cannot build them here). SAYING
        # NOTHING was the bug. Now it names them and names the script that does build them.
        *) case " $_foreign " in *" $_o "*) ;; *) _foreign="$_foreign $_o" ;; esac ;;
      esac
    done
  done
  # ── "needs no oracles" IS NOT "pattern matched nothing" ──────────────────────
  #
  # This used to `exit 1` with "FAIL: --for selected no oracles", conflating two
  # conditions that could not be more different:
  #
  #   pattern matched NO GATES        -> a typo. A real error. Still fails loudly,
  #                                      via the `_gates` check above.
  #   gates matched, need NO ORACLES  -> a legitimate no-op. Must SUCCEED.
  #
  # Plenty of gates drive ./medaka directly and reference zero test/bin/* probes:
  # diff_compiler_run_check_agreement, build_cmd, native_fixtures/run, and all 22
  # sqlite/test/*oracle gates. Failing on those broke two things at once — a CI shard
  # made only of such gates went red for having nothing to build, and `make preflight`
  # DIED on its single most common workflow: "I fixed a compiler bug, so I added a
  # regression fixture", which now correctly derives 1 consuming gate instead of 83 and
  # then fell over here if that gate happened to need no oracle.
  if [ -z "$_sel" ]; then
    for _g in $_gates; do
      echo "--for: $(basename "$_g" .sh) needs no oracles (drives ./medaka directly)."
    done
    echo "nothing to build."
    exit 0
  fi
  if [ -n "$_foreign" ]; then
    echo "note: these gates also read probe binaries this script does not build:$_foreign"
    echo "      build them with:  sh test/wasm/build_wasm_oracle.sh"
    echo "      (skipping them here is correct — but they are NOT optional for those gates.)"
  fi
  printf 'building %s of %s oracles (only what these gates read)\n' \
    "$(printf '%s\n' $_sel | grep -vc '^$')" "$(printf '%s\n' $ENTRIES | grep -vc '^$')"
  ENTRIES="$_sel"
fi

# ── Worklist: which entries actually need (re)building ─────────────────────────
# The probe entries are COMPILER internals (compiler/entries/*) whose graphs use
# the internal-only array-kernel externs (arrayGetUnsafe, …); the worker passes
# --allow-internal so the resolve-phase guard trusts them (part of this project).
worklist=""
uptodate=0
for e in $ENTRIES; do
  src="$ROOT/compiler/entries/$e.mdk"
  out="$BINDIR/$e"
  [ -f "$src" ] || { echo "FAIL: missing entry $src"; exit 1; }
  if [ "${FORCE:-0}" != "1" ] && [ -x "$out" ]; then
    bm=$(stat -c %Y "$out" 2>/dev/null || stat -f %m "$out" 2>/dev/null)
    if [ "$bm" -ge "$newest_src" ]; then
      uptodate=$((uptodate+1)); printf 'up-to-date  %s\n' "$e"; continue
    fi
  fi
  worklist="$worklist $e"
done

# ── CI FAST PATH: precompile the C runtime object ONCE ─────────────────────────
# Every --build-one worker otherwise recompiles the byte-identical
# runtime/medaka_rt.c from scratch (~0.6s of clang each). Precompile it ONCE at the
# SAME opt level the workers link at (ORACLE_OPT, default -O0 — CRITICAL: a mismatch
# would make the object incompatible), then export MEDAKA_RT_OBJ; each worker
# inherits it (env passes through `sh "$0" --build-one`) and LINKS the object rather
# than recompiling. The compiler emits the object (`--emit-rt-obj`) with exactly the
# flags its own link uses, so it can't drift; inline-vs-prebuilt is proven
# byte-identical by test/diff_compiler_rt_obj.sh. Best-effort: on failure we don't
# export it and every build falls back to the (unchanged) inline compile.
#
# ── CI FAST PATH #2: precompile the PRELUDE object ONCE (issue #118) ───────────
# Same trick, one level up, and a bigger win: the prelude is 88% of a small
# program's emitted IR, so without this every worker hands clang ~10k lines of
# identical prelude to re-optimise. Precompiled at the SAME ORACLE_OPT the workers
# link at (the same CRITICAL constraint as the runtime object: the compiler reads
# MEDAKA_CLANG_OPT for both, so a mismatch cannot arise as long as both are built
# with the same value here). Two link paths, identically-behaving programs — proven
# by test/diff_compiler_prelude_obj.sh. Best-effort, exactly as above.
if [ -n "$worklist" ]; then
  _rtobjdir="$(mktemp -d)"
  trap 'rm -rf "$_rtobjdir"' EXIT
  _rtobj="$_rtobjdir/medaka_rt.o"
  if ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" MEDAKA_CLANG_OPT="${ORACLE_OPT:--O0}" \
         "$MEDAKA" build --emit-rt-obj "$_rtobj" ) >/dev/null 2>&1 && [ -f "$_rtobj" ]; then
    export MEDAKA_RT_OBJ="$_rtobj"
  fi
  _preludeobj="$_rtobjdir/prelude.o"
  if ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" MEDAKA_CLANG_OPT="${ORACLE_OPT:--O0}" \
         "$MEDAKA" build --emit-prelude-obj "$_preludeobj" ) >/dev/null 2>&1 && [ -f "$_preludeobj" ]; then
    export MEDAKA_PRELUDE_OBJ="$_preludeobj"
  fi
fi

# ── Parallel build via an xargs -P job pool ────────────────────────────────────
# Default concurrency = logical CPU count (override with JOBS=n). Each build is a
# self-reinvocation (`sh "$0" --build-one <e>`); xargs exits non-zero if any fails.
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
built=0
rc=0
if [ -n "$worklist" ]; then
  built=$(printf '%s\n' $worklist | wc -l | tr -d ' ')
  printf '%s\n' $worklist \
    | xargs -P "$JOBS" -n 1 sh "$0" --build-one \
    || rc=$?
fi
[ "$rc" = 0 ] || { echo "FAIL: one or more oracle builds failed (see FAIL lines above)"; exit 1; }

printf '\noracles ready in %s (%d built, %d up-to-date, JOBS=%s)\n' "$BINDIR" "$built" "$uptodate" "$JOBS"
