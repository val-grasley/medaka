# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-05)

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
below and `selfhost/README.md` for the full slice log. A couple of
forward-looking performance levers remain (lexical addressing eval-consumption
half).

**Conventions.** Work is organized by numbered **Phases**; commit messages and
code comments reference them. Phases left *partial* keep their original number
(e.g. Phase 83/84, 101); genuinely new work gets the next free number (last used:
146). At task triage, match the work against AGENTS.md's task-playbook table and
load the matching skill before planning.

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
  - ✅ **Toolchain de-risking spike DONE (slices 1–2b)** — *ahead of the strict
    VM-first ordering by design* (front-loads the riskiest lift; runs parallel to
    the bytecode VM, uses only the tree-walker oracle). Proves the decided toolchain
    (EMIT textual LLVM IR + shell out to `clang`; no llc/opt, no C++/Rust bindings)
    end-to-end: `selfhost/llvm_emit.mdk` (Core IR → textual LLVM IR) +
    `selfhost/llvm_emit_main.mdk` + `runtime/medaka_rt.c` (a malloc-and-leak stub;
    GC deferred), gated by `test/diff_selfhost_llvm.sh` (emit → clang → link → run →
    diff vs `dev/eval_probe.exe`, **17/17 byte-identical**). Slice 1 = scalars
    (arithmetic / comparisons / `let` / `if` / value bindings / type-directed
    print). Slice 2 = top-level functions + saturated direct calls; self-recursive
    tail calls lower to `musttail call`+`ret` (the calling-convention proof,
    TCO-correct under `clang -O0`). Slice 2b (2026-06-06) = **Bool/Float function
    boundaries** via a two-pass signature inference that recovers each function's
    param + return type from the type-erased Core IR (param type from its first
    typed use, return type structural); the ABI stays a uniform i64 word, so the
    recovered type drives only int-vs-float instruction + print-routine selection,
    no prototype/`musttail` change, **no value-rep edit**. **Not** the real backend
    (no closures/ADTs/records/dispatch/GC; out-of-scope nodes panic). See
    [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) §2.4.
- ✅ **§2.1 — Core IR + evaluator DONE (2026-06-05).** `selfhost/core_ir.mdk`,
  `core_ir_lower.mdk`, `core_ir_eval.mdk` (+ sexp/round-trip gates). 47/47
  fixtures byte-identical across 6 corpora. See `selfhost/README.md`.
- ✅ **§2.2 — Bytecode VM (all 6 slices) DONE (2026-06-05).** `selfhost/bytecode.mdk`
  (compiler + stack VM) + single-file driver + multi-module driver. 22/22 fixtures
  (18 single-file slices 1–5 + 4 multi-module slice 6). Zero `eval.mdk` changes —
  full Axis-2 reuse. See `selfhost/README.md`.
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

The immediate runway for the Phase 146 / WASM-edge wedge (full design:
[`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md),
[`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md); architecture decisions: the
"Targets & the WASM soft-pivot" callout above). Dependency-ordered; items 1–3 are
design/research and parallelizable. Item 4 (effect soundness) is **already done**;
item 5 (fine-grained labels) is the first *remaining* coding step.

1. **Research pass (narrowed).** WASI Preview 2 / Wasm component-model capability
   model; edge-host isolation specifics (Cloudflare Workers, Fastly Compute, Fermyon
   Spin); object-capability & effects-as-security literature; competitor scan
   (MoonBit especially — closest; Grain; Roc's platform model). TCO + WasmGC
   viability is already **verified** (STAGE2-DESIGN §2.4b). Output: a findings note.
   Skill: none (research).
2. **Phase 146 design note (gate before coding).** Concrete effect-tracking surface
   syntax (label declaration, inferred-vs-annotated boundary, subsumption), the
   capability-manifest format a host reads, and 2–3 worked plugin interfaces (reuse
   the discount-calc / auth-middleware / pipeline examples in CAPABILITY-PLATFORM.md)
   pressure-tested on paper. Skill: **add-language-feature** (planning).
3. ✅ **Stdlib capability audit — DONE 2026-06-06.** Cataloged all extern/stdlib
   functions by capability tier (P/M/H); designed the pure-core/capability-module
   split; documented effect labels, the `<IO>`-split roadmap, and the `panic`
   design gap. Output: `STDLIB.md` §"Capability stratification audit". Skill: **extend-stdlib**.
4. ✅ **Sound effect tracking — DONE (Phase 79/79e/146; selfhost mirror 2026-06-06).**
   Effect propagation/inference, higher-order `<e>` composition
   (`map : (a -> <e> b) -> List a -> <e> List b`), binding-boundary escape, and
   laundering soundness all shipped — in the reference *and* the selfhost mirror (see
   the Phase 146 entry above + CAPABILITY-EFFECTS.md §5a). This was the prerequisite
   for any capability guarantee; gap-1 is closed. No remaining work here.
5. **User-definable fine-grained effect labels (gap 2). ✅ DONE 2026-06-06.**
   Replaced the hardcoded `built_in_effects` membership check in `resolve.ml` with
   *builtins (`IO`/`Mut`/`Async`/`Panic`/`Rand`/`Time`) ∪ user-declared* via a new
   top-level `effect Foo` (`export effect Foo`) declaration form (`DEffect of bool *
   ident`); an undeclared label in a row stays `UnknownEffect`. Threaded
   lexer→parser→AST→resolve with **zero new parser conflicts**; typecheck needed no
   change (the row-unify/subsumption path is label-agnostic, so user labels inherit
   Phase 146 laundering soundness). Selfhost mirror complete (lexer/parser/ast/
   sexp/resolve `.mdk`), all `diff_selfhost_*` byte-identical. Fixtures: unit
   (test_parser/resolve/typecheck) + differential (diff_fixtures/effect_label,
   parse_fixtures/effect_decl, resolve_fixtures/unknown_effect). Syntax + rationale:
   CAPABILITY-EFFECTS.md §3a/§5a. **Remaining for the wedge:** cross-module label
   export + manifest emission. Skill: **add-language-feature**.

**Concrete near-term target:** gap 2 (labels, ✅) + a ~150–250-line harness, on the
existing interpreter, produces the **minimal "wow" demo** ✅ — `demo/plugin_good.mdk`
and `demo/plugin_malicious.mdk` + `medaka check-policy` CLI subcommand. The malicious
plugin buries `fetch` four calls deep; the harness typechecks the plugin, reads
`transform`'s inferred effect row, checks it against the policy set, and either accepts
(running it on a sample request) or rejects it with the full call chain:
`transform → tagVisit → recordMetric → sendBeacon → fetch`. First shareable
artifact, decoupled from the backend. Full sketch: CAPABILITY-PLATFORM.md §7c.

Downstream (already captured, NOT near-term): **Phase 146b** parameterized effects
(CAPABILITY-EFFECTS §6a); the **WasmGC backend** (STAGE2-DESIGN §2.4b); the
**capability platform/runtime** (CAPABILITY-PLATFORM.md).

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
  the host that runs it) exactly what it can do." Target use case: WebAssembly edge
  / plugin / sandboxed compute, where untrusted, increasingly AI-generated modules
  need their authority bounded at compile time. **Effect *tracking*, NOT
  algebraic-effect *handlers*** (no `perform`/`handle`/`resume`/continuations — the
  host is the handler; continuations are also Wasm-hostile). Effects stay **erased
  at runtime** (zero cost; manifest is metadata). Full design and per-piece status
  in [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) (§5a). Skill: cross-cutting
  → **add-language-feature** (threads resolve/typecheck/eval; not harden-typechecker
  despite the typechecker weight). **Note:** deliberately revisits the
  *row-polymorphism* rejection in PLAN-ARCHIVE §8, narrowed to *effect* rows only (a
  scoped effect-label grammar, not general extensible records).
  - **Gap 1 (soundness) — propagation DONE (Phase 79/79e); laundering soundness
    DONE for open/closed rows (2026-06-05).** The doc's "annotation-only, no
    propagation" framing was stale: inference with effect variables, higher-order
    `<e>` composition (`map : (a -> <e> b) -> List a -> <e> List b` on real stdlib),
    and binding-boundary escape checks already shipped. What was still unsound was
    **effect laundering** — an effectful closure stored in / annotated as a pure
    arrow (data field, value signature, callback param, typeclass-method impl)
    silently dropped its labels because `unify_row` was permissive. Fixed by
    enforcing OPEN-row labels ⊆ CLOSED-bound labels in `unify_row` (closed extras
    still flow into the open sink → legit calls unchanged); new `EffectLeak` error.
    Zero regressions across all unit suites, `@thorough`, and selfhost
    typecheck/check/selfproc. Tests in `test_typecheck.ml` `effects` group.
  - **Gap 1 remaining — directional subsumption. DONE (2026-06-06).**
    Closed-closed point-free aliasing (`f : String -> Unit = putStrLn`,
    `Box putStrLn`, `[putStrLn]` under a pure annotation) used to launder: both
    rows closed → symmetric `unify_row None,None` couldn't tell safe
    pure→effectful subsumption from unsafe effectful→pure escape. Fixed in
    `instantiate_raw`: re-open a closed-with-labels row to `<labels | ρ>` **only
    at covariant (positive) positions** (the value's own arrows), so the existing
    open/closed subset check fires. Contravariant rows (ctor field / parameter the
    scheme accepts, e.g. `VPrim (Value -> <Mut> Value)`) stay closed → safe
    subsumption preserved (pure arg into a `<Mut>` slot is fine). Measurement
    surfaced ONE genuine latent unsoundness in selfhost source — `concatMapList`'s
    pure callback hid `<Mut>`; fixed by an effect-polymorphic signature
    (`util.mdk`). Zero spurious regressions across all unit suites, `@thorough`,
    and every selfhost harness. Gap 1 is now sound. Contravariant laundering is
    NOT a hole: effects are performed by *calling* effectful functions, so a value
    only exposes effects it itself performs (covariant); contravariant effects are
    the supplier's, checked at the supply site.
  - **Selfhost mirror — DONE (2026-06-06).** The original framing ("mirror the two
    small rules") was **wrong**: `selfhost/typecheck.mdk` had no effect rows at all
    (effects were a bare `List String` on `TFun`, `unifyN` discarded them, `Scheme`
    had no effect variables, no ambient-effect state). The real work was a **full
    port of the effect-tracking subsystem** — Phase 79 (propagation), 79e (escape),
    and 146 (laundering) — done across four committed stages: A (representation:
    `EffRow`/`Effvar` mutual decls, `Scheme = Forall tyvars effvars`), B (ambient
    `curEffect`, `performEffect`/`openRow`/`unifyRow`/`substRow`/`freeEffvars`,
    named-tail sharing for `<e>`-poly sigs), C (binding-boundary escape in
    `inferMembers`/`checkEffectEscape`), D (the `unifyRow` subset rule +
    variance-aware `substMonoP`/`reopenRow` covariant re-open). Three new fixtures
    (`effect_leak`/`effect_escape` reject, `effect_subsume` accepts) verified
    against `dev/tc_probe.exe` first. All `diff_selfhost_*` typecheck/error/golden/
    check/check_modules/selfproc/eval harnesses byte-identical; `@thorough` green.
    The self-hosted typechecker now rejects effect laundering identically to the
    reference — gap-1 selfhost parity closed.
  - **Gap 2 (fine-grained labels) — ✅ DONE 2026-06-06.** Replaced the hardcoded
    `built_in_effects` (`IO, Mut, Async, Panic, Rand, Time`) membership check in
    `resolve.ml` with *builtins ∪ user-declared* via a top-level `effect Foo`
    (`export effect Foo`) declaration form (`DEffect of bool * ident`); undeclared
    labels stay `UnknownEffect`. Lexer→parser→AST→resolve, zero new parser
    conflicts; typecheck unchanged (row-unify is label-agnostic → user labels get
    Phase 146 laundering soundness free). `DExtern` is a top-level decl, so a
    platform declares `<KV>` host imports as ordinary externs. Selfhost mirror
    complete; all `diff_selfhost_*` byte-identical, `@thorough` green. Details:
    CAPABILITY-EFFECTS.md §3a/§5a. Cross-module label export deferred.
  - **Manifest emission — TODO** (waits on the edge runtime; research pass per
    CAPABILITY-EFFECTS §9).
  - **Phase 146b (parameterized effects) — TODO.** Pinned domains `<Fetch "x.com">`
    / scoped storage `<KV "ns">` via type-level literal params over finite-set
    lattices + literal-lifting — the layer the platform's pinned-domain &
    namespaced-KV guarantees need. Designed in CAPABILITY-EFFECTS.md §6a; two
    sub-questions deferred there (singleton-arg wrapper precision; param-aware
    unification × typeclass/dict). Follows gap 2 (labels). The platform/runtime that
    consumes all of this is [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md).

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

- **Phase 83 / 84 #5 — true recursive/nested instance dictionaries. REFERENCE
  DONE (2026-06-05); self-host mirror is the only remaining work.** The
  instance-`requires` dict-threading into return-position impl bodies is DONE; the
  tractable set was closed by Phase 115, and #4 (free-`e` `Result`) closed via
  head-key dict-application routing (all in PLAN-ARCHIVE.md). #5 — the
  `List (List Int)` case — is now **built in the reference**: structured/recursive
  dicts replace the flat impl-key strings. Skill: **harden-typechecker** /
  **add-language-feature** (cross-cutting).
  - **(2026-06-05) #5 reference build — DONE; oracle established.** `medaka run`
    now prints `def : List (List Int)` → `[[0]]`, `List (List (List Int))` →
    `[[[0]]]`, and mixed `Option (List (Option Int))` → `Some [Some 0]` (single
    and multi-module loader paths). The runtime dict is now **structured**:
    `VDict of string * value list` / `VDictHead of string * value list` (key plus
    the impl's own `requires` dicts, recursively); `Ast.RKey of string * res_route
    list` carries the requires routes. The fix has three moving parts, all
    mirroring machinery that already existed for *checking*:
    1. `lib/typecheck.ml` `impl_requires_routes_rec` — the routing twin of the
       already-recursive `check_entry_requires`; resolves each `requires` to
       `RKey (chosen_key, <its own requires routes>)` recursively. Used by both
       the method-occurrence ground path (`commit`) and the dict-application
       ground path (`resolve_one_route`).
    2. `lib/eval.ml` `dict_of_route` recurses to build the nested `VDict`; the
       `EMethodRef` arm, for a *forwarded* (RDict) return-position site, splices
       the runtime dict's own `requires` into the selected impl's body.
    3. The forward is **gated** by a new `res_fwd_requires : bool` on the resolved
       record (true only for return-position RDict sites) — without it,
       arg-position methods (`display`/`==`, which dispatch by arg-tag) get extra
       leading dict args and corrupt: the regression that broke `println [1,2,3]`
       mid-build. `dict_pass.ml` needed **no** change (param count is unchanged;
       depth lives in the value). Regression test:
       `test_run.ml t_nested_instance_dicts`.
  - **Self-host mirror — DONE (2026-06-05).** `selfhost/ast.mdk`/`typecheck.mdk`/
    `eval.mdk` + fixture `test/eval_dict_fixtures/nested_instance_dicts.mdk`.
    `def : List (List Int)` → `[[0]]`, `def : List (List (List Int))` → `[[[0]]]`,
    `def : Option (List (Option Int))` → `Some [Some 0]` all match `medaka run`.
    Key selfhost-specific gotcha: `implDictRoutesFor` must thread the **full**
    implTable (not `rest`) through the helper so sub-route lookup can re-find the
    `"List"` impl for the inner level. Also `siteRDictName` (dict_pass usesImplDict
    gate) must match `RDictFwd` as well as `RDict`. 17/17 eval-dict, 16/16
    selfproc, 18/18 golden — all gates green.
  - **Phase 101b nesting limit is now lifted**: `Arbitrary` instance-requires dicts
    are structurally nested (e.g. `gen : List (List Int)`) on the self-host dict
    path. Phase 101b (synthesized typed generators) can proceed.
  - **Self-host parity work toward this (Option C, user-approved):** Layer 1 DONE
    — user-defined SINGLE-impl return-position methods now resolve on the
    self-host typed/dict paths (a bare-`VTypedImpl` wrapper-strip bug in
    `selfhost/eval.mdk narrowMethod`; fixture
    `test/eval_typed_fixtures/single_impl_return_pos.mdk`). Layer 2 — single-level
    instance-`requires` in the self-host — **DONE (2026-06-05).** `def : List Int`
    → `[0]`, `def : List String` → `["empty"]`, `def : Option Int` → `Some 0` all
    match `medaka run` on the self-host dict path. 4-step port (EMethodAt 2nd
    impl-dicts ref; gated `implInferEnabled` impl-body inference sharing one tyvar
    table head↔requires; `dictPassDecl` `DImpl` arm; eval folds via `applyDicts`)
    — see the "Instance-`requires` dict-passing" block in `selfhost/README.md` for
    the per-file detail. Fixtures `test/eval_dict_fixtures/instance_requires_*.mdk`.
  - **Method-level-constraint dicts (Phase 69.x-e) in the self-host — DONE
    (2026-06-05).** A method whose own signature carries a `=>` over a non-interface
    tyvar (`foldMap : Monoid m => …`): the caller-supplied `Monoid m` dict is now
    threaded into the method's default body so its return-position `empty` resolves
    correctly. `foldMap dup [1,2,3]` → `[1,1,2,2,3,3]` matches `medaka run`. 4-step
    port (EMethodAt 3rd method-dicts ref; `methodConstraintsRef` + `inferDefaultBodies`
    gated by `implInferEnabled`; `dictPassDecl` `DInterface` arm; eval folds method
    dicts before impl dicts) — see the "Method-level-constraint dict-passing" block in
    `selfhost/README.md`. Fixtures `test/eval_dict_fixtures/method_constraint_*.mdk`.
    Out of scope: multi-impl *overrides* of such a method (dict param shifts the
    container-dispatch position; no prelude impl overrides `foldMap`).

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

### Stdlib enablement (Phase 19) — ✅ COMPLETE

All of Modules 1–9 are done (`core`/`list`/`array`/`string` + `map`/`set`, hash
containers, `io`, `mut_array`, `json`) — see PLAN-ARCHIVE.md and STDLIB.md. The
hand-write-it-myself constraint was lifted 2026-06-02 and the remaining modules
delegated. `stdlib/string.mdk` API frozen 2026-06-03 (Phase 128).

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
