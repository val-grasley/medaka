# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-07)

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

**The self-host port (Stage 1) is complete** — all eight pipeline stages are
ported to Medaka and validated byte-for-byte against the OCaml reference, and
the bootstrap closure ("the compiler processes its own source") has landed for
all four Legs A–D. See [North star → Stage 1](#stage-1--self-host-on-the-interpreter)
below and `selfhost/README.md` for the full slice log. The forward-looking
performance levers are all resolved (lexical-addressing eval-consumption half
measured a non-win on the tree-walker and is parked; see `selfhost/PERF-NOTES.md`).

**Stage 2 (native backend) is underway** — Core IR + evaluator (§2.1) and the
bytecode VM (§2.2) are fully done, including the §2.2 capstone (lexer stage runs
byte-for-byte through `bcEvalModulesOutput`); the LLVM toolchain de-risking spike
is **complete** — it lowers the full non-GC Core IR surface, runs on Boehm GC, and
the **entire native extern catalog is ported** (slices 1–14 + RNG/sorts/hash, all
byte-identical against the oracle). The remaining work is promoting the spike into
the real backend and the bootstrap closure. See the [Workstreams table](#workstreams--where-each-roadmap-lives) for
the map and `selfhost/STAGE2-DESIGN.md` for the staged plan.

**Conventions.** Work is organized by numbered **Phases**; commit messages and
code comments reference them. Phases left *partial* keep their original number
(e.g. Phase 83/84, 101); genuinely new work gets the next free number (last used:
146). At task triage, match the work against AGENTS.md's task-playbook table and
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
| **Native backend (Stage 2)** | [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) §"Staged plan" + [`RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md) §7–8 | 🟡 in progress | Core IR + bytecode VM (§2.1–2.2) fully done incl. capstone; **LLVM de-risking spike COMPLETE** — full non-GC Core IR surface (126/126 plain + 16/16 typed gate), Boehm GC live, **entire native extern catalog ported** (slices 1–14 + RNG SplitMix64 + sorts →MEDAKA + hash→Hashable + **inspect→method**); value rep RATIFIED + dense i32 ctor-ordinal tags + nullary-immediate; next = **promote spike → real backend**: **typeclass dispatch in the backend** (DECIDED: runtime dict-passing; D0+D0.5 inventory DONE → re-scoped: 0 nested/0 CDict, return-pos done; remaining = **D3a** stamp ~903 concrete arg-position sites→RKey (✅ DONE 2026-06-07; emitter now static-dispatches concrete arg-position, incl. the 25 primitive heads) + **D3b** dict-pass 110 type-variable sites (**D3b-1** ✅ DONE 2026-06-07: the ~87 derived-impl element dispatches route through the `requires`-dict + emitter threads element-dict witnesses; **D3b-2** ✅ DONE 2026-06-07: the ~23 prelude `=>` helpers dict-pass their constraint var in arg position — reused D3b-1's `activeDictVars`/`resolveArgStamp` machinery unchanged, the delta was the `preludeArgPosDictNames` selector + 4 fixtures; **D3b COMPLETE** — on the emit path all arg-position dispatch is RKey/RDict, no arg-tag for primitives; deferred to D4: native EMISSION of the real prelude (emitter-completeness, slice-2) + the 1 `empty` return-position default body)) → **D4 dispatch corpus gate → bootstrap closure** → WasmGC sibling §2.4b. See [Native backend near-term sequence](#native-backend-stage-2--near-term-sequence) |
| **Capability-effects wedge (Phase 146)** | [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (lang) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product) | 🟡 in progress | gap-1 sound + gap-2 labels + wow-demo done; next = research pass, manifest format/emission, cross-module label export, Phase 146b |
| **Compiler / language correctness** | **this file** → [Compiler / language](#compiler--language) | 🟡 open items | Phase 101b (deferred) |
| **Standard library** | [`STDLIB.md`](./STDLIB.md) §"Remaining work" + §"Label refinement roadmap" | 🟡 modules done, extras open | `zip`/`unzip`, `Semigroup List`, JSON pretty/codecs, effect-label refinement |
| **CLI surface (Phase 82)** | **this file** → [CLI surface](#cli-surface-phase-82-continued) | 🟡 gaps | `medaka build` (needs design), `doc` multi-module, `--json` multi-file |

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

### Stage 0 — Prerequisites before self-hosting can begin — ✅ COMPLETE

All Stage-0 prerequisites are met (details in PLAN-ARCHIVE.md):

- **Standard library breadth** — `Map`/`Set` (ordered) + `HashMap`/`HashSet`
  (mutable) + `mut_array`, `io`, and a finalized importable `string` are all done.
- **Language stability** — `do`→`Thenable`, guard exhaustiveness, plain
  multi-clause exhaustiveness, and the multi-module / return-position dispatch
  residuals are closed (only the nested/structured-dict residual #5 remains — see
  Phase 83/84 below; it does not block the port).
- **Interpreter performance** — "good enough to bootstrap" confirmed; the cost is
  typeclass dispatch + persistent-tree allocation, addressed opportunistically in
  the self-host perf work (`selfhost/PERF-NOTES.md`), not a blocker.
- **Multi-file ergonomics at scale** — scale-probed; cross-module user-defined
  interfaces (the one hard gap) closed by Phase 130.

### Stage 1 — Self-host on the interpreter — ✅ COMPLETE

Port the pipeline into Medaka, one stage at a time, checked against the OCaml
reference. The self-host tree lives in `selfhost/`, each stage validated against
the OCaml reference via a differential harness on the interpreter.

**All eight stages are ported and validated byte-for-byte** (full per-stage slice
logs in `selfhost/README.md`):

| Stage | Status | Validated against |
|-------|--------|-------------------|
| lexer (Phase 132) | ✅ | 17/17 fixtures + all 13 real `.mdk` files |
| parser (Phase 135) | ✅ | stdlib + `parse_fixtures` + `diff_fixtures` + self-source |
| desugar | ✅ | `astdump --desugar`, 95/95 corpus |
| resolve (single + multi-module) | ✅ | `diagdump --resolve[-modules]`, corpus + fixtures |
| method_marker | ✅ | `astdump --mark`, full corpus |
| exhaust (guard coverage) | ✅ | `diagdump --exhaust`, corpus + 5 fixtures |
| eval (untyped, typed/RKey, multi-module) | ✅ | `eval_probe` + all 16 `=== EVAL ===` goldens |
| typecheck | ✅ | `tc_probe` + all 16 `=== TYPES ===` goldens |

**Integration milestones beyond per-stage validation:**
- **Composed front-end** (`selfhost/check.mdk`) — parse → desugar → resolve →
  exhaust → typecheck in one program; reproduces all 16 TYPES goldens + the
  resolve diagnostics.
- **True execution** (`selfhost/eval_run_main.mdk`) — runs programs for stdout,
  matching all 16 `=== EVAL ===` goldens.
- **Typed eval path / return-position dispatch** (`selfhost/eval_typed_main.mdk`).

**The bootstrap closure** ("the compiler processes its own source"), validated by
`test/diff_selfhost_selfproc.sh`:
- ✅ **Leg A** — the self-hosted multi-module front-end typechecks all 12 selfhost
  modules of its own source and matches the OCaml reference.
- ✅ **Leg B** — the self-hosted eval engine executes a real selfhost stage (the
  lexer) identically to the `eval_modules` oracle.
- ✅ **Leg C** — the *typed* self-hosted eval executes a `Parser`-monad stage (the
  parser) identically to the oracle, via `typecheck.elaborateModules`.
- ✅ **Leg D** — the *typed* self-hosted eval executes the `typecheck.mdk` stage
  (also monadic → return-position dispatch) through `eval_typed_modules_main.mdk`,
  validated the same way Leg C validates the parser. See `selfhost/README.md`.

**Dictionary passing** for user `=>`-constrained functions is also ported
(`eval_dict_main.mdk` + `typecheck.elaborateDict`), including inferred/unsignatured
constraints and self/mutual recursion — beyond the RKey-only minimum the bootstrap
source needs (the selfhost source has no `=>`-constrained user polymorphism).

**Forward-looking performance levers** (backend-independent, cheap now / expensive
to retrofit — recorded so they aren't lost; not blocking):
- **Lexical addressing** — resolve emits a `(frame, slot)` address per variable
  reference to replace the assoc-list env scan. ✅ EMIT done + CONSUME
  **investigated and closed for the tree-walker**: `annotateProgram` (EMIT) is
  validated and consumed by the bytecode VM / Core IR (where it becomes O(1)
  compiled slot loads); the AST tree-walker CONSUME arm (`EVarAt`/`lookupAtAddr`)
  is correct (18/18 EVAL goldens byte-identical with it active, slot/name assert
  never fires) but **measured twice as a non-win** (list-indexed ~neutral-to-2.5%
  slower, array frames −14%) — the address resolution is itself interpreted, so it
  can't beat the by-name scan. Kept DORMANT by design; do not re-attempt on the
  tree-walker. See `selfhost/PERF-NOTES.md`.
- ✅ **Stdlib string builder** — killed the O(n²) `++` string-building in
  lexer/formatter via native `stringConcat` over cons-built lists (2026-06-05; see
  `selfhost/PERF-NOTES.md`).
- Larger levers (bytecode VM, decision-tree match compilation) are recorded as
  post-profiling work, and feed Stage 2.

### Stage 2 — LLVM backend (after self-host)

> **Backend-architecture decision (bytecode VM first vs. straight to LLVM):** see
> [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md). Recommends a Core IR
> + bytecode VM as a "Stage 1.5" on-ramp (conditionally), on differential-testing
> grounds — the bytecode VM is gated against the existing tree-walker oracle per
> slice, where LLVM-first is not. The staged plan there feeds the work items below.

With the language proven, build native codegen. The heavy, decision-dense work
deliberately deferred to here:

- **A frozen Core IR** as the codegen input: desugared, fully typed, effects
  erased, **dictionaries explicit**. The existing elaboration already inserts
  `EMethodRef`/`EDictApp` — this stage commits to it as a serializable lowering
  target. (Effects erase here; the capability *manifest* of Phase 146 is
  compile-time metadata, not runtime state — see [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md).
  A **WasmGC** backend, sibling to LLVM via the Core IR seam, is the natural target
  for the edge/capability wedge — and is reached by a *direct* emitter, not through
  LLVM, which targets only linear-memory Wasm.)
- **Typeclass lowering strategy:** runtime dictionary passing (already the eval
  model) vs. monomorphization.
- **Memory model & value representation:** heap allocation, closure layout,
  tagged ADTs/records, boxing/unboxing. **Proposal + recommendation now written:**
  [`selfhost/RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md) §8 recommends a
  uniform **tagged word** (OCaml-style, lossless for Medaka's 63-bit `Int`),
  rejects NaN-boxing (breaks conservative GC), and sketches the calling convention
  (commits to `musttail`). **Provisional, pending human ratification** — surfaced by
  the de-risking spike below, not yet locked.
- **Garbage collection:** conservative (Boehm) to start vs. reference counting
  vs. a precise collector.
- **Runtime library:** re-implement the `extern` catalog against the native
  runtime. Per-extern disposition for all 71 primitives + the language/ABI strategy
  is in [`selfhost/RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md).
- **LLVM lowering:** Core IR → LLVM IR, calling convention, FFI.
  - ✅ **Toolchain de-risking spike COMPLETE** (2026-06-07) — *ahead
    of the strict VM-first ordering by design* (front-loads the riskiest lift; uses
    only the tree-walker oracle). Proves the decided toolchain end-to-end (EMIT
    textual LLVM IR + shell out to `clang`; no llc/opt, no C++/Rust bindings):
    `selfhost/llvm_emit.mdk` + `llvm_emit_main.mdk` + `runtime/medaka_rt.c`
    (Boehm `GC_malloc` allocator since 2026-06-07; was a malloc-and-leak stub), gated by `test/diff_selfhost_llvm.sh`
    (emit → clang → link → run → diff vs `dev/eval_probe.exe`, **43/43
    byte-identical**). Slices cover scalars (1), top-level fns + `musttail`
    self-recursion (2), Bool/Float boundaries (2b), ADT ctors + decision-tree match
    (3), closures + HOFs via lambda-lifting (4), records/tuples/mutable refs (5a),
    built-in list/tuple match heads + recursive closures (5b), **typeclass dispatch
    (6)**, **arg-position dispatch (7)**, **arrays + ranges (8)**, **lists (9)**. Slice 6 (the largest remaining Core-IR gap, and the one the bootstrap
    needs — the self-host compiler dispatches return-position via `RKey`) lowers
    `CMethod`/`CDict`: an `RKey` route is statically resolved → a direct call to the
    impl's lifted `@mdk_impl_<tag>_<method>`; `RDict`/`RDictFwd` read a runtime dict
    witness word → an inline if-chain over the method's impls. Dispatch needs types,
    so it has its OWN typed driver (`llvm_emit_typed_main.mdk`, desugar →
    `elaborateDict` → lower → emit) and gate (`test/diff_selfhost_llvm_typed.sh`,
    oracle = the TYPED Core-IR tree-walker `core_ir_dict_pp_main.mdk` — `eval_probe`
    is untyped and leaks the dispatch wrapper) over `test/llvm_fixtures_typed/`
    (**3/3 byte-identical**: single-impl `RKey`, multi-impl `RKey` narrowed at two
    types, a `=>`-constrained fn through the dict at two types). Slice 7 (arg-position
    / arg-tag dispatch) found the symmetric occurrence does NOT lower to a `CMethod`:
    an arg-dispatched method stays a bare `CVar` (the marker rewrites only
    return-position) resolving to the coalesced VMulti, so the call site loads the
    discriminating arg's cell tag → a direct lone-impl call or a type if-chain over
    `ctorsOfType` (ADT-only), and multi-clause / pattern-param impl bodies coalesce
    into one lifted fn whose body is a decision tree built by the now-exported
    backend-neutral `compileTree`/`canonPat` (arity ≥2 tuple-wrapped to reuse
    `emitDecision`) — **typed gate now 6/6** (+ single-impl multi-clause, multi-impl at
    distinct ADTs, multi-clause wildcard fall-through). Slice 8 (arrays + ranges):
    `CArray` allocates a length-prefixed boxed cell (raw_len at header position;
    elements at offsets 8*(i+1)); `CIndex` bounds-checks via `@mdk_oob()`; `CRangeArray`
    and `CSlice` emit alloca-counter loops (the spike's first non-recursion loop; no phi
    nodes). 4 new fixtures (arr_index, arr_range_sum, arr_slice, arr_range_excl). Slice 9
    (lists): `CList` inline right-folds into Cons/Nil heap cells via `emitCtorAlloc`
    (cell hashes match slice-5b's `HCons`/`HNil` match heads); `CRangeList` reuses the
    alloca-counter back-to-front loop (high-to-low index → ascending order, no reverse
    pass). 4 new fixtures (list_lit, list_range_incl, list_range_excl, list_range_combo).
    **Not** the real backend (arg-tag dispatch on non-ADT args, nested requires dicts,
    `HUnit` heads, guarded/range/record arms,
    ~~non-empty `PList` binding~~ [✅ E6], partial application, Ref capture still panic). Full
    per-slice log + the spike-surfaced representation notes (a)–(t) — nullary
    boxing, i64 hash-tag vs i32 ordinal, closure header, saturated-only calling,
    eta-wrapping, positional records, tuple headers, the `set_ref` write-barrier gap,
    the slice-6 dict-witness / impl-fn / dispatch-chain notes (j)–(m), the slice-7
    arg-tag call-site / impl-coalescing / bool-ctor notes (n)–(p), the slice-8
    array-cell / bounds-check / range-loop / slice-loop notes (q)–(t), and the slice-9
    list inline-fold / range-list back-to-front notes (u)–(v) — live in
    [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) §2.4/§2.4a
    (the spike's owning doc; rep decisions belong to the real backend).
- ✅ **§2.1 — Core IR + evaluator DONE (2026-06-05).** `selfhost/core_ir.mdk`,
  `core_ir_lower.mdk`, `core_ir_eval.mdk` (+ sexp/round-trip gates). 47/47
  fixtures byte-identical across 6 corpora. See `selfhost/README.md`.
- ✅ **§2.2 — Bytecode VM (all 6 slices + capstone) DONE (2026-06-06).** `selfhost/bytecode.mdk`
  (compiler + stack VM) + single-file driver + multi-module driver. 22/22 fixtures
  (18 single-file slices 1–5 + 4 multi-module slice 6). Capstone: lexer selfproc
  probe runs byte-for-byte through the bytecode multi-module VM
  (`test/diff_selfhost_bytecode_selfproc.sh`, 1 real pass + 2 documented
  expected-gaps for parse/tc probes that need return-pos dispatch — closed by §2.3).
  Zero `eval.mdk` changes — full Axis-2 reuse. See `selfhost/README.md`.
- **§2.3 — Close front-end gaps the VM surfaces.** Three concrete items; see
  `selfhost/STAGE2-DESIGN.md` §2.3 for detail:
  - ✅ **DONE (2026-06-06) — Typed multi-module bytecode VM path** (`eval_bytecode_typed_modules_main.mdk`)
    — `elaborateModules` (route-stamping) + `annotateProgram` per module +
    `bcEvalModulesOutput`; all three selfproc probes (lex/parse/tc) pass through
    the typed VM (`test/diff_selfhost_bytecode_selfproc.sh` §2.3 section, 3/3).
    Also closed `EVariantUpdate` → `CVariantUpdate` Core IR gap (named-field
    constructor updates in `typecheck.mdk`'s `DImpl`/`DInterface` clauses).
  - ✅ **DONE (2026-06-06) — Dict-passing corpus through typed bytecode VM**
    (`eval_bytecode_typed_dict_main.mdk`) — `elaborateDict` + `lowerProgram` +
    `bcEvalOutput`; all 17 `test/eval_dict_fixtures/` pass byte-for-byte
    (`test/diff_selfhost_bytecode_eval_dict.sh`, 17/17). Also fixed the Core IR
    `CMethod` lowering gap: `EMethodAt`'s `implRef`/`methodRef` were dropped; now
    `CMethod String Route (List Route) (List Route)` carries all three dispatch
    components (topRoute + implRoutes + methRoutes), mirroring the tree-walker's
    `methodAtNarrow + applyDicts + applyValues(fwdReqs)` chain.
  - ✅ **DONE (2026-06-07) — Erased effect-polymorphism in Core IR.** Frozen-IR
    contract: **full erasure, no runtime representation** (the opposite of
    typeclass polymorphism). Effects are type-level only (`TyEffect`/`EffRow`),
    no runtime construct (no perform/handle/resume), dispatch is type-head not
    effect directed — so they erase WITH types at lowering and an
    effect-polymorphic fn is represented identically to a monomorphic one (no
    effect node/param/dispatch). Documented in the `core_ir.mdk` header; gate
    `test/eval_fixtures/effect_poly.mdk` (a `<e>`-polymorphic combinator at
    `<Mut>` + pure rows) byte-identical across tree-walker / Core IR / bytecode
    VM (19/19 in `diff_selfhost_eval.sh` / `_core_ir.sh` / `_eval_bytecode.sh`).
- **Bootstrap closure:** self-hosted compiler + LLVM backend compiles itself to a
  standalone native binary — the finish line.

> **Targets & the WASM soft-pivot (decided 2026-06-06).** Medaka is **one language,
> one core, identical semantics**, parameterized by **target = (capability set) ×
> (backend)** — NOT Roc-style platforms, NOT forked variants. "General-purpose" =
> all capabilities + LLVM-native; "WASM-edge" = host-granted subset + WasmGC. The
> stdlib stratifies into a **pure core** + **effect-labeled capability modules**
> (start now; see STDLIB.md). **WasmGC is a planned second backend** (the wedge's
> delivery vehicle, via a *direct* emitter — LLVM only does linear-memory Wasm).
> **Soft pivot:** keep LLVM first, but make WASM's constraints design inputs to the
> shared layers *now* — value representation to the WasmGC intersection (no
> pointer-tagging; `i31ref`; `Int` 64-bit logically — `RUNTIME-DESIGN.md` §7.1),
> capability surface parameterized (`RUNTIME-DESIGN.md` §6a), guaranteed TCO assumed
> uniformly. **Verified 2026-06-06:** WASM tail calls + WasmGC (Wasm 3.0) are
> supported on both V8/Cloudflare and Wasmtime/Fastly — `STAGE2-DESIGN.md` §2.4b.
> Full rationale: `selfhost/STAGE2-DESIGN.md` §2.4/§2.4b, `RUNTIME-DESIGN.md`
> §6a/§7.1.

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

### Native backend (Stage 2) — near-term sequence

**Owning roadmap:** [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md)
§"Staged plan" + [`RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md) §7–8.

**Done (foundation):** §2.0 observability (per-phase timing + allocation counter,
2026-06-05) ✅; §2.0 lexical-addressing — EMIT done, CONSUME closed as a
tree-walker non-win and already captured in the VM/Core IR (O(1) slots) ✅; §2.1
Core IR + evaluator + sexp round-trip ✅; §2.2 bytecode VM (6 slices + capstone) ✅;
§2.3 front-end gaps (typed multi-module VM, dict corpus, erased effect-poly) ✅;
§2.4 **LLVM de-risking spike COMPLETE** — the full non-GC Core IR surface
(scalars → fns → ADTs/match → closures → records/tuples/refs → return-position +
arg-tag dispatch → arrays/ranges → lists), Boehm GC, and the **entire native extern
catalog** (slices 1–14 + RNG/sorts/hash); 126/126 plain + 16/16 typed gate ✅.

**Near-term (remaining), dependency-ordered:**
1. ✅ **Value representation + calling convention RATIFIED (2026-06-07).** Native
   encoding = **Option A** (uniform tagged word, low-bit-1 immediate 63-bit `Int`),
   adopted *under §8.6's shared abstract value contract* so semantics are
   WasmGC-compatible by construction. Constructor tag = **dense i32 ctor-ordinal per
   type** (not the spike's i64 hash — `br_table`-ready, kills the hash-collision
   miscompile class; the separate `decodeHead` reserved-name aliasing bug is now
   fixed — see Compiler / language); **uniform
   one-word heap header** kept; `Float` boxed-first; scalars not self-describing
   (compile-time `Debug`). Record: [`RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md)
   §8 status banner + §8.4. This unblocks item 2.
2. **Promote the spike to the real LLVM backend** (§2.4). The de-risking spike has
   now closed every lift it was scoped to prove — what remains is turning that probe
   into the production backend that compiles the real self-hosted compiler.
   **DONE (all 2026-06-07):**
   - **GC** — `mdk_alloc` routes to Boehm `GC_malloc` (conservative). Verified active
     (not a malloc fallback): a 2×10⁸-cons churn fixture (`gc_stress.mdk`) holds ~3 MB
     RSS vs ~614 MB malloc-and-leak. Gate clang lines locate libgc via pkg-config /
     `brew --prefix bdw-gc` and skip cleanly (exit 2) when absent.
   - **Dense i32 ctor-ordinal tags** — the spike stamps the ratified per-type ordinal
     (composite `typeId<<32 | ordinal`); hashName gone from every ctor tag, killing the
     hash-collision miscompile class. **Nullary ctors immediate** (`(cellTag<<1)|1`, no
     alloc); a `match` reads the tag via `loadDiscriminant` (low-bit branch). The spike's
     value-rep no longer differs from the ratified scheme.
   - **Native extern catalog — FULLY PORTED** (slices 1–14, slice breakdown below):
     Tier A (numeric/IO/abort/string-leaf/array-intrinsics/array-leaf), Tier B (Char rep
     lock, string↔char, unicode), Tier C (reserved ADT-tag precursor + ADT-returning
     string externs + args/env + file IO), Tier D (**RNG** = deterministic SplitMix64
     shared oracle+runtime; **sorts** = `arraySortBy`/`arraySortInPlaceBy`/`arrayMakeWith`
     rewritten as pure-Medaka stdlib `→MEDAKA`; **`hash`→`Hashable`** typeclass `→METHOD`
     replacing the structural extern). All byte-identical vs the tree-walker oracle.
   **REMAINING (the spike→real-backend gap):**
   - ~~`inspect : a -> <IO> Unit` → `→METHOD`~~ **DONE 2026-06-07**: `inspect x = putStrLn (debug x)` in `stdlib/io.mdk`; reflective extern gone.
   - ~~**Finish the `→MEDAKA` sort/builder cutover.**~~ **DONE 2026-06-07** — `arrayMakeWith`
     emitted as an inline INTRINSIC in `selfhost/llvm_emit.mdk` (`emitArrayMakeWith`):
     alloca-counter loop calls the Medaka closure directly, no FFI. `array.mdk` unchanged.
     Dead `arraySortBy`/`arraySortInPlaceBy` externs remain in interpreter (harmless).
   - **Typeclass dispatch in the backend (the bootstrap-critical lift).** Both spike
     "dispatch gaps" — arg-tag dispatch on non-ADT/Int args, and nested-`requires` dicts —
     share one root: the emitter lags the typed pipeline + interpreter, which already
     resolve dispatch via (possibly nested) dict routes. The spike's runtime arg-tag
     dispatch (`emitMethodArgDispatch`) is a shortcut that **cannot** discriminate
     primitive types (`Int`/`Bool`/`Char` immediates carry no type tag), and it panics on
     nested dicts. The real compiler does `eq`/`compare`/`show` over `Int`/`String`
     everywhere, so this blocks bootstrap.
     **STRATEGY DECIDED 2026-06-07: runtime dict-passing** (mirror the interpreter —
     dict cells + dict params + nested dicts; the emitter becomes a *port* of validated
     `eval.mdk` machinery, and the Core IR is already dict-explicit). **Monomorphization
     is deferred** as a later optimization pass (Medaka can support it — no polymorphic
     recursion / higher-rank / existentials — but it breaks across the wedge's
     separate-compilation/dynamic-plugin boundary, so dict-passing is the correct
     baseline; specialize statically-known sites later if perf needs it). Full analysis:
     [`project_backend_dispatch_strategy`] memory + STAGE2-DESIGN §2.4c. **Staging
     RE-SCOPED 2026-06-07 by the D0+D0.5 inventory (`selfhost/DISPATCH-INVENTORY.md`)** —
     the real compiler has **0 nested dicts, 0 CDict sites, 0 first-class method values**;
     return-position dispatch is done (only 1 RNone `empty` panics). The whole remaining
     gap is **1013 directly-applied arg-position method occurrences**, splitting **903
     concrete (~89% → static RKey marking; incl. the only 25 sites the emitter can't do
     today: `display@String`×19, `compare@Int/String/Float`×6) + 110 type-variable (~11% →
     dict-passing, localized to 5 derived-impl bodies + ~18 prelude helpers)**:
     - ✅ **D0 — route-coverage inventory.** DONE (`dispatch_inventory_main.mdk`).
     - ✅ **D0.5 — arg-position classification.** DONE (`dispatch_argclass_main.mdk`).
     - **D1/D2 (nested-dict cells, CDict params) — DROPPED for bootstrap.** Inventory
       shows 0 nesting / 0 CDict; defer this machinery until a non-bootstrap program needs
       it.
     - ✅ **D3a — stamp concrete arg-position sites → RKey.** DONE (2026-06-07). The ~903
       concrete arg-position sites (25 primitive + 878 ADT) are stamped static `RKey` on the
       LLVM emit path, behind `argStampEnabled` (off for every golden/oracle driver, so all
       goldens stay byte-identical). `typecheck.mdk`: `prePassDictArg` (arg-position `EVar`→
       `EMethodAt`), `inferMethodAt`→`recordArgStamp` (keyed on the discriminating-arg mono),
       `resolveArgStamps` (concrete→`RKey`, type-var→`RNone`), `inferPlainImpl` (infer
       NON-`requires` impl bodies on the emit path so the `display@String` impl-body sites are
       reached). **Emitter now does static dispatch for concrete arg-position** — its existing
       `RKey` path already emitted primitive impl fns (`@mdk_impl_Int_compare`,
       `@mdk_impl_String_display`); the only emitter change is `emitMethod`'s `RNone` arm →
       arg-tag fallback (was panic) so the 110 type-variable sites keep working until D3b. New
       fixtures `disp_arg_prim_{compare,display}` (panic pre-D3a, pass after); existing ADT
       arg fixtures now lower to static `RKey`. `emitMethodArgDispatch` retained (D3b).
     - **D3b — dict-passing for the 110 type-variable sites.** Extend the Phase-83/84
       `requires`-dict from return- to **arg**-position element dispatch.
       - ✅ **D3b-1 — the ~87 derived-impl element dispatches.** DONE (2026-06-07). The
         arg-position element sites inside parametric `requires` impl bodies
         (`Eq/Ord/Debug/Display/Hashable (List a)`-style, dispatching the element method on the
         impl's element tyvar `a`) now route through the impl's `requires`-dict instead of
         `RNone`→arg-tag — which arg-tag cannot do for a primitive element. `typecheck.mdk`:
         `registerImplRequires` now registers the element dict var for arg-position methods too
         (gated `argStampEnabled`, via `registersElementDict`); `resolveArgStamp` routes an
         arg site whose discriminating mono is that registered element tyvar to `RDict
         $dict_<method>_<slot>`, a concrete head to `RKey` (filling the impl-dicts ref via the
         new `argImplDictRoutesFor` so the outer/recursive `List` call threads the element
         dict — concrete element→`RKey Int`, recursive element→`RDict` forward); `dictPass`'s
         `implDictPassMethods` prepends the leading `$dict_<method>_<slot>` param UNIFORMLY
         across all clauses of a dict-using method (was return-position-only, per-clause). All
         emit-path-gated, so goldens stay byte-identical. **Emitter** (`llvm_emit.mdk`):
         `emitMethod`'s `RKey` arm materializes `methRoutes ++ implRoutes` as leading dict
         witnesses (`dictWordsOf`) and prepends them (removed the `ensureNoMethodDicts` panic);
         the arg-position `RDict` element site reuses the existing `emitMethodDispatch`
         dict-read. New fixtures `disp_req_{eq,compare}_list_int` (`eq`/`compare` on `MyList
         Int` via `requires`; PANICKED pre-D3b-1, pass after).
       - **D3b-2 — the remaining ~23 prelude `=>` generic helpers** (`neq`/`clamp`/
         `debugListItems`/`elem`/`sum`/`any`/…). ✅ DONE (2026-06-07). Same `=>`-dict-passing
         layer the typed pipeline already builds for return-position (`when`/`unless`), applied
         to arg-position method bodies — and it needed NO new typecheck/emitter code: D3b-1's
         `activeDictVars`/`resolveArgStamp` already routes an arg-position method at a fn's `=>`
         constraint var to `RDict $dict_<fn>_<slot>`, and `constrainedSigNames` already
         dict-passes the call sites (concrete→`RKey` witness, polymorphic→forwarded dict). The
         delta was the `preludeArgPosDictNames` selector (arg-position analogue of
         `preludeReturnPosDictNames`, wired into the emit + dict_pp-oracle drivers only — no
         golden driver shares them) + 4 prelude-free fixtures, one per shape:
         `disp_constr_elem_int` (Eq element), `disp_constr_pick_int` (Ord element),
         `disp_constr_fold_int` (Foldable container `fold` on `t`), `disp_constr_forward_int`
         (dict forwarding through a `=>`-helper chain). All pass emit→clang→run == ceval at a
         PRIMITIVE element. **D3b COMPLETE** — on the emit path all arg-position dispatch is
         `RKey`/`RDict`, no arg-tag for primitives.
     - **The 1 RNone `empty` — deferred to D4** (NOT closed by D3a/D3b-1/D3b-2):
       `foldMap`'s default-body seed stays `RNone` because the `elaborateModules` bootstrap path
       never infers interface default bodies (`implInferEnabled=False`, the gate that keeps
       module goldens identical). It is a RETURN-position default body needing separate
       default-body-inference plumbing, not covered by D3b-2's constraint-dict *arg* routing. Not
       on the LLVM fixture path; the `RNone`→arg-tag fallback means it no longer panics the
       emitter. `emitMethodArgDispatch` is retained until then.
     - **D4 — dispatch corpus gate** over the real compiler's dispatch-heavy modules →
       bridge to bootstrap. Includes native EMISSION of the real prelude helpers (D3b-2 proved
       their *routing*; emitting `core.mdk` whole is blocked only by orthogonal
       emitter-completeness — multi-clause / point-free / operator-section top-level fns).
     - **(deferred) D5 — specialization/monomorphization** optimization; reach for it only
       if profiling demands it (it would collapse the 110 to concrete RKey per instance).
   - **Emitter completeness (E-series) — close the construct-shape gaps so the emitter can
     LOWER real modules** (orthogonal to dispatch, which is done). Inventory +
     staging: [`selfhost/EMITTER-GAPS.md`](./selfhost/EMITTER-GAPS.md). Milestone =
     fully emit `stdlib/core.mdk` (core.mdk-first).
     - ✅ **E1a — multi-clause + patterned top-level fns.** DONE (2026-06-07). Routed
       ordinary multi-clause fn-binds (and single-clause fns with non-variable params)
       through the SAME clause-coalescing + decision-tree lowering the impl methods use
       (`emitMultiClauseFn` → shared `emitClauseTree`, factored out of `emitGroupBody`);
       extended signature inference to multi-clause bindings (`inferMultiSig`) so the
       synthetic scrutinee params are typed from the fn's sig (`implParamEnvTyped`) and
       `fnRetTy` reports the right result type for `main`'s print selection. **Closes
       EMITTER-GAPS #1** (multi-clause top-level fn: core 16→0, whole 732→0) **and the
       fn half of #4** (non-variable parameter pattern, fn: core 4→0, whole 150→0; the
       lambda half #5 stays for E2). core.mdk gap total 57→44 (the multi-clause wall no
       longer masks the downstream value-shape gaps in the now-reachable bodies). New
       fixtures `fn_multiclause_{ctor,list,float}` + `fn_nonvar_param`; all four gates
       byte-identical (133/25/20/20).
     - ✅ **Bool `match` switch-head miscompile — FIXED (2026-06-07).** `cellTag` was
       not special-cased for `True`/`False`: both returned tag 0 (not in ctor table on
       prelude-free path), causing both arms to `icmp eq …, 0` → `True` never matched
       → `unreachable`. Fix: `cellTag` now special-cases `True`→1 and `False`→0 before
       the ctor-table lookup, mirroring `emitVar`/`emitLit` (word 3→tag 1, word 1→tag 0
       after `loadDiscriminant` ashr 1). New fixtures `match_bool_true` (→7),
       `match_bool_false` (→9), `match_bool_fn` (→300); all four gates byte-identical
       (136/25/20/20). Float literal switch heads (1 whole-compiler site, rare) remain
       documented as deferred in EMITTER-GAPS #14.
     - ✅ **E1b — top-level value / mutable `Ref` globals** (#7). DONE (2026-06-08).
       Each top-level non-`main` non-fn binding emits as an LLVM global
       `@mdk_g_<name> = global i64 0` (`emitGlobalDecls`); an `@main` **init prologue**
       (`emitTopGlobals`) computes each rhs in **source order** and `store`s the word,
       then `emitVar`/`lookupVarG` lowers any reference to `load i64, ptr @mdk_g_<name>`
       — referenceable from ANY `define`. A `Ref v` global holds the heap-cell POINTER,
       so `.value`/`set_ref` deref through it (mutation shared across calls). A new
       `Emit` globals registry (10th ref, `name -> (initialised?, LTy)`) carries each
       binding's resolved LTy; `@main` is emitted BEFORE the fn defines so the prologue
       resolves every LTy first, and a forward/mutual init dependency records a precise
       `gapE` rather than loading an uninitialised 0. **core #7 stays 0** (no genuine
       value globals — its residual unbound-vars are pattern-cascade); **whole genuine
       value-global refs 781→146 unbound events, whole TOTAL 2660→2025.** 3 new fixtures
       (`global_value_ref` / `global_ref_mut` / `global_chain`); all gates byte-identical
       (156/25/20/20). **Single-program milestone**; multi-module cross-module init order
       deferred to D4 (census B flattens all modules to one program → measures this
       capability).
     - ✅ **E2a — `::` and `++` as `CBinPrim`** (#3/#6). DONE (2026-06-07). `emitBin` now
       handles `"::"` (→ `emitCtorAlloc e "Cons" [lw, rw]`, `typeOf` extended → `LTCon`) and
       `"++"` (→ `mdk_string_append` for `LTStr`, `mdk_list_append` for `LTCon`). Two new C
       helpers (`mdk_string_append` / `mdk_list_append`), declared in `emitPreamble`; 4 new
       fixtures. **`::` A:2→0; `++` A:14→4** (4 remaining = `append`/`ap` impls with both
       params unknown type; `paramUseTy` falls back to `LTInt`). core total: 44→**32**. All
       gates byte-identical (140/25/20/20).
     - ✅ **E2b — non-variable lambda parameter patterns** (#5). DONE (2026-06-08).
       `emitLam`/`emitRecLam` route a non-`allPVar` `CLam` (and recursive-`let`-`CLam`)
       to `emitPatLamDefine`, which runs the shared `emitClauseTree` decision tree over
       the `%argK` params *inside the lifted-lambda frame* (after `%clos`/capture binding;
       the recursive case prepends `f -> %clos`). Realised emitter-side — no Core IR
       rewrite, goldens unchanged. **#5 core 1→0, whole 185→0** (the fn half #4 closed in
       E1a). core total: 32→**31**. 3 new fixtures (`lam_tuple_param`, `lam_ctor_param`,
       `lam_rec_tuple`); all gates byte-identical (143/25/20/20).
     - ✅ **E2c — static impl-param typing** (`++` param-type residue). DONE (2026-06-08).
       `emitGroup` now extracts `positions` from `ImplGroup` and passes `tag`+`positions`
       into `emitGroupBody`.  For single-clause all-`PVar` impl methods, a new fast path
       (`paramEnvByPos`) binds the actual param names directly to `%argK` at `tagToLTy
       tag`-derived types (receiver positions → `LTStr`/`LTCon`/etc., non-receiver → `LTInt`),
       bypassing the `emitClauseTree` tuple-scrutinee indirection that caused `paramUseTy`
       to fall back to `LTInt`. For non-all-PVar / multi-clause clauses the general
       `emitClauseTree` path runs unchanged but with `implParamEnvByPos` providing the
       typed synthetic `aK` env.  Adds: `tagToLTy`, `implParamEnvByPos`, `listContains`,
       `patPosTys`, `paramEnvByPos`.  **`++` A:4→2** (`append@List`/`append@String` fixed;
       `ap@List`/`andThen@List` remain — `++` is on fn-call RESULTS `map f xs`/`f x`, not
       direct params). **B: 1927→1925**.  New typed fixtures: `impl_append_str` (→6),
       `impl_append_list` (→10); all gates byte-identical (160/27/20/20). core total: 17→**15**.
     - ✅ **E3 — guard residue** (#8 `otherwise`, #9 `__fallthrough__`). DONE (2026-06-08).
       `otherwise` in condition position is a `CVar` reaching `emitVar`; added as a constant
       arm → `("3", LTBool)` (same as `True`). `__fallthrough__` is always `CApp (CVar
       "__fallthrough__") (LUnit)`; intercepted in `emitApp`'s `CVar fname _` branch before
       `emitIndirect` → `call void @mdk_oob()` + dummy `("0", LTInt)` (the block's real
       terminator comes from the surrounding `if`'s `br`; dead but valid IR). **#8 B:88→0,
       #9 B:88→0**; core (A) was already 0 before E5 but the E5 let-group workers exposed
       guard residue — now gone. core total: 34→**30**. 2 new fixtures (`guard_otherwise`,
       `guard_chain`); all gates byte-identical (149/25/20/20).
     - ✅ **E5 (#10) — local function bindings in `let`/`where` groups.** DONE
       (2026-06-08). `emitLetGroup` now lambda-lifts a non-nullary / recursive local
       binding (`CBind name clauses` with params) into a closure via `emitGroupBind`:
       self-recursion threads through `%clos` (reusing `emitRecLam`'s mechanism), and
       multi-clause / patterned-param workers reuse the E1a `emitClauseTree` decision
       tree. Bindings emit one-at-a-time with growing env, so a binding capturing an
       EARLIER sibling (value or closure) works; a genuine forward/mutual reference to a
       LATER sibling is a precise `gapE` (none occurs in core.mdk). **#10 core 5→0,
       whole 5→0** — closes the structural `let`/`where`-group gap that `find`/`count`/
       `maximum`/`arbitraryList` hit. Net core gap total *rose* 31→34 because the
       now-emittable workers expose their own guard residue (#8/#9, #4) the old
       early-skip hid — honest progress, all revealed reasons pre-existing. 4 new
       fixtures (`let_local_fn`, `let_local_rec`, `where_local_rec`, `where_sibling_ref`);
       all gates byte-identical (147/25/20/20). NB: multi-arg `let f a b = …` lowers to
       *curried* nested `CLam` (arity-1 closures) and over-applies the saturated-call
       machinery — a pre-existing slice-4 limit, distinct from the where/group form which
       keeps arity-N in one clause; `let_local_rec` uses arity-1 recursion to stay green.
     - ✅ **E6 (#7-core) — per-type Hashable hashers + debug-lit externs.** DONE
       (2026-06-08). Closes core's last extern-catalog gap (the 7 `#7` core events =
       `__hashRaw`×5 + `debugStringLit` + `debugCharLit`). Replaced the structural
       `__hashRaw` (`Hashtbl.hash`, uncomputable by the type-erased native runtime) with
       five SPECIFIED deterministic per-type hashers called from the primitive `Hashable`
       impls: `hashInt`/`hashChar`/`hashFloat` = a SplitMix64-finalizer mix, `hashString`
       = FNV-1a over the UTF-8 bytes, `hashBool` = 0/1 — all masked to `[0, 2^30)`
       (non-negative) and byte-identical in `lib/eval.ml` (oracle) and
       `runtime/medaka_rt.c` (`mdk_hash_*`), the RNG SplitMix64 playbook applied to
       hashing (a deliberate oracle-editing semantics change → content-hashing now works
       for String/Float keys natively). `debugStringLit`/`debugCharLit` gained
       `mdk_debug_string_lit`/`mdk_debug_char_lit` (mirroring `escape_string_lit`/
       `escape_char_lit`). All seven wired into `llvm_emit.mdk`'s extern catalog (new
       `isHashExtern`/`emitHashExtern`, `isDebugLitExtern`/`emitDebugLitExtern`) +
       `emitPreamble` declares. **#7 core 7→0, total A 30→23; whole 2677→2660.** 4 new
       fixtures (`hash_int`, `hash_string`, `debug_strlit`, `debug_charlit`); all gates
       byte-identical (153/25/20/20). hash_map/hash_set doctests are order-insensitive →
       no golden churn.
     - ✅ **E6 (PAs/PList #4 residue) — as-pattern and list-literal pattern variable binding.** DONE
       (2026-06-08). `canonPat` shape was already correct (transparent `PAs _ p` and
       `PList (h::r) → PCon consName [h, PList r]`); the gap was in `bindPattern`'s
       variable-extraction, which fell to the catch-all gap on `PAs x p` and non-empty
       `PList`. Two new arms added before the catch-all: `PAs x p` binds `x` to the
       whole value `v` (same `paramUseTy`/`LTInt`-default as `PVar`) then recurses into
       `p`; `PList (p::ps)` delegates to `bindFields [p, PList ps] v body 0`, which loads
       head (field 0) for `p` and tail (field 1) for the recursive `PList ps`, bottoming
       out at the existing `PList [] → env` arm. **#4 residue core 4→0; core TOTAL
       23→17; B TOTAL 2025→1927.** 4 new fixtures (`pat_aspattern` →34,
       `pat_aspattern_use` →10, `pat_list_literal` →6, `pat_list_nested` →1020); all
       gates byte-identical (160/25/20/20).
     - **E4 — dispatch-routing port** (#2/#13: carry D3b arg-position dict-passing onto
       the `elaborateModules` emit path; 0 on the single-file path already).
   - **Drive the emitter over the REAL self-hosted compiler source** (not just fixtures)
     — the spike gates against `test/llvm_fixtures/`; the real backend must compile
     `selfhost/*.mdk`. Surfacing+closing whatever constructs that exposes is the bulk of
     the remaining work and feeds directly into item 3.
   Skill: none specific (lands in `selfhost/llvm_emit*.mdk` + `runtime/`). Gate: native
   stdout vs the tree-walker **and** the bytecode VM (the second, single-steppable oracle).
3. **Bootstrap closure** — self-hosted compiler + LLVM backend compiles itself to a
   standalone native binary (the finish line, STAGE2-DESIGN §2.4).

Downstream (captured, NOT near-term): the **WasmGC sibling backend** (§2.4b — the
capability-wedge delivery vehicle, reached by a direct emitter; soft-pivot
constraints are already design inputs to the shared layers).

#### Native extern catalog — slice breakdown (Stage 2.4, item 2)

> **✅ COMPLETE (2026-06-07).** All slices 1–14 (Tiers A–C) plus Tier D (RNG, sorts,
> hash) are landed and byte-identical-gated. The breakdown below is kept as the
> implementation record. Remaining catalog item: `inspect` → `→METHOD` (see item 2).

The catalog re-implementation (item 2 above) is decomposed into the small, ordered
slices below. **Each slice follows the String-slice template verbatim**
(STAGE2-DESIGN §2.4a-7 / commit `797bd32`): add a C helper to `runtime/medaka_rt.c`,
intercept the extern in `selfhost/llvm_emit.mdk` (`emitApp`'s `CVar` arm for a
LEAF/IO call, or an inline emit for an INTRINSIC), add fixtures to
`test/llvm_fixtures/` (+ `_typed/` if dispatch-relevant), and gate **byte-identical
vs the tree-walker oracle** (`test/diff_selfhost_llvm{,_typed}.sh`). The value/String
reps are LOCKED, so **no design work** is required in the mechanical slices — they
are sized for a **Sonnet agent**. Verify each extern's oracle rendering empirically
(`dev/eval_probe.exe`) before chasing the emitter, exactly as the String slice did.
Two structural facts set the slice order (both verified 2026-06-07): a C extern can
**read** a built-in `List` tag-free (Nil = odd immediate, Cons = even pointer) but
**cannot construct** an ADT cell — `Cons`/`Nil`/`Some`/`Ok` tags are *program-
dependent* (`cellTag` keys off the program's type count), so every ADT-**returning**
extern is gated behind the reserved-tag precursor (slice 10); and `Char`'s rep is now
locked (slice 8 DONE), unblocking the char/unicode slices 9 + 14.

**Tier A — mechanical, no precursor (Sonnet-ideal):**

| Slice | Externs | Disposition | Notes |
|---|---|---|---|
| ✅ 2 — numeric | `intToFloat` `floatToInt` `floatToString` `pi` `e` `intMinBound` `intMaxBound` | INTRINSIC + 1 LEAF | **DONE 2026-06-07.** conversions are inline `sitofp`/`fptosi`; constants inline; `floatToString` is a C helper that mirrors `mdk_print_float`'s `%.12g`+dot logic, boxed via `mdk_str_lit`. No ADT, no Char. 58/58 plain + 9/9 typed fixtures byte-identical. |
| ✅ 3 — IO output | `putStr` `putStrLn` `ePutStr` `ePutStrLn` | IO | **DONE 2026-06-07.** `LTUnit` added to LTy; `emitPrint LTUnit` → `mdk_print_unit()` → `"()\n"`. C helpers (`mdk_putstr/ln`, `mdk_eputstr/ln`) use a shared `mdk_fwrite_str` that reads the string cell and writes to stdout/stderr. stderr is dropped by the gate's `2>/dev/null` — `ePutStr*` fixtures prove compile+link+run. Typed gate uses `ePutStrLn` fixture (stderr-only side effect) so oracle and native both produce `"()"`. 61/61 plain + 10/10 typed fixtures byte-identical. |
| ✅ 4 — abort | `panic` `exit` | GC/CTRL | **DONE 2026-06-07.** `mdk_panic` writes string to stderr via `mdk_fwrite_str` then `exit(1)`; `mdk_exit` untags the Int and calls `exit(n)`. Both declared `noreturn` in C. Emitter intercepts `isAbortExtern`/`emitAbortExtern` in `emitApp`; returns `("1", LTUnit)` so the downstream `emitPrint LTUnit` is dead code. Empty-stdout fixtures prove compile+link+terminate; after-output fixture proves ordering. 65/65 plain fixtures byte-identical. |
| ✅ 5 — string leaf (non-ADT) | `stringLength` `stringConcat` | INTRINSIC + LEAF | **DONE 2026-06-07.** `stringLength` loads `cp_count` (offset 16) and tags it (INTRINSIC: inttoptr + GEP + load); `stringConcat` walks a built-in `List String` by low-bit (Nil = odd immediate, Cons = even ptr), sums `byte_len`s, one `mdk_alloc` + blit, boxed via `mdk_str_lit`. 71/71 plain + 11/11 typed fixtures byte-identical. |
| ✅ 6 — array intrinsics | `arrayLength` `arrayGetUnsafe` `arraySetUnsafe` | INTRINSIC | **DONE 2026-06-07.** pure-inline: no C helper. `arrayLength` = `loadTag` + `tagInt`; `arrayGetUnsafe` = `untagInt` + `loadFieldDyn`; `arraySetUnsafe` = `untagInt` + `storeFieldDyn` (new helper mirroring `loadFieldDyn` with a store). All three intercepted via `isArrIntrinsic`/`emitArrIntrinsic` in `emitApp`'s `CVar` arm. 75/75 plain + 12/12 typed fixtures byte-identical; mutate-then-read fixture proves store visibility. |
| ✅ 7 — array leaf | `arrayMake` `arrayCopy` `arrayBlit` `arrayFill` `arrayFromList` | LEAF | **DONE 2026-06-07.** array cells carry no program-specific tag (header = raw length), so construction is tag-free; `arrayFromList` reads a `List` structurally. `arrayBlit`/`arrayFill` are `<Mut>`. 80/80 plain + 13/13 typed fixtures byte-identical. **Tier A complete.** |
| ✅ 8 — Char rep + char scalars | `charCode` `charToStr` `charMinBound` `charMaxBound` | INTRINSIC + LEAF | **DONE 2026-06-07.** `Char` = immediate codepoint word `(cp << 1) | 1` (same encoding as `Int`). `LChar` lit emit: `charCode(arrayGetUnsafe 0 (stringToChars c)) * 2 + 1`. `charCode` is pure identity (re-type `LTChar → LTInt`, no instruction). `charToStr` → `mdk_char_to_str` (UTF-8-encode codepoint via `mdk_utf8_encode`, box via `mdk_str_lit`). `charMinBound = "1"`, `charMaxBound = "2228223"`. `LTChar` auto-print via `@mdk_print_char`. 86/86 plain + 14/14 typed fixtures byte-identical; unicode round-trip (`☕` = U+2615) verified. **Tier B slice 8 complete; unblocks slices 9 + 14.** |
| ✅ 9 — string↔char + codepoint slicing | `stringToChars` `stringFromChars` `stringSlice` | LEAF | **DONE 2026-06-07.** `stringToChars` → `mdk_string_to_chars` (walk UTF-8, emit Char immediates into raw-length Array); `stringFromChars` → `mdk_string_from_chars` (two-pass: sum UTF-8 widths → alloc → encode); `stringSlice` → `mdk_string_slice` (clamped codepoint indices via `mdk_utf8_byte_offset`). `mdk_utf8_decode` + `mdk_utf8_byte_offset` added to medaka_rt.c. Array result is LTCon (no auto-print). 91/91 plain + 15/15 typed byte-identical; unicode round-trip (`wörld`) + codepoint slice (`café` → `af`) verified. |

**Tier B — gated behind the Char-rep lock:**

- ✅ **Slice 9 — string↔char + codepoint slicing** (dep: 8, 6/7). **DONE 2026-06-07.** `stringToChars` → `mdk_string_to_chars` (walk UTF-8, emit one Char immediate per codepoint into a raw-length Array cell); `stringFromChars` → `mdk_string_from_chars` (two-pass: sum UTF-8 widths, alloc, encode each Char); `stringSlice` → `mdk_string_slice` (codepoint-indexed, CLAMPED: `mdk_utf8_byte_offset` converts lo/hi codepoint indices to byte offsets). `mdk_utf8_decode` added to medaka_rt.c alongside `mdk_utf8_byte_offset`. 91/91 plain + 15/15 typed fixtures byte-identical; unicode round-trip (`wörld`) and codepoint-indexed slice (`café` → `af`) verified.
- ✅ **Slice 14 — unicode (ASCII subset)** (dep: 8). **DONE 2026-06-07.** `charIsAlpha/Space/Upper/Lower/Punct`, `charToUpper/Lower`, `stringToUpper/Lower`. Nine C helpers in `medaka_rt.c`; `isUnicodeExtern`/`emitUnicodeExtern` added to `selfhost/llvm_emit.mdk` (predicates call C and tag raw 0/1 to Bool via `tagInt`; case-mappers return `LTChar`/`LTStr`). `charIsPunct` is a switch over Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII members — NOT `ispunct()` — so `+`/`$`/`=`/`^`/`` ` ``/`|`/`~` (Unicode symbols Sm/Sc/Sk) correctly return `False`. String case-map is byte-wise ASCII (bytes ≥ 0x80 pass through, so UTF-8 multi-byte codepoints are unchanged). 10 plain fixtures (including `uni_punct_sym.mdk` proving `charIsPunct '+' = False`) + 1 typed fixture; 101/101 plain + 16/16 typed byte-identical. Full-Unicode classification (a Rust `unicode-*` crate) deferred; see RUNTIME-DESIGN §6.

**Tier C — gated behind the reserved-ADT-tag precursor:**

- **Slice 10 — reserve fixed tags for the built-in ADTs (PRECURSOR).** **DONE
  2026-06-07.** `List`(Cons/Nil), `Option`(Some/None), `Result`(Ok/Err),
  `Ordering`(Lt/Eq/Gt) get a **fixed reserved tag block** at `reservedTypeBase`
  (65536, far above any real program's dense type-ids), shared by the emitter
  (`reservedTag` → `cellTag`) and the runtime (`MDK_TAG_*` in `runtime/medaka_rt.c`,
  same `(base+typeId)*2^32+ordinal` formula). Without it, a prelude-free fixture's
  untabled `Some`/`Cons` both collapse to the "one past" type-id ordinal 0 and
  collide. Runtime constructors added: `mdk_some`/`mdk_ok`/`mdk_err`/`mdk_cons`
  (boxed) + `mdk_none`/`mdk_nil`/`mdk_lt`/`mdk_eq`/`mdk_gt` (immediate). Canary:
  `charFromCode : Int -> Option Char` (`isAdtExtern`/`emitAdtExtern`) — `adt_some`
  (boxed `Some`, charCode 65) + `adt_none` (immediate `None`, surrogate 0xD800 → -1)
  prove both reps round-trip through `match`. 103/103 plain gate; core_ir/eval
  unaffected (existing list/option/ordering fixtures re-pass — alloc + match both
  reserve). No typed fixture: the typed gate loads only `runtime.mdk`, so the
  self-hosted typecheck has no `Option` ctor (scalar-only by design). KNOWN
  LIMITATION (per spec): a user type reusing a reserved ctor name aliases the
  reserved tag — internally consistent; the real backend resolves statically. Slices
  11/12/13 exercise the remaining constructors (`mdk_some`/`cons`/`ok`/`err`/…).
- **Slice 11 — ADT-returning string externs** (dep: 10). `stringToFloat` (Option),
  `stringIndexOf` (Option), `stringCompare` (Ordering). Fixtures must `match` the
  result down to a scalar/String (the emitter can't auto-print an ADT). *DONE.*
- **Slice 12 — args + env** (dep: 10). `args` (List String — needs Cons construction),
  `getEnv` (Option String). Plumb `argc`/`argv` by changing the emitted entry to
  `main(i32 %argc, ptr %argv)` and stashing them for the extern. **DONE 2026-06-07.**
  `mdk_set_args`/`mdk_args`/`mdk_get_env` in `runtime/medaka_rt.c`; `isEnvExtern`/
  `emitEnvExtern` in `selfhost/llvm_emit.mdk`; `emitProgram` entry changed to 2-arg
  `@main(i32 %argc, ptr %argv)` (harmless for non-args programs); `LUnit` literal
  added to `emitLit`. Fixtures: `env_args_empty` ([] case — both oracle and native
  see no extra args), `env_getenv_none` (unset var → None → 0), `env_getenv_some`
  (PATH → Some → 1). **114/114 plain byte-identical**; 16/16 typed; 20/20 core_ir;
  20/20 eval. GATE LIMITATION: `args`' non-empty path (mdk_cons via argv[1..]) is
  not gate-verifiable — oracle's `program_args=[]` and native `./bin` both yield [];
  only the empty case is byte-gated. The real argv→Cons plumbing is implemented and
  correct; the gate limitation is inherent to the test harness.
- ✅ **Slice 13 — file IO** (dep: 10). **DONE 2026-06-07.** `readFile`/`writeFile`/
  `appendFile` (Result String String/Unit), `fileExists` (Bool), `listDir`
  (Result String (List String)), `readLine`/`readLineOpt`/`readAll` (stdin).
  `mdk_str_cstr` helper + seven C functions in `runtime/medaka_rt.c`; `isFileExtern`/
  `emitFileExtern` in `selfhost/llvm_emit.mdk` (wired after `isEnvExtern`); 8 new
  `declare i64` entries in `emitPreamble`. 6 fixtures: `s13_write_read` (write+read
  → length 5), `s13_append` (write+append+read → length 3), `s13_exists_true`,
  `s13_exists_false`, `s13_listdir_ok`, `s13_listdir_err`. All byte-identical vs
  oracle. `readLine`/`readLineOpt`/`readAll` implemented but NOT fixtured — the
  gate does not pipe stdin; both sides would hang or be nondeterministic. **Tier C
  complete. Tier A + B + C all done — native extern catalog fully ported.**

**Tier D — different shape (NOT the C-extern template; scope/flag separately):**

- **Slice 15 — `→MEDAKA` sorts + builder.** `arraySortBy`, `arraySortInPlaceBy`,
  `arrayMakeWith` — *rewritten in Medaka* (a mergesort/introsort over `Array`), not C
  externs (RUNTIME-DESIGN §4: the comparator/builder is a Medaka closure). Skill:
  `extend-stdlib`. *Sonnet: good, but a stdlib task, not a runtime task.*
- ✅ **RNG — `randomInt`/`randomBool`/`randomFloat`/`randomChar`/`setSeed`.** **DONE
  2026-06-07 (deterministic SplitMix64).** Resolved the gating decision: Medaka's RNG
  is now a *specified* SplitMix64, the SAME algorithm in `lib/eval.ml`
  (`splitmix64_next`, an `Int64` state — replaces OCaml `Random`) and the runtime
  (`mdk_next_u64` in `runtime/medaka_rt.c`), seeded identically → byte-identical
  streams per seed, reproducible property tests, cross-backend stable. Ranges
  preserved from the old oracle: `randomInt` INCLUSIVE [lo,hi]; `randomFloat` ∈ [-1,1);
  `randomChar` ASCII [32,126]; `randomBool` 50/50. Parity: OCaml uses
  `shift_right_logical`/`unsigned_rem`; C `uint64_t`; the float path is bit-identical
  (`randomFloat` byte-matched at `-0.476939056861`). `isRngExtern`/`emitRngExtern` in
  the emitter (Int/Bool/Char tagged via `tagInt`, Float boxed, setSeed→Unit). 6
  fixtures (rng_int/bool/float/char/seq/reseed; `reseed`=0 proves same-seed
  determinism). **126/126 plain byte-identical**; 16/16 typed; 20/20 core_ir; 20/20
  eval. NOTE: this is the one Tier-D item that edits the oracle (`lib/eval.ml`) — a
  deliberate language-semantics decision, not under the spike scope guard.
- **`hash` → `→METHOD` (derived `Hashable`).** Convert the lone structural extern to
  a derived typeclass method (same `deriving` machinery as `Eq`). A typechecker/
  desugar lift, not a runtime extern. Skill: `add-language-feature`. *Escalate — not
  a catalog slice. Decided 2026-06-07: DO IT (combiner `acc*33 + hash field`; migrate
  hash_map/hash_set off the extern).*

Dependency order for execution: **2–7 in any order (no deps) → 8 → {9, 14} → 10 →
{11, 12, 13}**; 15 / RNG / hash are independent and separately scoped. Slices 2–9 and
14 clear the bulk the self-host source leans on (string/char/array ops); 10–13 unlock
the IO-and-`args`-heavy driver paths (`args` 140×, `readFile` 106× in `selfhost/`).

### Self-host (Stage 1 tail)

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

- **`medaka build`** — needs its own design first: a serialized Core IR now
  exists (`selfhost/core_ir_sexp.mdk` — `cprogramToSexp`/`parseCProgram`,
  round-trip proven; `test/diff_selfhost_core_ir_roundtrip.sh`), but a build
  artifact cache also needs a cache-key strategy (content hash of source +
  transitive imports) and an on-disk layout. Until that design exists it would
  only be an alias of `check`.
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
