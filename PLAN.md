# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-09)

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
| **Native backend (Stage 2)** | [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) + [`selfhost/BOOTSTRAP.md`](./selfhost/BOOTSTRAP.md) | ✅ **complete** | Core IR + bytecode VM (§2.1–2.2) done; LLVM backend promoted from spike to a **native self-hosting compiler** — all 7 stages native==interpreter (141 fixtures), self-compile **fixpoint reached** (C1 emitter-IR reproduction · C2 native compiles the real lexer · C3 `IR1==IR2`). Runtime dict-passing dispatch (D3a/D3b done); Boehm GC; CTGuard lowered. Residual: `max`/`min` over primitive `Ord` (dead code). |
| **Make LLVM canonical (Stage 3)** | **this file** → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) | 🟡 **in progress** | 🔝 **TOP: close [TYPECHECK-AUDIT](./selfhost/TYPECHECK-AUDIT.md) soundness findings** (S1→S2→T1→T2→S3→L1/L2→C→D; gates `lib/` retirement). ✅ #1 `medaka build` CLI + #2a prelude (DCE/unit-head/flip) + #2b Unit-return done. Then: emitter-gap sweep → port OCaml test suites → differential fuzzer → stack scalability → perf → housekeeping refactor → self-bootstrapping build → retire `lib/` (gated). |
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
CANONICAL compiler** — the one users invoke and the one that builds the compiler —
and retires the OCaml reference (`lib/*.ml`) on a **gated** schedule (no fixed
date; deletion is unlocked only when the bar below is met).

**The "native is canonical" bar (gates `lib/` retirement):**
1. `medaka build` compiles + runs arbitrary USER programs natively (not just the
   compiler's own stages).
2. The ported test suite passes on the native compiler (the OCaml `test/*.ml`
   suites re-expressed as Medaka tests).
3. A differential fuzzer runs clean (random valid programs: native == oracle).
4. Performance is acceptable (self-compile time + emitted-code speed within an
   agreed factor of the OCaml compiler).
5. The build self-bootstraps without the OCaml interpreter (a seed path that
   produces the native compiler from the `.mdk` sources).
6. **The selfhost typechecker is sound + coherent** — the
   [TYPECHECK-AUDIT](./selfhost/TYPECHECK-AUDIT.md) soundness findings are closed
   (value restriction, dict-application gate, method-dict offset, coherence
   checking), so nothing downstream depends on a guarantee only `lib/` enforces.

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

> **Overnight autonomous run (2026-06-09 22:xx → 07:00 PDT):** working the audit
> queue unattended. Done: S1, S2, T1, T1b, T2, S3. **L1 deferred** (E4-gated — fix
> with the E4 work). **L2 deferred for the unattended run** (latent + arg-tag-masked;
> the full fix touches the fragile route-keying area + the interim typecheck error
> risks over-rejection — wants careful attention near E4, not unattended). Proceeding
> to the **C-series** (real correctness divergences, cleaner oracle-mirrors), then
> the D-series, then broader Stage-3 roadmap. Skipping only genuine language-design
> items.


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
4. **Differential fuzzer.** Generate random parse-valid / well-typed Medaka
   programs and diff native vs the tree-walker oracle. Highest-leverage bug finder
   — fixtures have finite coverage; the fuzzer hunts the long tail
   (order-dependence, value-rep edges, dispatch corners, big/deeply-nested
   inputs). Shrink failing cases to minimal repros.

**Supporting / parallel work:**

- **Stack scalability** — the `-Wl,-stack_size` band-aid is **maxed at 512 MB on
  arm64** (the linker rejects larger). (a) **Worker-thread big-stack** in
  `medaka_rt.c` (emit the entry as a named fn; C `main` spawns a large-stack
  `pthread`) — general, covers deep STRUCTURAL recursion (typecheck/eval on big
  inputs); do first. (b) **TRMC** (tail-recursion-modulo-cons / destination-passing)
  in the emitter for `x :: recurse` list-builders → O(1) stack — the principled
  fix for the streaming loops (OCaml `[@tail_mod_cons]` is the blueprint); the
  cons-loop optimization on top of (a). Not yet forced (512 MB sufficed through C3).
- **Error-path / diagnostics parity.** The bootstrap diffed happy-path stdout;
  native panics/aborts/diagnostics need parity with the interpreter (the selfhost
  error path was noted unvalidated). Diff error output too.
- **Performance.** Emitted IR is naive (`clang -O0` in harnesses): turn on `-O2`,
  measure; consider value-rep / dispatch optimizations + an emitter-side pass if
  profiling demands. Benchmark native-compiler-compiling-itself vs the OCaml
  compiler (bar-item 4).
- **Self-bootstrapping build** (bar-item 5) — remove the OCaml-interpreter
  dependency from producing the *first* native compiler: a checked-in/reproducible
  seed binary that compiles the `.mdk` sources, or a documented multi-stage
  bootstrap from a minimal seed. (C3 proves the native compiler reproduces itself;
  this makes the *build* not need `medaka run`.)
- **Cross-platform** — currently arm64 macOS only. Linux/x86-64 (runtime, the
  stack-flag specifics, clang target triple) before the backend is broadly
  canonical.
- **GC** — Boehm conservative GC today. Evaluate precise GC + the WasmGC path (the
  wedge target needs WasmGC, a sibling backend off the Core IR seam — §2.4b).
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
  stays dormant. The lever's payoff is already captured by the bytecode VM (§2.2),
  which lowers the same addresses to O(1) compiled slot loads. Do not re-attempt on
  the tree-walker. See `selfhost/PERF-NOTES.md`.

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
  adt_user_cons_nil.mdk` (byte-identical across tree-walker, ceval, bytecode VM,
  and the LLVM spike); `test/llvm_fixtures/adt_list_fold.mdk` was unwound from its
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
