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
149). At task triage, match the work against AGENTS.md's task-playbook table and
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
| **Make LLVM canonical (Stage 3)** | **this file** → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) | 🟡 **next** | Harden the native backend toward CANONICAL + gated OCaml retirement: `medaka build` CLI → completeness (max/min + emitter-gap sweep) → port OCaml test suites to Medaka → differential fuzzer → TRMC/worker-thread stack scalability → perf (-O2, value-rep) → housekeeping refactor (style/DRY) → self-bootstrapping build → retire `lib/` (gated). |
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

**Oracle (hybrid).** As OCaml recedes, ground truth = the Medaka tree-walker
(`eval.mdk`) for runtime BEHAVIOR (native diffed vs interpreted-selfhost — the
bootstrap pattern) **+** frozen GOLDEN snapshots for structural dumps
(tokens/AST/Core-IR/types). Belt-and-suspenders; neither depends on `lib/`.

**Near-term sequence (front-loaded order, decided 2026-06-09):**

1. **`medaka build` CLI** — wire the LLVM backend into the actual CLI so
   `medaka build foo.mdk` emits → `clang` → native binary for ARBITRARY user
   programs (today native compilation lives only in `test/selfcompile_*.sh` /
   `bootstrap_*.sh`). Surfaces the backend and forces it to handle programs beyond
   the compiler's own source. Design points: output path + linking (`medaka_rt.c`
   + libgc), the **gap policy** (a *reachable* gap must be a hard error, not a
   silent placeholder — the gap-tolerant driver is bootstrap-only), error
   reporting, and how it relates to `medaka run` (interpreter) — see the
   [CLI surface](#cli-surface-phase-82-continued) `medaka build` note.
2. **Completeness — `max`/`min` + emitter-gap sweep.** Close the last known gap
   (`max`/`min` over primitive `Ord`: a default method whose `compare` impls are
   primitives with no runtime tag — via dict-passing or monomorphic
   specialization; `selfhost/EMITTER-GAPS.md`). Then AUDIT `emitTree`/`emitExpr`/
   `emitApp` for every reachable `gapU`/`gapE`, and build a **language-construct
   coverage matrix**: the bootstrap only exercised what the compiler's own source
   uses — user programs use more (list comprehensions, all operator sections,
   inclusive ranges, string interpolation, every `do`/guard form, record/variant
   update, etc.). One native==interpreter fixture per construct in `SYNTAX.md`.
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
