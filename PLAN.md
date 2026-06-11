# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-10)

**🏁 Medaka is a native self-hosting compiler.** The compiler is written in
Medaka (`selfhost/`), and the native **LLVM backend now compiles it**: all seven
pipeline stages (lex → parse → desugar → resolve → mark → typecheck → eval) are
native-compiled and **byte-identical to the tree-walker interpreter** (141
fixtures across `test/bootstrap_*.sh`), and the **self-compile fixpoint is
reached** — the native-compiled emitter emits the whole emitter graph (~10.6 MB
IR), reproduces the interpreter's IR byte-for-byte (C3a), and a second-generation
native emitter reproduces that IR exactly (C3b: `IR1 == IR2`). See
`selfhost/BOOTSTRAP.md` for the B1–B7 + C1–C3 log and `selfhost/EMITTER-GAPS.md`
for the closed/residual emitter gaps. The native lexer runs ~90× faster than the
tree-walker.

The **OCaml compiler** (`lib/*.ml`) remains the reference + the differential
oracle, and the build still bootstraps the first native compiler by running the
`.mdk` sources through the OCaml-hosted interpreter (`medaka run`). The near-term
roadmap ([Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml))
hardens the native backend toward making it **canonical** and retiring the OCaml
dependency on a **gated** schedule.

The OCaml compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — with phases through ~141 done (see PLAN-ARCHIVE.md). The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint), list
comprehensions, string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`), property testing, doctests, **unit tests**
(Phase 127), an LSP server, a formatter, and a project-config/`medaka new` surface.

The stdlib in Medaka is **complete** across `core`, `list`, `array`, `string`
(frozen, Phase 128), ordered `map`/`set`, mutable `hash_map`/`hash_set`,
`mut_array`, `io`, and `json` (STDLIB.md Modules 1–9 all done).

**Self-host (Stage 1) and the native backend (Stage 2)** are both ✅ COMPLETE —
all eight pipeline stages ported to Medaka and validated byte-for-byte, the
bootstrap closure landed for Legs A–D, and the LLVM backend promoted from spike to
a self-hosting native compiler (the C1–C3 fixpoint above). The forward-looking
interpreter-perf levers are all resolved (`selfhost/PERF-NOTES.md`).

**Conventions.** Work is organized by numbered **Phases**; commit messages and
code comments reference them. Phases left *partial* keep their original number
(e.g. Phase 83/84, 101); genuinely new work gets the next free number (last used:
150). At task triage, match the work against AGENTS.md's task-playbook table and
load the matching skill before planning.

---

## Workstreams — where each roadmap lives

PLAN.md is the **hub**. Each workstream below has an **owning doc** that holds the
detailed, living roadmap; this file keeps only the one-line status + a pointer.
Edit the owning doc for detail; update the status line here when a workstream's
state changes.

| Workstream | Owning roadmap | Status | Near-term items |
|------------|----------------|--------|-----------------|
| **Self-hosting (Stage 1)** | [`selfhost/README.md`](./selfhost/README.md) §Roadmap | ✅ complete | perf-lever tail only (all closed) |
| **Native backend (Stage 2)** | [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) + [`selfhost/BOOTSTRAP.md`](./selfhost/BOOTSTRAP.md) | ✅ **complete** | Core IR + bytecode VM (§2.1–2.2) done (bytecode VM removed 2026-06-10 — off canonical path); LLVM backend promoted from spike to a **native self-hosting compiler** — all 7 stages native==interpreter (141 fixtures), self-compile **fixpoint reached** (C1 emitter-IR reproduction · C2 native compiles the real lexer · C3 `IR1==IR2`). Runtime dict-passing dispatch (D3a/D3b done); Boehm GC; CTGuard lowered. Residual: `max`/`min` over primitive `Ord` (dead code). |
| **Make LLVM canonical (Stage 3)** | **this file** → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) | 🟡 **in progress** | **TYPECHECK-AUDIT autonomous phase ✅ (16: S1·S2·T1·T1b·T2·S3·C1·C2·C3·C6·C7·C8·C9·D1·D2·OBS4)**; construct-coverage matrix built + 10 gaps closed (**Gap E Float-corruption cluster fully closed** — garbage/SIGSEGV/lambda; range-pattern typecheck; backtick/newtype/let-mut/let-else native; stdlib-on-build-path); DCE `collectVars` soundness audited; bar-item-2 = 336 ported `medaka test` assertions. ✅ #1 `medaka build` + #2a/#2b. **Deferred for oversight (precise plans in CONSTRUCT-COVERAGE/TYPECHECK-AUDIT):** ✅ Gap G CLOSED (Phase 151 — operators dispatch to user `Eq`/`Ord` via A2 type-directed rewrite; interpreter+selfhost+native-`==`; native-`<` deferred behind slice-7), dict-pass cluster — **Cause B/L2 ✅ CLOSED** (`ba757de`, set builds natively, one-level nested reqs); **Cause A + per-module-arity promotion layer ✅ CLOSED** (2026-06-10 — `elaborateModules` now seeds `dictEligibleRef`, runs a joint promotion fixpoint, snapshots promoted arities across `resetState`, and uses per-module importer-scoped arity replacing the Phase-134 bare-name `seedDictAritiesFromSigs`; `recordArgSiteFn` surfaces arg-position inferred constraints; `f s = println s` builds native==oracle; Gap C C2/C3-unannotated closed; fixpoint byte-identical; residuals: Cause-B two-level, `debug`-on-List-element, lambda-bound constraint), Gap C (primitive arg-tag dispatch — C1/C5b tuple-as-tag remains), C5/L1/D-tail. Then: differential fuzzer ✅ → **perf ✅ (2026-06-11, bar-item 4, 5.68× self-compile / ~59× vs interp — PERF-RESULTS.md)** → stack scalability (TRMC #56) → housekeeping → retire `lib/` (gated). |
| **Capability-effects wedge (Phase 146)** | [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (lang) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product) | 🟡 in progress | gap-1 sound + gap-2 labels + wow-demo done; next = research pass, manifest format/emission, cross-module label export, Phase 146b |
| **Compiler / language correctness** | **this file** → [Compiler / language](#compiler--language) | 🟡 open items | Phase 101b (deferred) |
| **Standard library** | [`STDLIB.md`](./STDLIB.md) §"Remaining work" + §"Label refinement roadmap" | 🟡 modules done, extras open | `zip`/`unzip`, `Semigroup List`, JSON pretty/codecs, effect-label refinement |
| **CLI surface (Phase 82)** | **this file** → [CLI surface](#cli-surface-phase-82-continued) | 🟡 gaps | `medaka build` ✅ MVP (empty-prelude; cache deferred), `doc` multi-module, `--json` multi-file |

---

## North star — self-hosting, then LLVM

The long-term goal that orders everything below: **rewrite the Medaka compiler
in Medaka, then compile it to native code via LLVM.** Chosen path: **bootstrap on
the existing tree-walking interpreter first** — get a self-hosted compiler running
(slowly but correctly) on the interpreter, *then* build the LLVM backend so that
compiler emits native code.

Three stages, each a gate on the next.

> **Why native matters — the wedge.** Self-hosting + LLVM aren't the end goal;
> they're what *enables* it. The candidate "killer feature" is **capability-safe
> effects** (Phase 146 / [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md)): a
> function's type becomes a compiler-verified manifest of what it can do, aimed at
> **WebAssembly edge / plugin / sandboxed compute** for untrusted, increasingly
> AI-generated modules. The native (WasmGC) backend is the delivery vehicle for
> that wedge; the wedge is the reason the backend is worth building.

### Stages 0–2 — ✅ COMPLETE (self-host + native backend)

Stages 0 (prerequisites), 1 (self-host on the interpreter), and 2 (LLVM backend)
are done — Medaka self-hosts and the native backend compiles it to a reproducing
fixpoint (see [Current status](#current-status-2026-06-09)). Full per-stage detail
archived in [`PLAN-ARCHIVE.md` → Archived north star stages 0 to 2](./PLAN-ARCHIVE.md#archived-north-star-stages-0-to-2);
owning docs: `selfhost/README.md` (Stage 1), `selfhost/STAGE2-DESIGN.md` +
`selfhost/BOOTSTRAP.md` (Stage 2). Forward work is
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml).

### Stage 3 — Make the LLVM backend canonical, retire OCaml

Stages 1–2 are done: Medaka self-hosts and the native LLVM backend compiles the
compiler to a self-reproducing fixpoint. **Stage 3 makes the native backend the
CANONICAL compiler** — the one users invoke and the one that builds the compiler.

**Retirement ≠ removal (user, 2026-06-10 — see memory `retirement-is-not-removal`):**
- **RETIREMENT (the milestone):** native is canonical; the OCaml reference (`lib/`+`bin/`) is
  DEMOTED from "the reference" but **kept in-tree, frozen, as a soak-period oracle.** Reached
  when the bar below is met.
- **REMOVAL (separate, later, confidence-gated):** delete `lib/`+`bin/` ONLY after **a few days
  of clean native-only development with no need to consult OCaml** AND **the tools suite exercised
  end-to-end** (real use, beyond the per-slice differential gates). The frozen OCaml = the
  soak-period safety net (maps to the frozen-third-oracle bar item). Do NOT `rm lib/` at the
  retirement milestone.

**The "native is canonical" bar (gates `lib/` retirement) — status as of 2026-06-10:**
1. 🟢 **~95%.** `medaka build` compiles + runs arbitrary USER programs natively. Gap G / Cause A /
   GAP 1 (nested dicts) / GAP 2 (max/min) / C5 standalone-vs-method / tuple-as-receiver all ✅.
   **Stdlib-emittability sweep DONE** (2026-06-10): 8/12 modules build CLEAN; **clause-label SSA
   collision** (#53, gated the Phase-C capstone — every multi-module build) ✅ CLOSED (`da3958f`);
   **hashing needs NO language decision** (works via C externs). Remaining (all tracked; full
   repro-verified scope in [`selfhost/DISPATCH-GAPS-SCOPE.md`](./selfhost/DISPATCH-GAPS-SCOPE.md)):
   **#54 Map `toList` bare-name** (H-b1 — module-local standalone shadows the Foldable method);
   **#55 sum/product two-constraint dicts** (#21 Cause-B residual); **#50 parametric-Ord `< > <= >=`**;
   **#21 2-level multi-module route flattening**. (tuple work also fixed `==` crashing on ANY parametric
   `Eq` impl.) **⚠️ #54 is COUPLED to #21 (found 2026-06-10):** the scope doc's "surgical one-node
   `buildKeyTable` fix" hypothesis was WRONG. The `prePassModulePairArgShadow` panic-fix removes the
   `no impl of 'toList' for 'Map'` panic, but then `debug (toList m)` emits garbage
   (`["\0\0\0", …]`) because the element-dict route comes out `RKey "String"` instead of
   `RKey "__tuple2__" [Int, String]` — i.e. the **#21 nested-element-dict route-flattening bug**.
   So #54-correct-output needs #21 first; an attempt STOPPED clean (no merge, no commit) rather than
   ship panic-gone-but-output-wrong. These two should be fixed together, Opus + oversight (route-fragile).
   **Block-let completeness gap CLOSED (2026-06-11):** `emitBlock` now handles `CSLet _ pat` for an
   arbitrary irrefutable pattern (`PCon`/`PCons`/`PList`/`PAs`/nested) — mid-block + last-position —
   via the existing `bindPattern` destructure (was `PVar`/`PWild`/`PTuple` only → `gapE`). Unblocked
   Phase-C Slice 3 `test` (pulls `prop_runner`'s constructor block-let into the native graph). See
   `selfhost/EMITTER-GAPS.md`.
2. ✅ **Effectively done.** Behavior suites ported to `medaka test` (`test_run`/`test_eval`/`test_loader`);
   the rest is internal OCaml API, intrinsically non-portable.
3. ✅ **Done.** Differential fuzzer (MVP + native Tier-C, 1080 native programs clean, found+fixed
   named-field deriving).
4. ✅ **DONE 2026-06-11 (`selfhost/PERF-RESULTS.md`, 18 fixpoint-gated wins).** Performance —
   emitter self-compile **12.04 s → 2.12 s (5.68×); ~59× faster than the OCaml interpreter**
   (125 s), peak RSS 770 → 200 MB. `-O2` flipped in both build drivers (the predicted `mem2reg`
   alloca win → 4.7× RSS drop); Boehm `GC_set_free_space_divisor(1)` (−36% alone); then a sweep of
   O(N²)→O(N·log N) / constant-table-index fixes across DCE, the typechecker (dep-graph membership,
   clause grouping, SCC clause lookup, dedupS/groupNames, member-sig presence — all via the in-tree
   `SMap`), and the emitter (lifted-define buffer, distinctTypeNames memo, isKnownFn/ctor/global-sig
   `EMap` indexes), plus core_ir_lower group-by and private-name collision merge-sort. `-O2` confirmed
   fixpoint-safe + GC-safe (no `-fno-omit-frame-pointer` needed). Reproducible via `test/bench.sh`.
   **Remaining levers are supervised-only** (mapped in PERF-RESULTS.md): the dict-passing
   constraint-promotion membership (~25 %, route-fragile dispatch) and the threaded-sig lookup cluster
   (~12 %, Float-two-pass-sensitive); TRMC (#56) is deferred (stack-scalability, not a measured
   wall-clock win). Documented dead-ends: LTO, GC_MARKERS, hash_map-in-emitter (breaks fixpoint),
   interior-pointers-off (unverifiable corruption risk).

5. ✅ **DONE 2026-06-10 (`44f5433`).** OCaml-free seed bootstrap. The strict `medaka build` driver
   (`llvm_emit_modules_main.mdk`) **fixpoints** (C3a/C3b YES — the one real gap, now verified via
   `test/selfcompile_build_fixpoint.sh`). Committed seed `selfhost/seed/emitter.ll` (~9.6 MB text IR,
   deterministic); `test/bootstrap_from_seed.sh` = `clang(seed)→seed_emitter→re-emit→cmp→clang→medaka_emitter`,
   **no `medaka run` anywhere** (opt-in gate). `build_cmd.mdk` reads `MEDAKA_EMITTER` env (native emitter
   binary) with the `medaka run` fallback. Self-refresh confirmed (native emitter reproduces the seed = C3b);
   `test/refresh_seed.sh` is the only OCaml-using script, run on demand. Decisions honored (text IR, arm64,
   opt-in gating). Doc: `BOOTSTRAP.md` §"C4 — OCaml-free seed bootstrap". **⚠️ SEED-REFRESH POLICY
   (user, 2026-06-10):** any emitter-IR change makes the committed seed stale. Emitter-changing agents
   **LEAVE the seed STALE** (confirm `selfcompile_fixpoint` C3a/C3b, SKIP `bootstrap_from_seed`, do NOT
   commit a re-mint) — to avoid per-agent 10 MB churn. The **orchestrator re-mints once at release
   checkpoints** via `test/refresh_seed.sh` + verifies `bootstrap_from_seed.sh`. (Last re-mint:
   the **2026-06-11 perf checkpoint** — the ~18 emitter/typecheck perf wins (PERF-RESULTS.md) rewrote
   the emitter graph; re-minted via `test/refresh_seed.sh` and verified `bootstrap_from_seed.sh` C3a/C3b
   byte-identical.)
6. 🟢 **Soundness + correctness CLOSED.** TYPECHECK-AUDIT: all confirmed soundness/correctness/
   diagnostic findings closed (S1-S3, T1/T1b/T2, C1-C9, D1/D2, OBS3/OBS4); **C4 resolved by decision**
   (lazy nullary canonical); **C5 ✅ CLOSED** (`5db8a83`, RLocal end-to-end, fixpoint byte-identical);
   **C8b ✅ CLOSED**; **OBS1 ✅ CLOSED** (`do { let mut }` rejected pre-desugar). Tail remaining:
   **C7-native**, **L1** (latent, fires at E4); **D3** =
   scope cut shared with the oracle. The "de-risk identity-keying fragilities" condition is now down to
   **L1** (C5's bare-name/install-order side closed).

**Also gating retirement, beyond the 6-item bar:** the **Stage-4 tooling port** (lib/+bin/ host the
tooling) — fmt/test/new/REPL/build/**LSP** ✅ (all 6 tools ported + differential-tested), and the
**Phase-C CLI capstone IN PROGRESS** (Slices 0–2 ✅: native `medaka` does check/fmt/new/build/run
OCaml-free in a 1.59 MB binary; Slices 3 `test` + 4 `repl`/`lsp` remain — see Phase C #12 below).
**Deferred (user, not near/mid-term):** GC, cross-platform (arm64-first accepted).

**🔝 TOP PRIORITY (set 2026-06-09): close the TYPECHECK-AUDIT findings.** The
2026-06-09 audit ([`selfhost/TYPECHECK-AUDIT.md`](./selfhost/TYPECHECK-AUDIT.md)) —
4 confirmed divergences (2 soundness-class), no coherence checking, 2 latent
Phase-134-class hazards, plus C/D correctness + diagnostic gaps — is the owning doc
and the front of the queue, ahead of the construct-sweep / test-port / fuzzer below
(those remain). These gate `lib/` retirement (bar item 6): the native `unreachable`
arms + first-match dispatch + arg-tag chains are sound only under guarantees the
*OCaml* typechecker currently enforces. **Fix order (the audit's own):**
`S1 → S2 → T1 → T2 → S3 → L1+L2 (before E4) → C-series → D-series`, each with a
repro + oracle-reference + fix location in the doc. Most are "port the oracle
behavior into `selfhost/{typecheck,eval,marker}.mdk`" — re-validate each with the
stage's `diff_selfhost_*` / `bootstrap_*` harness. Confirmed soundness items first:
- **S1** — ✅ **CLOSED (`69b3400`).** `EMethodAt` applied dicts without the
  awaits-args gate → valid programs panicked. Ported the gate into `eval.mdk`
  (758-771, reuses `awaitsArgs`); repro yields `[]` == oracle; all gates green.
- **S2** — method-level dict params dropped from explicit impl clauses (k-offset;
  `typecheck.mdk:2595-2614`; mirror `dict_pass.ml:103`). CONFIRMED; subsumes D6.
- **S2** — ✅ **CLOSED (`945053c`).** Method-level dict params dropped from explicit
  impl clauses → dict mis-bound to first value param. Ported `dictPats n k` prepend +
  slot offset into `implDictPassMethods`/`registerReqSlots` (mirror `dict_pass.ml:118`);
  repro prints `6` == oracle. **Subsumes D6** for the method-level case (2-method
  variant → `22`). *Surfaced a new oracle-side gap (OH1, below).*
- **T1** — value restriction entirely missing → polymorphic mutable refs typecheck
  (5 generalize sites; port `is_nonexpansive`/`gen_restricted`/`lower_to_current`).
  CONFIRMED. *Note:* mirroring the oracle reproduces an adjacent oracle `mut`-gen
  hole — the audit says fix BOTH sides (a design point to settle when we reach T1).
- **T1** — ✅ **CLOSED (`1c027d8`).** Value restriction was entirely missing →
  polymorphic mutable refs typechecked. Ported `isNonexpansive`/`genRestricted`/
  `lowerToCurrent` + the Phase 89 point-free relaxation into all generalize sites
  (inferLet/blockLet/generalizeGroup/sccSchemes); `Ref []` now rejects == oracle.
  Mirrors the oracle exactly (incl. its `mut` hole — see T1b). All gates green; no
  dispatch/route-keying perturbation.
- **T1b** — ✅ **CLOSED (both sides, 2026-06-09).** The `mut`-gen hole the oracle
  ALSO had: `lib/typecheck.ml:1968` keyed `gen_restricted` on `is_nonexpansive`
  only (ignored `mut`), so `let mut x = []` generalized and heterogeneous pushes
  checked clean + ran on BOTH sides. **Fixed via gen-restrict-on-mut alone** (no
  `DoAssign` change needed — once the binding is monomorphic the per-assignment
  re-instantiation can't widen it; confirmed empirically). Oracle: `is_value =
  (not mut) && is_nonexpansive e`. Selfhost: threaded the `mut` flag into
  `blockLet` (`typecheck.mdk:1436,1451`) → `(not isMut) && isNonexpansive e`. Now
  rejects `Type mismatch` identically; valid mut still typechecks. Fixture
  `test/typecheck_error_fixtures/mut_generalization.mdk`. All gates green. Audit §T1.
- **OBS1** (selfhost missing diagnostic, surfaced during T1) — selfhost does NOT
  enforce the oracle's `let mut not allowed inside a do block` prohibition; an
  invalid `do { let mut … }` is wrongly accepted by selfhost (oracle rejects).
  Separate from value restriction; a missing-diagnostic divergence. Low priority.
- **T2** — ✅ **CLOSED (`9dfb9e5`).** Inline `let … in` dropped `mut`/`is_fun` →
  recursive inline let panicked `unbound variable`. Split the `ELet` arm
  (`inferLet`): `is_fun`+`PVar` → `inferRecLet` (placeholder pre-bind + generalize
  via `genRestricted`); `mut` → `MutLetRequiresBlock` error. Repro accepts == oracle;
  inline `let mut … in` rejected == oracle; T1 generalize interaction clean.
- **OBS2** (selfhost parser gap, surfaced during T2) — selfhost can't parse a
  `let … in` as an indented clause body (oracle accepts). Moved to the canonical
  [Known parser gaps](#known-parser-gaps-selfhost-parsermdk) list; verified repro
  there.
- **OBS3** (selfhost typed-path gap, surfaced during C3) — ✅ **CLOSED 2026-06-10** (as a
  side-effect of the medaka-test GAP-C work). selfhost now has an `infer` arm for
  `EHeadAnnot` (head annotations like `Map`/`Set` literal head-pins via `fromEntries`):
  `infer env (EHeadAnnot e ty) = inferHeadAnnot env e ty` (`typecheck.mdk:1385`, helper
  `:2038`) — was `panic "unsupported expression (slice 1)"`. `check.mdk` on `map.mdk`/`set.mdk`
  now typechecks (schemes, no panic); their doctests are in the `diff_selfhost_test` gate.
- **OBS4** — ✅ **CLOSED (2026-06-10, during the medaka-test GAP-C work).** Record
  *construction* `MissingField` check: `checkMissingFields`/`missingFieldMsg`
  (`selfhost/typecheck.mdk:1981-1993`, called from `inferRecordCreateWith`) — message
  `"Missing field <f> in construction of record <r>"` byte-identical to oracle
  (`lib/typecheck.ml:718`). Fixture `test/typecheck_error_fixtures/missing_field.mdk`;
  `test_typecheck` 482/482, `diff_selfhost_check` 40/40, C3a/C3b fixpoint green.
- **C3** — ✅ **CLOSED (`d4f1469`).** Added `AnnotationTooGeneral` — after
  `inferAnnot`'s unify, requires the annotation's tyvars to stay distinct unbound
  (flags grounding + collapse via `sigTvarIds`/`hasDupI`); message byte-identical
  to oracle; `EHeadAnnot` exempt by construction. Fixture + all gates green.
- **C2** — ✅ **CLOSED (`d8d7ac6`).** Ported Phase 72 `field_owners` multimap +
  receiver-directed field resolution into `typecheck.mdk` (`fieldOwnerNames`/
  `resolveFieldRecord`): receiver head known → that owner; undetermined + multi-owner
  → `AmbiguousField`; unknown → clean type error (not panic). Messages byte-identical;
  fixtures + all gates green. (Unpinned sig-typed-param `getA a = a.x` still ambiguous
  until **C1**/Phase 73 lands — then receiver-directs for free.)
- **C8** — ✅ **CLOSED (`b3a6b2c`).** (a) `publicValNames` now exports `pub`
  interface method schemes (`ifaceMethodNames`, mirror `pub_iface_schemes`) →
  cross-module interface-method use resolves. (b) added `inferDefaultBodiesIfEnabled`
  to the module path (`checkModuleFullImpl`), gated identically → two-entry-point
  parity. Multi-module fixture + all gates green (also fixed a trailing-slash root
  bug in the modules harness). **Residual (C8b, follow-up):** default-body inference
  only covers *constraint-carrying* defaults on BOTH selfhost entry points, and is
  gated OFF on the plain-check path; the oracle type-checks ALL default bodies
  unconditionally. Full oracle-parity on *unconstrained* default-body diagnostics
  needs extending `inferDefaultBodies` to all defaults + ungating — out of C8 scope.
- **C6** — ✅ **CLOSED (`2926307`).** Memoised nullary return-position impl thunks
  (`implMethodValue` → `memoThunk`: a private `Ref (Option Value)` evaluated once,
  read back after) so a point-free impl body runs its effects once == oracle (was
  twice). Value-preserving; Phase-125 force *timing* untouched (that's C4). Fixture
  + all gates green incl. native fixpoint.
- **C9** — ✅ **CLOSED (`e31296f`).** Ported `inferIndex` normalize-and-branch
  (String→Char, Array/List→elem, **undetermined→Array** default) mirroring the
  oracle; `f xs = xs.[0]` now infers `Array a -> a` == oracle (was `List`). No
  golden shifts (corpus had none); fixture + gates green. (Annotated-param indexing
  `g : String -> Char; g s = s.[0]` still needs **C1**/Phase 73 — upstream.)
- **C1** — ✅ **CLOSED (`e671854`).** Ported Phase 73 bidirectional sig-driven
  param typing — `inferMembers`/`inferClauseEff` peel the signature's arrow domains
  onto clause param patterns (`peelArrows`/`zipUnify`) BEFORE body inference (mirror
  `typecheck.ml:2604-2644`). Contained checking-mode addition; SCC/generalization/
  mutual-rec untouched; **self-compile fixpoint holds**. **Unlocks the C2 + C9
  sig-typed-param residuals** (`getA a = a.x`, `g s = s.[0]` now resolve). Fixture +
  all gates green, no golden re-bless.
- **C7** — ✅ **CLOSED (`c93c7b9`, dict-eval path).** `RKey` now carries the
  canonical impl key (`iface|args|name`, mirror `impl_key`) and `hasTag` matches it,
  but ONLY upgraded at sites with a real head collision (≥2 impls share a head tycon)
  — non-colliding sites + the native backend stay byte-identical. Two non-overlapping
  same-head impls (`Pair Int Bool` / `Pair Bool Int`) now dispatch correctly ==
  oracle; fixpoint holds. **Residual (C7-native, follow-up):** the native Core-IR/LLVM
  backend is still head-tag-keyed (`CImplTagged`/`implFnName`), so a same-head
  collision resolves on the interpreter but hard-errors natively (no silent
  mis-dispatch). Closing it touches the emitter tag scheme broadly — out of C7 scope;
  relevant to native-canonical completeness.
- **C5** — ⏸️ **DEFERRED for oversight (not design-blocked; risk/scope).** Phase-112
  standalone-vs-method (no `lookup_method`, no `RLocal` route, install-order
  shadowing). The fix needs a **route-taxonomy addition** (`RLocal`) + `lookup_method`
  (walk past non-method shadows) + merging standalone+impl candidate sets — a larger
  feature-port with **UNCERTAIN blast radius** (audit), and the repro needs an
  imported-standalone / prelude-redefinition shape that's hard to verify unattended.
  Not merged autonomously — recommend human oversight (it's a route-taxonomy change,
  the flagged-fragile area). Audit §C5.
- **C4** — ⏭️ **SKIPPED (design-blocked, not a pure gap).** Selfhost makes top-level
  nullary bindings lazy `VThunk`s — the *deliberate* Phase-125 design — so an
  unreferenced `sideEffect = println …` doesn't run; the oracle forces all nullary
  thunks in source order. The audit itself offers "fix OR document the divergence,"
  i.e. forcing-to-match-oracle would partly revert Phase 125 = a **language-design
  decision** (eager vs lazy top-level nullary effects). Deferred for user input; NOT
  closed autonomously.
- **S3** — ✅ **CLOSED (`6140e0a`).** Ported `check_coherence` (Phase 68) into
  selfhost as `checkCoherence` — overlap rule mirrors `impls_overlap` byte-for-byte
  (wildcard unify with resolve-before-bind; `default` dup → `Multiple default impls`,
  anonymous non-default non-specialization overlap → `Overlapping impls`; named /
  strict-specialization accepted). Runs over USER decls only (prelude excluded → no
  over-rejection). 3 fixtures; all gates green incl. native fixpoint. **Deferred:**
  most-specific-wins dispatch (no corpus needs it) + orphan rejection (separate
  multi-module `check_orphans`, unrelated to first-impl-wins soundness).
- **OH1** (oracle-side, surfaced during S2) — combined method-level constraint +
  impl-`requires` + terminal body panics on the **OCaml oracle itself**
  (`unbound identifier: $dict_base_0`). A `lib/` dict-passing hole, no correct
  reference to mirror. Low priority (niche), but the hybrid oracle must not enshrine
  it before retirement. See TYPECHECK-AUDIT §OH1.

**Oracle (hybrid).** As OCaml recedes, ground truth = the Medaka tree-walker
(`eval.mdk`) for runtime BEHAVIOR (native diffed vs interpreted-selfhost — the
bootstrap pattern) **+** frozen GOLDEN snapshots for structural dumps
(tokens/AST/Core-IR/types). Belt-and-suspenders; neither depends on `lib/`.

**Near-term sequence (front-loaded order, decided 2026-06-09):**

> ### Overnight autonomous run — 2026-06-09 22:00 → 07:00 PDT (progress log)
>
> **TYPECHECK-AUDIT — autonomous phase COMPLETE, 16 findings closed** (all verified
> on main, all gates incl. native self-compile fixpoint green): S1 S2 T1 **T1b**
> T2 S3 · C1 C2 C3 C6 C7 C8 C9 · D1 D2 · OBS4. Detail in `selfhost/TYPECHECK-AUDIT.md`.
> - **Deferred (need oversight / gated):** C4 (design — Phase-125 lazy nullary),
>   C5 (route-taxonomy `RLocal` + uncertain blast radius), L1/L2 (E4-gated /
>   route-fragile), D3 (scope-cut) D4 (route) D7 (dispatch-latent) D8 (annotate
>   dormant) D9 (port-or-reject, borderline design) D10 (README-blocked) D11 (E4).
> - **Residuals tracked:** C8b (unconstrained default-body diagnostics), C7-native
>   (native same-head dispatch), OBS1 (let-mut-in-do diag), OBS2 (parser: let..in
>   indented clause body). [OBS3 EHeadAnnot typed-path — ✅ CLOSED 2026-06-10.]
>
> **Construct-coverage sweep (Stage 3 #2b)** — `selfhost/CONSTRUCT-COVERAGE.md` +
> gate `test/build_construct_coverage.sh`. Started 114 PASS / 15 GAP; **closed
> F1·H-a·D1·D2·B1·B2 + the OBS5 DCE-`collectVars` soundness audit → 123 PASS**,
> fixpoint intact throughout.
> - **Deferred construct gaps:** C (primitive arg-tag dispatch — known D3b), E (Float
>   corruption/SIGSEGV — too subtle for unattended), I (effect rows), most of A
>   (parser grammar), H-b (map/set emitter dispatch), F1-Layer2 (dict-pass SIGSEGV
>   for unannotated polymorphic constrained fn), D3/D4, let-else-refutable-nonctor.
>   - **✅ Gap G — CLOSED (Phase 151, A2 type-directed rewrite): comparison/equality
>   OPERATORS now dispatch to user/derived `Eq`/`Ord` impls.** `==`/`!=`/`<`/`>`/`<=`/`>=`
>   carry a dispatch ref on `EBinOp` (`lib/ast.ml` + `selfhost/ast.mdk`); typecheck
>   stamps it (RKey) ONLY when the operand grounds to a **non-primitive** with an
>   Eq/Ord impl (`lib/typecheck.ml` `check_binop_usages`; `selfhost/typecheck.mdk`
>   `resolveBinopSites`), and the dict-pass rewrites the stamped node into the method
>   application (`<`→`lt`, `==`→`eq`, `!=`→`not (eq …)`, …) — `lib/dict_pass.ml`
>   `rewrite_binops` (wired into `Dict_pass.run` + `Eval.eval_modules`) and
>   `selfhost/typecheck.mdk` `dictPass` (`rewriteBinopExpr`). Interpreter + selfhost
>   eval + native `==` on a user ADT all dispatch to the impl; selfhost == OCaml oracle
>   on user-written impls. Primitive operands stay the structural builtin EBinOp (zero
>   churn — primitive-only IR byte-identical; no recursion). **✅ Native `<`/`lt`/`>`/`<=`/`>=`
>   on a user/derived `Ord` ADT — CLOSED 2026-06-10 (slice-7, `13af6ab`).** Emitter-only
>   9-line fix: derived `Ord` emits only `compare`; the operators are interface DEFAULTS
>   over `compare`, so the rewritten `lt` method-app reached `emitDefaultRKey` but
>   `restampIface` (`llvm_emit.mdk:~2545`) had only a `CVar` arm — method-marking had
>   turned the inner `compare` into a `CMethod _ RNone`, which fell through unrewritten →
>   arg-tag dispatch → primitive `Ord Int` group (no cell tag) → `emitTagMatch` panic.
>   Added a `CMethod _ RNone` arm re-stamping same-interface to `RKey tag`. All four ops
>   native == oracle; fixpoint held byte-identical (no re-baseline). `max`/`min` over
>   generic `Ord a` NOT closed (separate — pure default methods, no concrete tag; needs
>   RDict→default-body synthesis; scoped 2026-06-10). Fixtures
>   `test/llvm_fixtures_typed/disp_ord_default_{lt,gt,lte,gte}.mdk`. (A pre-existing, independent selfhost-vs-oracle
>   divergence on *derived* `Ord` `compare`/`lt` — present on `main`, untouched by this
>   change — was **CLOSED 2026-06-10**: `selfhost/desugar.mdk` `deriveForData` was missing
>   the `"Ord"` arm, so derived `Ord` on `data`/record types was silently dropped → inverted
>   ctor-tag fallback. Added the one arm mirroring `lib/desugar.ml:574`
>   (`deriveOrdData` generator already existed, wired only into newtype); `compare Red Blue` =
>   `Lt` and `Red < Blue` = `True` selfhost == oracle, nullary + payload. Fixpoint untouched.
>   Fixtures `test/{diff_fixtures,eval_dict_fixtures}/adt_deriving_ord.{mdk,golden}`. **Follow-up
>   CLOSED 2026-06-10:** `deriveForRecord` was a full stub — records derived NO interfaces.
>   Added `Eq`/`Ord`/`Debug`/`Display`/`Generic` arms (dedicated field-access generators
>   mirroring `lib/desugar.ml`'s `derive_*_record` family — records read fields by name via
>   `EFieldAccess`, not positional ctor patterns, so they do NOT reuse the data derivers).
>   `Point { x:Int, y:Int } deriving (Eq, Ord, Debug)`: `==`/`compare`/`debug` selfhost == oracle,
>   byte-identical desugar dump. Fixtures `test/diff_fixtures/record_deriving.{mdk,golden}` +
>   `test/eval_dict_fixtures/record_deriving_ord.mdk` (typed-path `<` dispatch). Fixpoint
>   untouched — no `selfhost/*.mdk` record derives.)
>
> **Bar-item-2 (port tests to `medaka test`) — STARTED:** `test/ported/test_run_ported.mdk`
> = 40/46 `test_run.ml` cases → 96 assertions, all green + deterministic, no source
> changed. Skipped: 5 runtime-error cases (need `runExpectation` **exported** in
> `stdlib/test.mdk` — a 1-word stdlib edit, RECOMMENDED but not done per the
> stdlib-is-hand-written policy) + 2 IO-env cases. `test/ported/README.md` maps
> ported-vs-skipped. **test_eval also ported: 240 assertions green** (~120 cases; total
> bar-item-2 = 336 assertions). Recurring unblock: `runExpectation` unexported blocks
> 13 runtime-error cases — RECOMMEND `export` it (1-word stdlib edit, not done per policy).
> Portable = program→value cases; internal-API cases (AST/scheme
> inspection) are not expressible as `medaka test` and stay in the OCaml suites.
>
> **Method note:** every fix in its own worktree agent → verified on main → docs
> updated. L1/L2 deferred for the run (latent + route-fragile; near E4). Skipped
> only genuine language-design items. Heartbeat cron `d6dca841` armed until 7am.

> ### 2026-06-10 session (orchestrated, user-supervised) — progress log
>
> Native-canonicalization push. All landed + verified on local main; self-compile
> fixpoint (C3a/C3b) held byte-identical across every merge.
> - **✅ Cause A — `elaborateModules` promotion+arity layer (`729879f`).** The native
>   build path lacked the dict-promotion + `implTable` machinery the single-file typed
>   path has, so an unannotated constrained fn (`f s = println s`) was never promoted →
>   `RNone` → silent no-output. Ported the eligibility seed + `discoverPromoted` fixpoint
>   + per-module importer-scoped arity (mirror `lib/eval.ml:2104-2164`). Closes Cause A +
>   Gap C C2/C3-unannotated. (Trap: subtract the seed from the promoted set + `resetState`
>   after discovery, else prelude listItems arities get re-captured → SIGSEGV.)
> - **✅ Gap G native ordering operators (`13af6ab`)** — see the Phase-151 entry above
>   (now updated). Gap G fully closed across interp / selfhost / native for `==` and
>   `< > <= >=` on user/derived `Ord`.
> - **✅ Differential fuzzer (MVP + native Tier-C)** — see near-term #4 (updated). 1080
>   native programs byte-identical; found + fixed the named-field-data deriving divergence.
> - **✅ Named-field-data deriving (`e695539`)** — `data Box = Box { v : Int } deriving (Debug)`
>   panicked in the selfhost tree-walker. NOT a desugar bug (oracle also builds positional
>   `PCon` for ConNamed): the fix is value-representation in `selfhost/eval.mdk` —
>   `evalProgram` never populated `ctorFieldOrdersRef` + `ERecordCreate` always built
>   `VRecord`; now mirrors `lib/eval.ml` (registered named-field ctor → positional `VCon`).
>   All 5 deriver kinds fixed. (Recurring "looks like desugar, is the eval driver" trap.)
> - **✅ Error-path BLOCKERs** — see the Error-path bullet under Supporting work (updated):
>   audit found 6, closed 5 (B1-B4, B6), B5+R2 in flight.
> - **Native dispatch holes (scoped 2026-06-10):**
>   - **✅ GAP 1 — two-level nested dicts (silent SIGSEGV) — CLOSED 2026-06-10 (`5913297`).**
>     Boxed dict-witness rep (Option A): every dict witness is now a pointer to a heap cell
>     `[head_tag | reqdict_0 | …]` via `@mdk_alloc` (was a flat i64 `hashName(tag)` dropping
>     nested `reqs`). `emitDispatchChain` loads nested dicts from the cell and prepends to
>     `argOps` (order = `dict_pass` `methRoutes++implRoutes`). `eq [[1,2]] [[1,2]]` → `True`;
>     depth-agnostic (`[[[1,2]]]` works). Emitter-only; fixpoint re-stabilized automatically
>     C3a/C3b. **Residual (separate gap, task #21):** `Box (List (List Int))` still SIGSEGVs —
>     NOT the rep, but multi-module route flattening (`elaborateModules`/`elabModuleStamp`
>     stamps the element-dict FLAT as `RKey "List" []`; single-module path resolves it nested).
>     Phase-134-class; tracked in `EMITTER-GAPS.md`.
>   - **GAP 2 — `max`/`min` over generic `Ord a`** (clean panic; pure default methods need
>     RDict→default-body synthesis reusing E19 `emitDefaultDefine`/`restampIface`). NOT built;
>     emitter-only, no design decision; doesn't block fixpoint (DCE prunes). `emitDispatchChain` seam.
>   - **tuple-as-receiver** (Gap C C1/C5b — `headTyconMono (TTuple _)` → `$tuple` head) — the
>     empirically-top native construct gap from the fuzzer Tier-C. Touches `typecheck.mdk`+emitter.
>   Details in memory `project_native_dispatch_gaps`.


1. ✅ **`medaka build` CLI — DONE (MVP, 2026-06-09, `39f3318`).** `medaka build
   foo.mdk [-o out]` emits IR via the self-hosted emitter → `clang` → native
   binary, for arbitrary user programs. `lib/build_cmd.ml` + `bin/main.ml`
   dispatch + `test/build_cmd.sh` (build+run+diff, 6 programs). Shell-out MVP
   (subprocess `run`s `selfhost/llvm_emit_modules_main.mdk`, captures stdout —
   clean Ref-state isolation); repo-relative asset resolution; no artifact cache;
   gap policy = hard error (default non-gap-tolerant path). **Key boundary
   finding:** the build passes an **EMPTY prelude** — the full `stdlib/core.mdk`
   is **not yet emittable** (emitter has no DCE, and `core.mdk`'s
   `maximum`/`minimum` trip the open `max`/`min` arg-tag dispatch gap, aborting
   even a trivial program). So the emittable surface today = runtime externs +
   primitive arithmetic/comparison + ADTs/`match` + recursion + closures +
   tuples/records/arrays + cross-module data; **`println` and all `core.mdk`
   typeclass machinery are out of scope until the prelude is emittable** (clean
   `unbound variable` hard-error at that boundary). This makes #2 the gating
   unblocker, not just a completeness chore. Deferred: Core-IR artifact cache
   (cache-key + on-disk layout), install-prefix asset packaging.
2. **Prelude-emittability + completeness — DCE ✅ + unit-head ✅ + flip ✅ → emitter-gap sweep.**
   *Sharpened by the #1 finding:* this is the **unblocker that makes `medaka build`
   useful for real programs** (anything using `println`/typeclasses), not tail-end
   polish. Sub-goal **(a) make the real `stdlib/core.mdk` prelude emittable — DONE
   (2026-06-09):**
   - ✅ **DCE (`08be86a`).** `selfhost/dce.mdk` (`dceFilter`) filters `allDecls` in
     `llvm_emit_modules_main.mdk`'s `runEmit` before lowering: drops plain
     (`DFunDef`) bindings unreachable from `main` + emitting-decl roots; **retains
     ALL impls/interfaces whole** (sound — impls are dynamic-dispatch targets, off
     the static call graph). Order-preserving → IR byte-stable (C3 fixpoint intact).
     Cleared the `max`/`min`-in-`maximum`/`minimum` + `arbitraryString` blockers.
     (Consequence: `max`/`min` over primitive `Ord` is no longer a *build* blocker —
     DCE drops the dead default methods; it's a latent emitter gap only if a user
     program actually *calls* `max`/`min`. The 2 residual census events in
     `EMITTER-GAPS.md` are that latent case.)
   - ✅ **Unit-head emitter gap (E20, `42487b3`).** `emitSwitch` now treats
     `CTBranch HUnit` as an irrefutable no-test head (emit the branch, no
     discriminant) — emit-only, `canonPat`/Core-IR untouched. Closes the last
     census-A gap; `Arbitrary` impls (`arbitrary () = …`) emit. Fixture
     `test/llvm_fixtures/unit_head.mdk`; 170/170 `diff_selfhost_llvm` byte-identical.
   - ✅ **Prelude flip (`1bde51a`).** `lib/build_cmd.ml` now passes the real
     `stdlib/core.mdk`. Verified native==interpreter for `debug`/`Debug`, `==`/`Eq`,
     `compare`/`Ord`, `map`/`Foldable`, `data … deriving (Eq, Debug)`. `test/build_cmd.sh`
     11/11 green. **(Build main's `_build` after a `.mdk`-touching merge before running
     this gate — a stale embed shows spurious `unbound variable: debug`.)**
   - ✅ **`Unit`-return auto-print FIXED (Stage 3 2b, `35ff12a`).** Was: a
     `main : <IO> Unit` program appended a spurious `0` (native `println "hello"` →
     `hello\n0\n` vs interpreter `hello\n`). Root: `callRetTy` (in the emitter's
     pure inference pass, `selfhost/llvm_emit.mdk` ~line 4040) defaulted unknown
     callees to `LTInt`, and IO output externs (`putStr`/`putStrLn`/`ePutStr`/
     `ePutStrLn`) weren't in the sig table → `println` (`= putStrLn (display x)`)
     inferred `LTInt`, propagating to `main`'s result → auto-print routed through
     `mdk_print_int(0)`. Fix: `callRetTy` resolves IO output externs to `LTUnit`
     up front (mirrors the real emit path's `emitIoExtern`). Tight blast radius
     (only the 4 genuinely-Unit externs); emit-only. Now native `hello\n()\n` ==
     interpreter+harness convention; `println` un-SKIPped in `test/build_cmd.sh`
     (13/13); all byte-IR / fixpoint / bootstrap gates green.

   Sub-goal **(b)** AUDIT `emitTree`/`emitExpr`/`emitApp` for every reachable
   `gapU`/`gapE`, and build a **language-construct coverage matrix** (start with the
   Unit-return fix above): the bootstrap only exercised what the compiler's own
   source uses — user programs use more (list comprehensions, all operator sections,
   inclusive ranges, string interpolation, every `do`/guard form, record/variant
   update, etc.). One native==interpreter fixture per construct in `SYNTAX.md`.

   *Construct note (verified 2026-06-09):* multi-statement imperative IO uses a
   **bare indented block** (SYNTAX.md §"do notation") — `main` is a statement
   block; Medaka IO is deliberately **NOT** a monad. `medaka build` compiles it
   correctly: a two-`println` bare-block `main` is native==interpreter
   (`one\ntwo\n()`). `do` is monadic sugar (Option/Result/custom, lowers to
   `andThen`/`pure`) — intentionally not an IO sequencer; reaching for `do` to
   sequence IO is a usage error, not a backend gap.
3. **Port OCaml test suites to native Medaka.** Re-express `test/*.ml` (the
   alcotest suites — parser/typecheck/eval/resolve/exhaust/…) as Medaka tests
   (`medaka test`) so the suite stops depending on `lib/`. This is the bulk of
   bar-item 2.
4. ✅ **Differential fuzzer — BUILT (MVP + native tier, 2026-06-10).** Type-directed
   OCaml generator (`dev/fuzz_gen.ml`, reuses `lib/ast.ml`+`lib/printer.ml`) producing
   well-typed-by-construction programs (Tiers 0–2: scalars/arithmetic → ADTs/records/
   match/tuples → `deriving (Eq,Ord,Debug)` + comparison/equality operators), 0% oracle
   rejection. Driver `test/fuzz_diff.sh`: **Tier-A** oracle + oracle-independent invariants
   (Eq/Ord laws, operator↔method, arithmetic identities); **Tier-B** oracle vs selfhost
   tree-walker (`eval_dict_main`, batched ~12 blocks/program); **Tier-C** oracle vs
   `medaka build` native (`948329b`). Deterministic `--seed`, known-gap allowlist,
   self-tested. **Results:** 680 programs clean Tier-A/B; **1080 native programs
   byte-identical** Tier-C; found 1 divergence (named-field-data deriving, fixed
   `e695539`). The native tier mechanically confirms Gap G / Cause A / Gap E / named-field
   all pass native. Deferred: shrinker, corpus, multi-module, Tier-C tuple coverage
   (suppressed via `--no-tuple` — open Gap C1/C5 tuple-as-receiver floods otherwise).

**Supporting / parallel work:**

- **Stack scalability** — the `-Wl,-stack_size` band-aid is **maxed at 512 MB on
  arm64** (the linker rejects larger). (a) **Worker-thread big-stack** in
  `medaka_rt.c` (emit the entry as a named fn; C `main` spawns a large-stack
  `pthread`) — general, covers deep STRUCTURAL recursion (typecheck/eval on big
  inputs); do first. (b) **TRMC** (tail-recursion-modulo-cons / destination-passing)
  in the emitter for `x :: recurse` list-builders → O(1) stack — the principled
  fix for the streaming loops (OCaml `[@tail_mod_cons]` is the blueprint); the
  cons-loop optimization on top of (a). Not yet forced (512 MB sufficed through C3).
- **Error-path / diagnostics parity — AUDITED 2026-06-10 + BLOCKERs closing.** Full
  read-only sweep (lex/parse/resolve/typecheck/eval) found **6 BLOCKERs** (selfhost
  false-accepts an invalid program or crashes uninformatively) + 7 MAJORs + 3 MINORs;
  all 51 pre-existing error fixtures pass. **5 of 6 BLOCKERs CLOSED:** B1/B2/B3 lexer
  false-accepts (unterminated string/comment, bad escape — `selfhost/lexer.mdk` now
  raises like `lexer.mll`, `9867626`); B4 missing-impl never rejected (ported
  `NoImplFound` from `lib/typecheck.ml`, `5d78c61` — no over-rejection, self-compile
  held); B6 `eval_run_main` silent no-main (now errors like oracle). **In flight:** B5
  (type-aware non-exhaustive match warning dropped by `check.mdk`'s
  `checkToLinesWithRuntime` — reads `typeErrors` only, not `matchWarnings`) + R2 (loader
  cycle-chain truncated to root). **Remaining MAJORs (lower priority / architectural):**
  R3 (bad import → unbound-var not unknown-module), E10/C4 (eval_run suppresses top-level
  side-effect thunks — the Phase-125 lazy-nullary design point), E8/TC5/E9 (typecheck-error
  → runtime-panic degradation, intrinsic to the untyped `eval_main` driver). Full inventory
  + repros in the 2026-06-10 progress log below + memory `project_selfhost_error_path_gap`.
- **Performance** — ✅ **DONE 2026-06-11 (bar-item 4, `selfhost/PERF-RESULTS.md`).** `-O2` on,
  Boehm GC tuned, ~18 emitter/typecheck O(N²) hot paths fixed: self-compile **12.04 s → 2.12 s
  (5.68×); ~59× faster than the OCaml interpreter**. Remaining levers (dict-passing membership,
  threaded-sig tree, TRMC #56) are supervised-only / stack-scalability, mapped in PERF-RESULTS.md.
- **Self-bootstrapping build** (bar-item 5) — remove the OCaml-interpreter
  dependency from producing the *first* native compiler: a checked-in/reproducible
  seed binary that compiles the `.mdk` sources, or a documented multi-stage
  bootstrap from a minimal seed. (C3 proves the native compiler reproduces itself;
  this makes the *build* not need `medaka run`.)
- **Cross-platform** — ⏸️ **DEFERRED (user, 2026-06-10) — not a near/mid-term priority.**
  Currently arm64 macOS only. Linux/x86-64 (runtime, the stack-flag specifics, clang target
  triple) before the backend is broadly canonical — but canonicalizing arm64-first is an
  accepted scope decision; do the platform port later.
- **GC** — ⏸️ **DEFERRED (user, 2026-06-10) — revisit only if GC perf proves truly awful.**
  Boehm conservative GC today. Precise GC + the WasmGC path (the wedge target needs WasmGC, a
  sibling backend off the Core IR seam — §2.4b) are eventual, not roadmap-blocking.
- **Housekeeping refactor of the compiler** — now that it works + self-compiles,
  a general code-quality pass over `selfhost/*.mdk` (+ `llvm_emit.mdk`,
  `runtime/medaka_rt.c`): style + readability + naming consistency, **DRY**
  (consolidate duplicated helpers — e.g. `util.mdk` vs prelude, repeated emit
  patterns), remove dead/historical code + stale comments, and dogfood Medaka
  idioms where genuinely clearer (extends the guard-dogfood pass — sections,
  comprehensions, guards, pipes; per the "verify on binary, most sites aren't
  wins" guidance). **The differential harness + bootstraps + self-compile fixpoint
  are the safety net** — every refactor must be semantics-preserving (all gates
  byte-identical, all `bootstrap_*`/`selfcompile_*` green), so this is the safe
  moment to do it. Pairs naturally with the completeness/coverage work (item 2).

**Gated milestone — retire `lib/*.ml`.** Once the bar is met: make native
`medaka` the default build, re-root the remaining gates on the hybrid oracle,
archive/delete the OCaml compiler, update all docs. Sequenced toward, not dated.

After Stage 3, the **capability-effects wedge** (Phase 146) + the **WasmGC
backend** are the product horizon (see the Workstreams table).

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority.

### Stage 4 — full tooling port → native `medaka`, retire OCaml (decided 2026-06-10)

The compiler pipeline self-hosts (`selfhost/`); the native backend compiles it. What
remains in OCaml (`lib/`+`bin/`) is the **tooling around** the pipeline. **Decision
(2026-06-10): port ALL of it to Medaka, targeting a natively-compiled `medaka` binary
(LSP + REPL in scope) — the full-purity retirement endpoint.** Each tool is
differential-tested against its OCaml twin (same oracle pattern as the pipeline).

Host capabilities already present (`stdlib/runtime.mdk`): stdin (`readLine`/`readLineOpt`/
`readAll`), file IO (`readFile`/`writeFile`/`appendFile`/`fileExists`), `args`, `getEnv`,
`exit`, `json.mdk`. **Missing:** a subprocess/`exec` extern (for `medaka build`→`clang`),
and a TOML reader (for `medaka.toml`).

**Phase A — prerequisites (parallelizable; independent of the emitter-gap work):**
**Phase A — prerequisites (parallelizable; independent of the emitter-gap work):**
1. ✅ **`printer.mdk`** (AST→source, mirror `lib/printer.ml`) — DONE 2026-06-10. Full
   Wadler/Leijen doc algebra, every AST node, **26/26 byte-identical** to OCaml
   `program_to_string`; `dev/print_probe.ml` oracle + `test/diff_selfhost_printer.sh`.
   NOTE: this is `program_to_string` (AST→source core), NOT `format_program` (comment-
   preserving) — see A.5.
2. ✅ **Subprocess extern `runCommand`** — interpreter side DONE 2026-06-10
   (`runtime.mdk` + `eval.ml` `Unix.create_process` + `medaka_rt.c` `fork`/`execvp`;
   `: String -> List String -> <IO> Result String (Int, String, String)`). **FOLLOW-UP
   remaining:** the `llvm_emit.mdk` extern-table entry for native emission (deferred during
   GAP 1; do now that `llvm_emit.mdk` is free).
3. ✅ **TOML reader** (`stdlib/toml.mdk`) — DONE 2026-06-10. Mirrors `project_config.ml`'s
   subset (`[section]`, `key="string"`, string arrays, `#` comments); 12/12 doctests.
4. **Diagnostics surfacing layer** (mirror `lib/diagnostics.ml` 479) — structured errors
   the CLI + LSP consume. ⏳ TODO.
5. ✅ **Comment side-channel** (selfhost lexer) — DONE 2026-06-10. `RComment` in
   `lexer.mdk` (stripped before layout → token stream byte-identical); `collectComments`
   surfaces line/col/text; **8/8 byte-identical** to `lib/`'s channel. Unblocks the fmt port.

**Phase B — tools (each differential-tested vs OCaml):**
6. ✅ Formatter `medaka fmt` — DONE 2026-06-10 (`a933af9`). `selfhost/{fmt,printer}.mdk` +
   `fmt_main.mdk`; comment interleaving over the position+comment channels; **37/37 byte-identical**
   to `medaka fmt` (11 comment-heavy + 26 comment-free). Gate `test/diff_selfhost_fmt.sh`.
7. ✅ `medaka test` — DONE 2026-06-10 (`c6a4fd0`). `selfhost/{doctest,prop_runner,test_main}.mdk`;
   **6/6 byte-identical** (both doctest paths + passing props + FAIL path); `eval.mdk` gained an RNG +
   `evalModulesRootEnv` + eval-entry exports. Gate `test/diff_selfhost_test.sh`.
   **Completeness follow-ups (B.7, not blocking — task #28):**
   - **(a) Error-path doctests not mirrorable** — OCaml `eval_suppressed` traps a per-example runtime
     panic → one `ERROR …` line; the selfhost eval oracle has NO per-binding exception recovery (a
     panic aborts the whole run). Needs per-binding panic trapping in selfhost eval.
   - **(b) Prop RNG parity (failing props only)** — 3 RNGs in play (reference SplitMix64 externs, OCaml
     `Random` in `prop_runner.ml`, selfhost's new LCG); passing props are RNG-independent (match), but a
     FAILING prop's shrunk counterexample diverges. Reference uses OCaml `Random`, NOT the SplitMix64
     externs (see [[project_rng_splitmix64]]).
   - **(c) Selfhost eval-oracle extern/typecheck gaps block doctests on some stdlib files** (pre-existing,
     not doctest bugs): `map.mdk`/`set.mdk` map/set literal sugar in synth bindings → `unsupported
     expression (slice 1)`; `array.mdk` needs `arrayCopy`; `hash_map`/`hash_set` need `hashInt`;
     `core.mdk` char doctest hits `charCode: not a Char`. **Most actionable cluster** — closing it widens
     doctest coverage to the full stdlib.
8. ✅ `medaka new` — DONE 2026-06-10 (`88c3b55`). `selfhost/new_cmd.mdk` + `new_main.mdk`; 4
   scaffolded files byte-identical; added `makeDir` extern. Gate `diff_selfhost_new.sh`.
9. ✅ REPL — DONE 2026-06-10 (`a300f73c` merge). `selfhost/repl.mdk` + `repl_main.mdk`; banner/
   prompt/`:type`/`:browse`/`:reset`/`:quit` + error recovery; gate `diff_selfhost_repl.sh`.
   (`:load`/`:reload` deferred → process isolation, per [[no-catchable-panics-isolation]].)
10. LSP (`lsp_server.ml`+`lsp_log.ml`, 912+83) — **SCOPED 2026-06-10 (7-slice plan, task #36).**
    Expr-level locations are CHEAP (transparent `ELoc` wrapper, fixpoint-safe via sexp+core_ir
    strips). 2 hard prereqs: **#37 `readExactly` stdin extern** (JSON-RPC body) + **#38 typecheck
    env/`ppScheme` exposure** (hover/completion/inlay). parse-error-as-Result ✅ (`1fa79c0`),
    diagnostic-loc via `ELoc` (B.10.2). Slices: JSON-RPC skeleton → diagnostics → ELoc → located
    diags → fmt/symbols/def/highlight → hover/completion/inlay → analyze_project.
11. ✅ `build` driver — DONE 2026-06-10 (`1bc6005`). `selfhost/build_cmd.mdk` + `build_main.mdk`;
    shell-out emit (Ref isolation) + `runCommand`→clang; 9/9 differential builds == OCaml `medaka
    build`. (`runCommand`/`makeDir` native-emit done, #18 `a0c7b111`.)

**Phase C — capstone (#57, IN PROGRESS — Slices 0–2 DONE 2026-06-10):**
12. CLI dispatcher `selfhost/medaka_cli.mdk` (replaces `bin/main.ml`, 1076 LOC), native-compiled into
    the `medaka` binary — the retirement integration piece. Converges with bar-item-5 (self-bootstrap).
    **UNBLOCKED 2026-06-10** by clause-label SSA (#53). **Slices landed:**
    - **Slice 0+1 ✅ (`8a6c2f7`):** split `check.mdk` into logic (`runCheck`) + driver `check_main.mdk`
      (mirrors `fmt_main.mdk`); `medaka_cli.mdk` dispatcher routes `check`/`fmt`/`new` + help + a
      "not yet in native CLI" stub for deferred subcommands. `check.mdk`/`medaka_cli.mdk` are NOT in
      the emitter graph (`elaborateModules`) → seed byte-identical. Gate `test/diff_native_cli.sh`.
    - **Slice 2 ✅ (`dd6edbc`):** wired `run` + `build`. `build` → `build_cmd.runBuild` (thin —
      emit is a `runCommand` shell-out, emitter NOT pulled in). `run` → `eval.mdk` load→typecheck→eval,
      which **pulls the ENTIRE front-end + interpreter into `medaka_cli`'s native module graph** (the
      ultimate multi-module emittability stress test). **It native-compiled CLEAN — no new emitter gap.**
      Combined OCaml-free toolchain = one **1.59 MB** binary (check/fmt/new/build/run). **OCaml-free
      build+run proven end-to-end** (native `./medaka build` + `MEDAKA_EMITTER=./medaka_emitter` + clang,
      zero OCaml at runtime). `diff_native_cli.sh` 50/0; seed byte-identical; fixpoint C3a/C3b green.
      *Adjacent gap found (#61, not retirement-blocking):* native `args` returns whole process argv (no
      slicing primitive) → `run FILE a b c` hands the program the CLI's full argv, and native `run`
      can't host the emit shell-out → OCaml-free emit host must be `MEDAKA_EMITTER`. A `mdk_set_args`
      primitive would fix both.
    - **Remaining:** Slice 3 (`test`), Slice 4 (`repl`/`lsp`).

    The parked dispatch gaps (#54 map / #55 sum-product / #50 parametric-Ord / #21 nested dicts /
    C7-native) are verified **NOT on this critical path** (the tooling never touches them) → end-user
    stdlib-completeness, not retirement-blocking.

**Implied sub-tracks:**
- **Stdlib emittability sweep** — native-compiling these tools needs the FULL stdlib
  emittable (`json`/`map`/`string`/`io`/…), not just `core.mdk`. Each big tool will hit
  native construct gaps → a forcing function feeding the GAP-2/tuple/emitter work.
- Coverage (`coverage.ml`, 148) + bench (`bench_runner.ml`, 44) — auxiliary, port last.

### Future idea (parked, not scheduled): effect-reannotation utility

**Problem (the effect-annotation tax):** add an effect at a program leaf — e.g. a `<Mut>`
deep in a helper — and every transitive caller's written effect annotation is now too
narrow, so each one must be hand-updated up the call graph. Tedious for humans and a
recurring friction for agents.

**Idea:** a utility that propagates the new effect and **rewrites the stale annotations
automatically.** Medaka is well-suited to this because the effect system **already infers
the true effect rows** — the typechecker already knows where an annotation is narrower than
the inferred effect (that's the same information behind the "effect not in annotation" error).
So the tool mostly *consumes* existing inference: run effect inference, find each signature
whose written row ⊊ inferred row, and rewrite the annotation to the inferred row (using the
printer/`fmt` machinery to edit in place, comment-preserving).

**Surfaces:** an LSP **code action / quick-fix** ("update effect annotation" — and a
"propagate effect through callers" project-wide variant), and/or a CLI command
(`medaka fix-effects`). Leverages: the effect inference (have it), the located diagnostics +
LSP (B.10.x), `parseWithPositions`/`ELoc` for the edit site, and `fmt`/printer for the rewrite.

**Why parked:** nice-to-have ergonomics, not on the retirement path. Lands naturally AFTER the
LSP code-action infrastructure exists. Cross-ref [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md).

### Capability-effects wedge — near-term sequence

**Owning roadmap:** [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (language
work) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product/runtime).
Architecture context: the "Targets & the WASM soft-pivot" callout above. Effect
labels also drive [`STDLIB.md`](./STDLIB.md) §"Label refinement roadmap".

**Done (foundation):** effect soundness — propagation/inference, higher-order `<e>`
composition, binding-boundary escape, laundering soundness — gap 1, reference +
selfhost mirror ✅; user-definable fine-grained labels (`effect Foo` declaration) —
gap 2 ✅; cross-module effect label export (`exp_effects` across the loader
boundary) — gap 3 ✅; stdlib capability audit ✅; the minimal **"wow" demo** ✅
(`demo/plugin_good.mdk` + `demo/plugin_malicious.mdk` + `medaka check-policy`: the
malicious plugin buries `fetch` four calls deep; the harness rejects it with the
full call chain). Detail in CAPABILITY-EFFECTS §5a + the Phase 146 entry below.

**Near-term (remaining), dependency-ordered:**
1. **Research pass** — WASI Preview 2 / Wasm component-model capability model;
   edge-host isolation (Cloudflare/Fastly/Fermyon); object-capability &
   effects-as-security literature; competitor scan (MoonBit closest; Grain; Roc).
   TCO + WasmGC viability already verified (STAGE2-DESIGN §2.4b). Output: a findings
   note. Skill: none (research).
2. **Design note + manifest format** — concrete surface syntax + the
   capability-manifest format a host reads, pressure-tested against the 2–3 worked
   plugin shapes in CAPABILITY-PLATFORM.md. Gate before manifest coding. Skill:
   **add-language-feature** (planning).
3. ✅ **Cross-module effect label export** — done (gap 3, 2026-06-07). `pub effect
   Fetch` visible across the loader boundary via `exp_effects` in `module_exports`.
4. **Manifest emission** — emit `[package.capabilities]` from a verified entry
   point's effect row; final Phase 146 item, waits on label refinement
   (STDLIB.md §"Label refinement roadmap").

Downstream (captured, NOT near-term): **Phase 146b** parameterized effects
(CAPABILITY-EFFECTS §6a); the **WasmGC backend** (STAGE2-DESIGN §2.4b); the
**capability platform/runtime** (CAPABILITY-PLATFORM.md §9 open questions).

### Native backend (Stage 2) — build log — ✅ COMPLETE (archived)

The D0–D4 dispatch-staging + native-extern-catalog build log (how the spike
became a self-hosting native compiler) is archived in
[`PLAN-ARCHIVE.md` → Archived native backend build log](./PLAN-ARCHIVE.md#archived-native-backend-build-log).
Current native-backend state + residual gaps: `selfhost/BOOTSTRAP.md`,
`selfhost/EMITTER-GAPS.md`. Forward work:
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml).

### Self-host (Stage 1 tail)

#### Known parser gaps (selfhost `parser.mdk`)

Constructs the **OCaml parser accepts but `selfhost/parser.mdk` rejects** — check
here before assuming `selfhost/` can parse a construct (AGENTS.md points here).
The differential `test/diff_selfhost_parse*` / `diff_selfhost_check*` gates only
cover the corpus; these are known holes outside it.

- **`let … in` as an indented clause body.** A clause whose head is on its own
  line with the body on the next indented line, where that body is a `let … in`
  expression — e.g.
  ```
  f x =
    let go n = if n == 0 then 0 else go (n - 1) in go x
  ```
  Oracle **accepts**; selfhost **rejects** (`parser.mdk` parse error). Workaround:
  put the whole clause on one line (`f x = let … in …`). Verified 2026-06-09 (T2).
  (The general "expression RHS cannot wrap to a second indented line" rule —
  SYNTAX.md — is a *language* rule both honor; this is a selfhost-only divergence.)

- ✅ **Lexical-addressing perf hook — eval-consumption half. CLOSED (non-win on
  the tree-walker; 2026-06-05).** Wired `annotateProgram` into the single-file eval
  path and measured: correct (18/18 EVAL goldens byte-identical with `EVarAt`
  consume active; the slot/name assert never fires) but **~2.5% slower** than the
  by-name baseline (`fib 25`), independently re-confirming the earlier finding
  (list-indexed neutral, array frames −14%). Reverted the wiring; the `EVarAt` arm
  stays dormant. The lever's payoff is captured by the native LLVM backend; the
  bytecode VM (§2.2) that previously held this note was removed 2026-06-10. Do not
  re-attempt on the tree-walker. See `selfhost/PERF-NOTES.md`.

> **Note for OCaml-compiler tasks below:** the self-host port mirrors the OCaml
> pipeline stage-for-stage (`selfhost/{lexer,parser,desugar,resolve,marker,
> exhaust,typecheck,eval}.mdk`). A change to a *ported* stage in `lib/` must be
> mirrored into the corresponding `selfhost/*.mdk` and re-validated with that
> stage's `test/diff_selfhost_*.sh`, or the differential harness breaks. Changes
> to *non-ported* parts (printer/`fmt`, diagnostics, the CLI driver, doctest) have
> no self-hosted counterpart.

### Compiler / language

- ⭐ **Phase 146 — Capability-safe effects (the headline wedge). IN PROGRESS.**
  Make Medaka's existing effect rows **sound + fine-grained** so a function's type
  becomes a compiler-verified **capability manifest** — "the program tells you (and
  the host that runs it) exactly what it can do." Target: WebAssembly edge / plugin
  / sandboxed compute for untrusted, increasingly AI-generated modules. **Effect
  *tracking*, NOT algebraic-effect *handlers*** (no `perform`/`handle`/`resume`; the
  host is the handler). Effects stay **erased at runtime** (manifest is metadata).
  Skill: cross-cutting → **add-language-feature**. **Note:** deliberately revisits
  the *row-polymorphism* rejection in PLAN-ARCHIVE §8, narrowed to *effect* rows.
  - **Full design, per-piece status, and the implementation log live in
    [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §5a.** The near-term sequence
    is the [Capability-effects wedge](#capability-effects-wedge--near-term-sequence)
    section above.
  - **Done:** gap 1 (soundness — propagation, laundering, directional subsumption),
    reference + selfhost mirror ✅; gap 2 (user-definable `effect Foo` labels) ✅.
  - **Remaining:** cross-module label export → manifest emission (both in the wedge
    sequence above); **Phase 146b** parameterized effects `<Fetch "x.com">` /
    `<KV "ns">` (designed in CAPABILITY-EFFECTS §6a, follows gap 2).

- ~~**Phase 145**~~ **DONE.** See PLAN-ARCHIVE.md.

- ~~**Phase 143**~~ **DONE.** See PLAN-ARCHIVE.md.

- **Phase 101 — drive property generation/shrinking through the `Arbitrary`
  interface (101b). DEFERRED, reassess later.** 101a (registry-first
  `arbitrary`/`shrink`, native element recursion) is DONE (PLAN-ARCHIVE.md). What
  remains — **101b**: synthesized typed generators + parametric `core.mdk`
  `Arbitrary` impls. Phase 83/84 made single-level interface-driven generation
  work, but **nested** parametric elements (`List (List Int)`) still fail — the
  flat `VDict of string` dict can't carry a recursive element dict. Since 101a
  already handles every case *including* nesting and makes hand-written element
  impls win, 101b's only unique gain is honoring a user's custom
  container-*generation* strategy — niche. Revisit only if that need arises (also
  wants structured/recursive dicts, same as Phase 83/84 #5). WIP on branch
  `claude/suspicious-sammet-21d73e` (commit `860ba12`). Skill:
  **add-language-feature** (cross-cutting).

- **Phase 148 (proposed) — diagnose duplicate / non-contiguous top-level bindings.**
  Two same-named top-level bindings separated by other declarations are silently
  **coalesced into one multi-clause function** instead of being flagged. Symptoms,
  verified on the binary:
  - conflicting type sigs → a confusing `Type mismatch` reported at the *first*
    binding's body, with NO mention that a duplicate exists elsewhere (this cost a
    real debugging loop while adding `cellTag`'s helpers — an accidental second
    `indexOfStr` 600 lines from the original surfaced only as "Option Int vs Int");
  - matching sigs → silently accepted, the later definition becoming **dead clauses**
    with no warning.
  The resolver already detects `Duplicate constructor: Bar`, so duplicate-detection
  exists for the *constructor* namespace but not for value/function bindings, and
  there is no "equations must be contiguous" check (Haskell errors *Multiple
  declarations of foo* here). Fix: in `resolve` (+ selfhost `resolve.mdk` mirror),
  treat a same-named top-level binding separated from its earlier clauses by an
  intervening declaration as an error (`DuplicateBinding` / "clauses of `foo` must be
  contiguous"); adjacent multi-clause stays valid. Lands in resolve + diagnostics,
  not the typechecker — a missing diagnostic, not a unification change. Low blast
  radius; high debuggability win. Skill: **add-language-feature** (resolve-rooted).

- **Phase 149 (proposed) — record rest-capture pattern + construction spread sugar.**
  Surface sugar for the "transform some fields, keep the rest" idiom that recurs all
  over the compiler passes (`annotateDecl`, `desugar`, etc.):
  ```
  annotateDecl DInterface { methods, ...rest } =
    DInterface { methods = map annotateIfaceMethod methods, ...rest }
  ```
  desugars to today's record/variant update — `DInterface { rest | methods = ... }`.
  **Scope decision (locked 2026-06-09): FULL rest semantics, NO row polymorphism.**
  `rest` binds to the **whole scrutinee** at the *same nominal record type* (it still
  carries the captured fields — harmless, the explicit field overrides it on the
  construct side). So this is **same-nominal-type only**: you cannot spread `rest`
  into a *different* constructor, and `rest.field` for a captured field returns the
  *old* value. The cross-type version (a standalone "type-minus-fields" value) needs
  row/structural records — **explicitly out of scope** (stays on the PLAN-ARCHIVE §8
  / "Won't-do" row-polymorphism rejection).
  - **Why it's cheap:** both halves land on existing nodes. Construction spread →
    `EVariantUpdate` (named-field ctors, `ast.ml:160`/`eval.ml:1051`) or
    `ERecordUpdate` (bare record types). Pattern rest-bind → bind the matched
    `VCon`/`VRecord` value (`eval.ml:431-466`). No new typecheck/eval *machinery*,
    no new runtime value shape.
  - **The work (thread through the pipeline + selfhost mirror):**
    1. **Parser** (`parser.mly:538`, `record_pat_rest`): the rest tail is currently
       an anonymous `ELLIPSIS` (= "ignore remaining fields"); extend to
       `ELLIPSIS IDENT` to carry a **bind name**. Add `...IDENT` spread to the
       record-construction field list (`parser.mly:805-830`).
    2. **AST** (`ast.ml:39`, `PRec`): the rest flag is `bool` → widen to
       `ident option` so the bound name survives to eval. New construction-spread
       carries the rest source expr (reuse / lower to the update nodes in desugar).
    3. **Typecheck** (`typecheck.ml:1302`): on a named rest, add `rest : <nominal
       record type>` to the env. Confirm `has_rest=true` already relaxes the
       all-declared-fields-must-appear check (it must, for partial mention — verify;
       may be part of the work).
    4. **Eval** (`eval.ml:431-466`): bind the rest name to the matched record value.
       Construction spread is pure desugar → existing update eval, so no new arm.
    5. **Exhaust** (`exhaust.ml:65`): unchanged — rest fields already map to
       wildcards.
    6. **Selfhost mirror** (`selfhost/{parser,desugar,typecheck,eval}.mdk`) +
       `SYNTAX.md` entry + `test/parse_fixtures` / round-trip / eval fixtures.
  - Estimate: ~a day (Full scope). Skill: **add-language-feature** (cross-cutting —
    new pattern + construction syntax through parser/ast/typecheck/eval + selfhost).

- **Phase 150 (proposed) — better error for `do` used on a non-monad.** Using `do`
  to sequence IO (a common newcomer mistake, since Medaka IO is **not** a monad —
  imperative IO is a bare indented block, see [[medaka-io-not-a-monad]] / SYNTAX.md
  §"do notation") produces a baffling diagnostic. Verified on the binary:
  ```
  main = do
    println "one"
    println "two"
  -- → 2:12: Type mismatch: a b vs Unit   (caret on the string literal!)
  ```
  No mention of `do`, monads, or the fix; the caret lands on `println`'s argument.
  **Root:** `do` lowers to `andThen`/`pure` in **`desugar.ml` (runs first)**, so by
  typecheck the `do` shape is gone — unification fails deep in the synthesized chain
  with no provenance back to the `do`. **Fix path:** thread `do`-origin provenance
  from the desugaring (tag the lowered `EApp (andThen …)`/`pure` nodes, or keep an
  `EDo` source span) so the typechecker, on failure to satisfy the
  `andThen`/`Monad`/`Mappable` constraint for a do-lowered node, emits a tailored
  `type_error`: *"`do` requires a monad (e.g. `Option`/`Result`); for imperative IO
  sequencing use a bare indented block."* Lands in `desugar.ml` (provenance) +
  `typecheck.ml` (the tailored error) + selfhost `{desugar,typecheck}.mdk` mirror.
  Surfaced when an orchestrated agent misused `do` for IO and mis-filed the failure
  as a "missing IO monad gap" (2026-06-09) — the language is fine; the *diagnostic*
  is the gap. Skill: **add-language-feature** (desugar+typecheck provenance thread;
  not pure harden-typechecker — it needs the desugar tag).

- ~~**Phase 83 / 84 #5 — recursive/nested instance dictionaries**~~ **DONE
  (reference + selfhost mirror, 2026-06-05).** Structured/recursive runtime dicts
  (`VDict`/`VDictHead` + `RKey` routes) replaced the flat impl-key strings;
  `def : List (List Int)` → `[[0]]` etc. on both loader paths. Closing this also
  lifted the Phase 101b nesting limit. Write-up moved to PLAN-ARCHIVE.md (§"Phase
  83/84 residual #5"). No Phase 83/84 dispatch residuals remain.
- ✅ **Core IR: reserved-name collision in `decodeHead`. DONE (2026-06-07).**
  `core_ir_lower.decodeHead` keyed the built-in list/tuple/unit heads by the
  user-facing NAMES (`"Cons"` → `HCons`, `"Nil"` → `HNil`, `"Unit"` → `HUnit`),
  so a user constructor literally named `Cons`/`Nil`/`Unit` aliased the built-in
  head. `check` accepted it and the AST tree-walker ran it correctly, but `ceval`
  panicked `no matching clause in match` (`core_ir_eval.mdk:151`) — `HCons`/`HNil`
  route `headExtract` to the built-in `VList` shape while the value is a user
  `VCon "Cons"`. The 2026-06-07 rep ratification promoted this from latent
  (ceval-only) to real-backend-blocking: the spike's i64-hash immunity (both
  user-`Cons` and built-in list hash to `"Cons"`) does NOT survive the ratified
  dense i32 ctor-ordinal, under which a user `Cons` carries its type's ordinal
  while a name-keyed match still routes to the built-in head.
  **Fix path selected (research):** the two pattern forms — built-in `PCons`/
  `PList` vs a user `PCon "Cons"` — are distinct *forms* only up to `canonPat`,
  which collapsed both onto the bare name `"Cons"`; past that point only the name
  reaches `decodeHead`. So neither prompt option was needed — instead `canonPat`
  now lowers the built-in forms to **reserved synthetic head names** (`__cons__`/
  `__nil__`/`__unit__`, un-writable as user ctors, mirroring the existing
  `__tuple__`), and `decodeHead` keys those. A genuine user ctor keeps its own
  name and lowers to `HCon "Cons"`. This is the lowest-blast-radius fix: **no
  `CHead` shape change**, so no serializer / sexp / consumer churn. The whole
  matrix machinery (colHeads/specializeCon) is pure string-equality and internal
  to `compileTree`; serialized Core IR for genuine built-in lists is byte-identical,
  and `conHeadInfo` maps `HCons` and `HCon "Cons"` to the same `hashName "Cons"`
  tag so the LLVM spike stays green. Regression guard: `test/eval_fixtures/
  adt_user_cons_nil.mdk` (byte-identical across tree-walker, ceval, and the LLVM spike; `test/llvm_fixtures/adt_list_fold.mdk` was unwound from its
  `Node`/`Empty` workaround back to `Cons`/`Nil`.

- **Phase 147 (proposed) — type-directed constructor disambiguation.** Today a
  constructor name must be **globally unique** (resolve rejects `Duplicate
  constructor: Bar`), so `data A = Foo | Bar` and `data B = Bar | Baz` cannot
  coexist — the Haskell-within-a-module model. Two cleaner end-states exist:
  **OCaml-style** (unqualified `Bar` allowed in multiple types, resolved by the
  expected type at the use site; ambiguity warns / annotates) and **Rust/Swift-style**
  (always-qualified `A.Bar`). Recommend **OCaml-style**, because Medaka already has
  the machinery: **Phase 72** added `field_owners` (receiver-directed resolution) so
  record *field* names can be reused across types — this is the same problem for the
  *constructor* namespace, i.e. generalize `field_owners` to ctors. **Coupling to the
  native rep:** the ratified **per-type ctor-ordinal** tag (the LLVM spike's tag
  scheme) is correct *precisely because* a constructor is conceptually owned by its
  type; today's flattened namespace forces the tag to be keyed by globally-unique
  *name* (and the spike's arg-tag dispatch to carry a synthetic type-id alongside the
  ordinal — see `llvm_emit.mdk` `cellTag`). Per-type ctors would let lowering carry
  `(type, ctor)` directly, dropping the name-keyed lookup and the built-in-list
  special-casing. **Scope/cost:** resolver gains ambiguity handling + optional
  qualifier syntax + the `data`-decl/inference coupling; a surface-syntax relaxation,
  not a semantic necessity (the underlying model is already per-type). Not bundled
  with the bootstrap-era tag work. Skill: **add-language-feature** (resolve +
  typecheck, cross-cutting).

### CLI surface (Phase 82, continued)

The design spec lists `new build run check test fmt lsp doc add remove update`;
`check / run / test / repl / lsp / fmt / new` exist, plus `bench`. Remaining
non-package-manager gaps:

- **`medaka build`** ✅ **MVP done (2026-06-09, `39f3318`)** — `medaka build
  foo.mdk [-o out]` compiles arbitrary user programs to native binaries:
  self-hosted emitter (`selfhost/llvm_emit_modules_main.mdk`, run as a subprocess
  capturing IR) → `clang` + `runtime/medaka_rt.c` + libgc → binary.
  `lib/build_cmd.ml`, `test/build_cmd.sh` (build+run+diff vs interpreter oracle).
  Empty-prelude subset only (full `core.mdk` blocked on the `max`/`min` gap + no
  DCE — see [Stage 3 #2](#stage-3--make-the-llvm-backend-canonical-retire-ocaml)).
  **Deferred:** a build-artifact CACHE — the serialized Core IR exists
  (`selfhost/core_ir_sexp.mdk` — `cprogramToSexp`/`parseCProgram`, round-trip
  proven; `test/diff_selfhost_core_ir_roundtrip.sh`) but a cache-key strategy
  (content hash of source + transitive imports) + on-disk layout remain unbuilt;
  also install-prefix asset packaging (assets resolved repo-relative today).
- **`medaka doc`** ✅ — done: `lib/doc.ml` + `test/test_doc.ml`.  Comment→decl
  matcher (parallel `Lexer.take_comments()` stream matched by position),
  signature renderer via `Typecheck.pp_scheme` for values / AST renderers for
  types, Markdown output (one `## name` section per public decl).  Single-file
  typecheck path; multi-module follow-up tracked separately.
- **`medaka check --json` multi-file** — currently single-file (`Diagnostics.
  analyze` doesn't invoke the `Loader`), so a file with `import`s can
  resolve-error in the JSON output. Multi-file `--json` is the follow-up.
- Skill: none specific (lands in `bin/main.ml` + `lib/lsp_server.ml`).

### Standard library (Phase 19)

**Owning roadmap:** [`STDLIB.md`](./STDLIB.md) §"Remaining work" + §"Label
refinement roadmap" (the effect-label half is shared with the capability wedge).

Core modules 1–9 are **complete** (`core`/`list`/`array`/`string` + `map`/`set`,
hash containers, `io`, `mut_array`, `json`) — see PLAN-ARCHIVE.md. `stdlib/string.mdk`
API frozen 2026-06-03 (Phase 128). Remaining work is incremental additions tracked in
STDLIB.md: `List` `zip`/`zip3`/`zipWith`/`unzip`, an explicit `Semigroup List` impl,
JSON pretty-printer + `ToJson`/`FromJson` codecs, and the effect-label refinement
steps (`wallTimeSec`→`<Time>`, `<IO>` split, `panic`/`exit` split). Skill:
**extend-stdlib** (user-reserved unless asked).

### Blocked on a package manager (out of scope until one exists)

- `medaka add` / `remove` / `update`, and a `medaka.lock` file.

---

## Won't-do (kept intentional)

- **Phase 78c — multi-module method shadowing.** Investigated 2026-06-01 and
  dropped: the motivating need (`length`/`isEmpty`/`toList` on `Array`) is
  already met by interface impls, and there is no safe export path for a bare
  `length : String -> Int` (it would shadow `Foldable.length` everywhere). The
  real lever, if ever needed, is a `Sized`/`HasLength` interface — which is
  stdlib design, not a compiler feature. (Phase 112 — the *narrower* lever:
  resolve to a local/imported name only when the method has no applicable impl —
  is **DONE** (PLAN-ARCHIVE.md); 78c stays dropped.)
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
