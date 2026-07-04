# HANDOFF.md — start here (next session)

> **Live handoff for the next agent.** Read this first, then the owning docs it
> links. Current phase = the **0.1.0 public preview** north star. When you finish a
> chunk, update this file (or delete it once the workstream has a stable home in
> PLAN.md). For build/test mechanics and non-obvious gotchas, see `AGENTS.md`.

## Where we are (2026-07-04)

New north star landed: **ship a public 0.1.0 preview** of Medaka. The compiler is
mature; the remaining distance is outward-facing surface (distribution, a front
door, docs, release hygiene). Full plan + workstreams:

- **[`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md)** — the release hub: the
  funnel (playground front door → native download), floor vs ceiling, all nine
  workstreams (W1–W9 + showcase + error-quality freeze).
- **[`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md)** — native-binary
  packaging design + the repo-dependency blocker map + the phased plan (D0–D5).
- `PLAN.md` — hub: new north-star section, Workstreams table rows, Open-issues
  index entries for every 0.1.0 item.

**Distribution decision (settled with Val):** 0.1.0 ships BOTH a polished
playground (front door, zero-install, already built) AND a downloadable native
`medaka build` binary for macOS + Linux (the "do something real" path — the
playground can't do fs/net in the browser sandbox). Native build is confirmed
viable (see below).

## What's DONE

- ✅ **D0 Linux native-build spike — GREEN.** Full pipeline builds + runs on a
  Docker `ubuntu:24.04` aarch64 container: cold-bootstrap from the seed →
  `medaka` CLI → `medaka run` and `medaka build` a hello program → native ELF that
  runs. No structural blocker.
- ✅ Dependency audit, stack-threshold sweep, and gdb backtrace of the overflow
  (see next section). Reusable harness committed at
  [`dist/linux-spike/`](./dist/linux-spike/) — `sh dist/linux-spike/run.sh spike`.

## The key finding you need (native stack overflow)

The deeply-recursive compiler needs a large stack on Linux (macOS bakes 512MB via
a link flag GNU ld rejects). Measured: self-compile emit needs **~32MB @ -O2 /
~128MB @ -O0** (Linux's 8MB default segfaults). **The gdb backtrace proves the
overflow is 100% the lexer** — 37k+ frames of
`scan → scanAt → {scanOp|scanUpper|singleOp|handleNewline|afterNl} :: scan`,
i.e. the token-spine cons build. This is exactly the WasmGC `b′`
"dispatch-into-single-target" TMC shape native lacks and wasm already fixed
(`compiler/WASMGC-TRMC-DESIGN.md` §1). Details: `DISTRIBUTION-DESIGN.md` §3a.

## NEXT ACTIONS (ranked, with where each lands)

Everything below is bounded/mechanical except the TMC port (a real but
well-scoped codegen change). None of it gates on the others except as noted.

1. **D2 Track 1 — big-stack `pthread` (0.1.0 baseline, ~hours). START HERE.**
   Run the compiler on a spawned thread with a 256MB stack on BOTH platforms;
   drop the Mach-O `-Wl,-stack_size` flag; add `-lm` to all clang link lines;
   make GC/clang detection Linux-clean. Lands in: `runtime/medaka_rt.c` (thread
   entry / stack provisioning) + `test/build_native_medaka.sh` +
   `test/bootstrap_from_seed.sh` + `compiler/driver/build_cmd.mdk` (link flags).
   ⚠️ Touching `medaka_rt.c` / the emitter link path can perturb emitted IR →
   expect a **seed re-mint + fixpoint re-validation** (`test/refresh_seed.sh`);
   batch it. Verify on the Linux harness: `sh dist/linux-spike/run.sh spike`
   should pass at the DEFAULT 8MB once the compiler self-provisions its stack.

2. **D1 — exe-relative stdlib discovery (mechanical).** Add an executable-path
   primitive (`_NSGetExecutablePath` mac / `readlink /proc/self/exe` linux) and
   default `MEDAKA_ROOT` to a path relative to the binary, so a relocated `medaka`
   finds its own stdlib. Collapses the two-binary `MEDAKA_EMITTER` ritual too.
   Lands in: `stdlib/runtime.mdk` (extern decl) + `compiler/eval/eval.mdk` (interp
   impl) + native path + `compiler/driver/medaka_cli.mdk` (the `MEDAKA_ROOT`
   defaulting). Use the `add-primitive` skill. Also a seed re-mint. This is the
   keystone relocatability fix — needed by ANY distribution (interpreter too).

3. **D3/D4 — install layout + Homebrew + Linux tarball + release CI matrix.**
   Package manager handles clang/libgc; tagged CI produces mac+linux artifacts.
   See `DISTRIBUTION-DESIGN.md` §5.

4. **Track 2 (fast-follow, independent) — port WasmGC `b′` TMC to native.** Fixes
   the lexer overflow at root, closes a native↔wasm parity gap, hardens vs
   pathologically long lists. NOT a 0.1.0 blocker (Track 1 covers correctness).
   Template: `compiler/WASMGC-TRMC-DESIGN.md` §1 + §11 (AS BUILT). Lands in the
   native emitter (`compiler/backend/llvm_emit.mdk` + `trmc_analysis.mdk`). Scope
   it off the backtrace (the exact functions are `lexer.mdk`'s `scan`/`scanAt`/
   per-kind scanners). Reach for the `add-language-feature`-style cross-cutting
   care, and verify with the Linux harness at 8MB (should pass with NO big stack
   once `b′` linearizes the token spine).

5. **Track 3 (capstone) — recursion-depth guard.** Clean `expression nesting too
   deep` diagnostic instead of a segfault on adversarial deep input. Makes "never
   crash on any input" true (with Track 1). Aligns with the error-quality
   workstream (`project_error_quality_workstream`).

Other 0.1.0 floor items (parallel, independent of the above): playground polish
(W2), Val-authored quickstart (W3, Val only), stdlib docs (W4), public repo +
LICENSE + KNOWN-GAPS (W5–W7), `--version` + release CI (W8), `.vsix` (W9). Side
quest: fs/net in the interpreter (`RELEASE-0.1.0-PLAN.md` §4).

## Gotchas for this workstream

- **Worktree:** this is the `splendid-soaring-sphinx` worktree. Build with
  `make -C <abs-worktree-path> medaka`; edit only worktree-absolute paths (shell
  cwd resets to the main checkout between calls — see `AGENTS.md`).
- **Seed re-mint:** any change that perturbs emitted IR (Track 1 runtime/link,
  D1 exe-path extern, Track 2 emitter) forces `test/refresh_seed.sh` + a fixpoint
  re-validation. Batch re-mints at checkpoints, don't do one per sub-change.
- **Linux harness reflects the WORKING TREE** (uncommitted edits included), so you
  can iterate on `lexer.mdk` / build scripts and re-run without committing. It
  regenerates `dist/linux-spike/repo.tar` each run (gitignored).
- **`main` moves under you** (active error-quality work in other sessions). Merge
  main before starting; expect PLAN.md conflicts (resolve by keeping both status
  entries).
