# Next-orchestrator handoff — Medaka, soak tail (2026-06-14)

You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

## Where things stand (local `main` = 869f156; nothing pushed — work lives on LOCAL main)
The big multi-session arc is essentially done. Verify current state, don't trust this verbatim:
- `cd /Users/val/medaka && git log --oneline -15 main` (the recent landings).
- `cd .claude/worktrees/imperative-wandering-cocke && export PATH="$HOME/.opam/5.4.1/bin:$PATH" && export MEDAKA_EMITTER=$PWD/medaka_emitter && make medaka && FORCE=1 bash test/build_oracles.sh && bash test/selfcompile_fixpoint.sh` (should print C3a YES / C3b YES — the decisive emitter gate).

DONE (don't re-do; full record in `PLAN.md` "Current status" + `PLAN-ARCHIVE.md` Stage-3/4 logs):
gate re-rooting (every correctness gate OCaml-free, `selfhost/REROOT-PLAN.md`); the
single-file/multi-module **driver collapse** (`selfhost/DRIVER-COLLAPSE-PLAN.md`, closes audit
§6; `medaka check` resolves imports); native dispatch gaps #55/#54/#50/#21 (the latter genuinely
solved, not contained); the map Foldable false-positive+SIGBUS; native stdlib test expansion;
fuzz_gen ported native; the cross-module **ctor-name collision** emitter fix (universal ctor
mangling); the **`argStampEnabled` eval-vs-emit dispatch unification** COMPLETE (eval now threads
dicts like emit — `selfhost/ARGSTAMP-UNIFY-PLAN.md`); emit-path Set-literal/mutual-rec dict fixes (#44).

## The standing goal: the SOAK, then gated `lib/` removal
Native is canonical; OCaml `lib/`+`bin/` is FROZEN in-tree as the differential oracle. **The
user's gate to delete `lib/` (memory `[[retirement-is-not-removal]]`): a clean day-or-two stretch
of native-only dev where we STOP hitting bugs/gaps.** We kept finding+fixing real bugs through
2026-06-14, so the clock effectively restarts from this checkpoint. Do NOT `rm lib/` until the
user explicitly calls the soak. Until then: keep native canonical, fix what real use surfaces,
keep all gates + fixpoint green.

## Open items (all durably documented — verify before acting; docs drift)
- **`lib/` removal** — soak-gated (above). The endgame.
- `eval_dict` 22/3 + batch 7/18 is the DOCUMENTED-GREEN baseline (`diff_selfhost_eval_dict.sh`
  header): the 3 fails = a method-level-constraint `foldMap : Monoid m =>` gap. NOT a regression.
- Deferred native-test modules: string (2 Unicode case-fold doctests), hash_map/hash_set
  (need byte-identical Int64-wrapping `hashInt`) — `diff_selfhost_test.sh` DEFERRED header.
- Stage-4 minor remainders: diagnostics-surfacing layer, coverage.ml/bench_runner.ml port — `PLAN.md`.
- `argStampEnabled` itself still has ~3 emit-only readers — a possible further-simplification
  follow-up (`ARGSTAMP-UNIFY-PLAN.md` §vestigiality). Not urgent.
- #11 full Num-polymorphic integer literals — `PLAN.md` (deferred, post-flip; not a gate).
- Memory holds the rest (`/Users/val/.claude/projects/-Users-val-medaka/memory/MEMORY.md` index):
  dispatch-gap history, the "parity probe is BLIND to equal-ON/OFF regressions → use
  diff_selfhost_eval_dict golden-diff" methodology, decided invariants.

## Non-negotiable operating rules (these cost real time this session — see ORCHESTRATING.md)
- **FORCE the oracle binaries:** `FORCE=1 bash test/build_oracles.sh` before ANY gate reading
  `test/bin/*` (`diff_selfhost_test`, `_eval_*`, the parity probe). `build_oracles.sh` mtime-skips
  rebuilds → a `typecheck.mdk`/`eval.mdk` change silently runs STALE source otherwise. Same for
  `./medaka` (rebuild via `make medaka`) and the parity probe binary (it doesn't auto-rebuild).
  A green/red on a stale binary means nothing.
- **The fixpoint is the decisive emitter gate.** Any change to `selfhost/types/typecheck.mdk`,
  `selfhost/eval/eval.mdk`, `selfhost/backend/*`, `selfhost/ir/*` is in the self-compiled emitter
  graph → `selfcompile_fixpoint.sh` C3a+C3b YES is MANDATORY.
- **Golden-diff, not convergence probes.** A probe comparing two modes (e.g. the argstamp parity
  probe) is BLIND to a regression that moves both modes the same wrong way. Gate on the OCaml
  golden (`diff_selfhost_eval_dict`, `diff_selfhost_test`, `diff_selfhost_build`).
- **Merge into LOCAL `main` via the MAIN checkout** (`cd /Users/val/medaka && git merge --ff-only
  <branch>`), then ASSERT it advanced (`git rev-parse main` == new tip). Never fetch/push.
  **Never `git checkout <sha>` in a worktree** (detaches HEAD; merges then strand commits on a
  dangling line — happened this session). Use `git reset --hard <sha>` on the branch.
- **Agent prompts:** STEP 0 = `git merge main` + a `git merge-base --is-ancestor <expected-tip>
  HEAD && echo BASE_OK` assert (an agent silently built on a stale base this session). Hand the
  agent the verified root cause + file:line; a STOP-with-precise-diagnosis is a success, not a
  failure (the gap docs are systematically stale — tell agents to reproduce + disprove the
  hypothesis on current main). Agents commit on THEIR branch + report the SHA; YOU verify + merge.
- **Bounded orchestrator reading:** scope-read just enough to frame a precise prompt; delegate
  deep exploration to read-only agents; keep conclusions, not file dumps.
- **Seed:** emitter-graph changes leave the gz seed (`selfhost/seed/emitter.ll.gz`) stale; agents
  do NOT re-mint (they rely on the fixpoint). The ORCHESTRATOR re-mints
  (`CHECK_OCAML=0 bash test/refresh_seed.sh` → verify `bootstrap_from_seed.sh`) only at real
  checkpoints. Currently FRESH (re-minted at 73a1958).
- Build in the worktree with `dune build --root .`; never `dune test` (hangs); opam env is pre-set
  (no `eval $(opam env)`). The task list is SESSION-LOCAL — durable items go in PLAN.md/docs/memory.

## How to start
Ask the user what they want, or — if told to proceed autonomously — pick the highest-value open
item that advances the soak (likely: close one of the documented gaps above, or chase whatever a
real-use bug report surfaces). For anything non-trivial, scope read-only first, present the plan,
then delegate + verify + merge. Surface genuine design decisions as questions; act on sensible
defaults otherwise.
