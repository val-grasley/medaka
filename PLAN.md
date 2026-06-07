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
runs through slice 9 (the full non-GC Core IR surface). See the [Workstreams table](#workstreams--where-each-roadmap-lives) for
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
| **Native backend (Stage 2)** | [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) §"Staged plan" + [`RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md) §7–8 | 🟡 in progress | Core IR + bytecode VM (§2.1–2.2) fully done incl. capstone; LLVM spike thru slice 9 — **full non-GC Core IR surface covered** (43/43 gate); §2.0 closed; **value rep RATIFIED (2026-06-07** — Option A tagged word under §8.6 contract, dense i32 ctor-ordinal, uniform header**)**; next = real backend (GC + extern catalog + ordinal tags) → WasmGC sibling §2.4b. See [Native backend near-term sequence](#native-backend-stage-2--near-term-sequence) |
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
  - ✅ **Toolchain de-risking spike DONE through slice 9** (2026-06-07) — *ahead
    of the strict VM-first ordering by design* (front-loads the riskiest lift; uses
    only the tree-walker oracle). Proves the decided toolchain end-to-end (EMIT
    textual LLVM IR + shell out to `clang`; no llc/opt, no C++/Rust bindings):
    `selfhost/llvm_emit.mdk` + `llvm_emit_main.mdk` + `runtime/medaka_rt.c`
    (malloc-and-leak stub; GC deferred), gated by `test/diff_selfhost_llvm.sh`
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
    non-empty `PList` binding, partial application, Ref capture still panic). Full
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
§2.4 **LLVM de-risking spike thru slice 9** — the full non-GC Core IR surface
(scalars → fns → ADTs/match → closures → records/tuples/refs → return-position +
arg-tag dispatch → arrays/ranges → lists), 43/43 plain + 6/6 typed gate ✅.

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
2. **Promote the spike to the real LLVM backend** (§2.4). The spike covers the Core
   IR but is explicitly *not* the real backend; the remaining lifts are the
   decision-dense ones deferred by design: a **GC** (Boehm to start — the spike is
   malloc-and-leak), the **native extern catalog** re-implementation (per-extern
   disposition in RUNTIME-DESIGN), the **dense i32 ctor-ordinal** tag emission (the
   ratified scheme, replacing the spike's hash), and the spike's out-of-scope gaps
   (arg-tag dispatch on non-ADT/Int args, nested-requires dicts). The `decodeHead`
   reserved-name aliasing bug — a lift here until the ordinal scheme exposed it — is
   now fixed ahead of this work (see Compiler / language). Gate: native
   stdout vs the tree-walker **and** the bytecode VM (the second, single-steppable
   oracle). Skill: none specific (lands in `selfhost/llvm_emit*.mdk` + `runtime/`).
3. **Bootstrap closure** — self-hosted compiler + LLVM backend compiles itself to a
   standalone native binary (the finish line, STAGE2-DESIGN §2.4).

Downstream (captured, NOT near-term): the **WasmGC sibling backend** (§2.4b — the
capability-wedge delivery vehicle, reached by a direct emitter; soft-pivot
constraints are already design inputs to the shared layers).

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
