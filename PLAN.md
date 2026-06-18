# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-14)

**Post-flip soak progress (since the 2026-06-12 native-canonical flip):** the
**gate suite is fully re-rooted off the OCaml oracle** — every correctness gate is
OCaml-free (`selfhost/REROOT-PLAN.md`); capture/mint tooling and the perf-baseline
gates keep OCaml at capture time by design until `lib/` removal. The **driver
collapse** is done (`selfhost/DRIVER-COLLAPSE-PLAN.md`): single-file typecheck+eval
now run as the 1-module case of the multi-module path (closes audit §6's recurring
single-vs-multi defect), and `medaka check` resolves imports. Native dispatch fixes
landed: **#55** (sum/product two-constraint, on both the build AND eval paths),
**#21** (binop over-application on parametric user `impl`s — removed the
`suppressBinopStamp` workaround), and the map **`Foldable (Map a)`** typecheck
false-positive + `medaka test` SIGBUS. Native stdlib test coverage expanded
(json/toml/list/set doctests+props), and the **fuzzer is ported to native**
(`fuzz_diff.sh` OCaml-free). The native-emitter **cross-module constructor-name
collision** (the fuzzer's find — really a bare-name ctor-table collapse, not the
"mixed-ADT match" first suspected) is fixed via universal ctor mangling; the
**`argStampEnabled` eval-vs-emit dispatch unification is COMPLETE** (eval now threads
dicts — the GENUINE #21 nested-element-dict flattening solved, not contained;
`evalDictLayerActive` retired; `selfhost/ARGSTAMP-UNIFY-PLAN.md`); and the **emit-path
Set-literal / mutual-rec-Monoid dict gaps** are fixed. **Remaining = the soak itself:**
a clean bug-free stretch of native-only dev, then the confidence-gated `lib/` removal.

**Soak findings from the Unit-`main` auto-print + fmt work (2026-06-16/17) — ALL CLOSED:**
- **Native under-defaulted ambiguous `Num` bindings** (`fa = [10,20,30].[1]` → native `fa : a` vs
  oracle `fa : Int`; `poly_let`/`index_default`) — ✅ CLOSED by the #11 value-level-defaulting fix
  (`4fc5f47`/`18176ea`): the no-prelude HM driver wasn't recording the literal's `Num` obligation, so
  nothing to default; now recorded unconditionally. `diff_selfhost_typecheck` 12/0.
- **Native type-error wording** (`default_body_type_error`: native `Type mismatch: Int vs Bool` vs
  oracle `Method 'greetDefault': expected type Int but got Bool`) — ✅ CLOSED (`18176ea`): specialized
  default-method-body error. `diff_selfhost_typecheck_errors` 35/0.
- **Native printer missing `ENumLit` arm** (fmt SIGTRAP on int literals) + **Unit-`main` auto-print
  suppression** — ✅ CLOSED in `d0a99a9` (merged); the interp-side `dev/eval_probe` lag (5
  `diff_selfhost_llvm` failures) closed in `7540a7e`. `diff_selfhost_llvm` 180/0. Native, interp,
  and CLI now all consistent: a Unit `main` prints nothing; value `main`s print their result.

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

The **OCaml compiler** (`lib/*.ml`) is now the **frozen soak-period differential
oracle** — native is canonical (2026-06-12 flip) and the build is OCaml-free
(`make medaka`, from a checked-in IR seed). `lib/` stays in-tree, frozen, until a
confidence-gated soak completes, then is removed (retirement ≠ removal; see
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml)).

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
| **Make LLVM canonical (Stage 3)** | **this file** → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) | 🟢 **essentially complete** | Native canonical (2026-06-12 flip); TYPECHECK-AUDIT (16 findings) + all 4 dispatch gaps (#54/#55/#50/#21) + perf bar-4 + Phase-C CLI capstone + gate re-rooting + the driver collapse all ✅ DONE (full log: PLAN-ARCHIVE.md → Stage 3 completion log). Soak fixes (2026-06-15): native-emit scale failure (`unbound 'not'`, fuzzer 5%→100%) ✅ DONE; foldMap method-level-constraint dict gap ✅ DONE (eval_dict 25/0). **Soak tail remaining:** the `argStampEnabled` eval-vs-emit dispatch unification ([`ARGSTAMP-UNIFY-PLAN.md`](./selfhost/ARGSTAMP-UNIFY-PLAN.md)), then confidence-gated `lib/` removal. |
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
fixpoint (see [Current status](#current-status-2026-06-14)). Full per-stage detail
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


**Status: Stage 3 is essentially COMPLETE — see the full item-by-item log in
[PLAN-ARCHIVE.md → Stage 3 — native-canonical completion log](./PLAN-ARCHIVE.md#stage-3--native-canonical-completion-log-archived-2026-06-14).**
The native LLVM backend is canonical (2026-06-12 flip): `make medaka` builds it
OCaml-free; all PRE-FLIP-GAPS soundness/capability gaps (G1–G9) closed; the full
TYPECHECK-AUDIT (16 findings — S1·S2·T1·T1b·T2·S3·C1·C2·C3·C6·C7·C8·C9·OBS3·OBS4)
closed; the construct-coverage sweep + all four native dispatch gaps (#54/#55/#50/#21)
closed; perf bar-4 done (5.68× self-compile / ~59× vs interp — `selfhost/PERF-RESULTS.md`);
the Phase-C native-CLI capstone + Stage-4 tooling port (fmt/test/new/repl/build/lsp) done;
**gate re-rooting done** (all correctness gates OCaml-free — `selfhost/REROOT-PLAN.md`);
the **single-file/multi-module driver collapse done** (`selfhost/DRIVER-COLLAPSE-PLAN.md`,
closes audit §6; `medaka check` now resolves imports).

**Soak tail (remaining, see "Current status" above for live state):** the `argStampEnabled`
eval-vs-emit dispatch unification (`selfhost/ARGSTAMP-UNIFY-PLAN.md` — retires the finer
dispatch fork the driver collapse left, the shared root of #55/#21); then a clean bug-free
soak stretch and the confidence-gated `lib/` removal (next). (Closed 2026-06-15: native-emit
scale failure `unbound 'not'` — fuzzer 5%→100%; foldMap method-level-constraint dict gap —
eval_dict 25/0; whole-float rendering canonical `1.0`.)

**Gated milestone — retire `lib/*.ml`.** ✅ **Native is now the default build (2026-06-12
flip):** `make medaka` builds the canonical native compiler OCaml-free from the seed; docs
updated; OCaml frozen as the soak oracle. **Re-rooting ✅ DONE (2026-06-13):** every
correctness gate runs OCaml-free (`selfhost/REROOT-PLAN.md`); only the capture/mint tooling
(`capture_goldens.sh`/`refresh_seed.sh`) and the perf-baseline gates (`bench.sh`/`profile_selfhost.sh`)
still invoke OCaml — by design, deleted with `lib/`. **Remaining gated steps (post-soak):**
the `argStampEnabled` eval-vs-emit dispatch unification (`selfhost/ARGSTAMP-UNIFY-PLAN.md`),
a clean bug-free soak stretch, then archive/delete the OCaml compiler. Sequenced toward, not dated.

After Stage 3, the **capability-effects wedge** (Phase 146) + the **WasmGC
backend** are the product horizon (see the Workstreams table).

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority.

### Stage 4 — full tooling port → native `medaka`, retire OCaml (decided 2026-06-10)

**Stage 4 (full tooling port → native `medaka`) — ✅ COMPLETE.** All six tools —
`fmt` / `test` / `new` / `repl` / `build` / `lsp` — were ported to Medaka and
differential-tested byte-identical vs OCaml, and the **Phase-C native-CLI capstone**
(`selfhost/driver/medaka_cli.mdk`, Slices 0–4) is done: the native `medaka` binary does
all 8 subcommands (`check`/`fmt`/`new`/`build`/`run`/`test`/`repl`/`lsp`) with no OCaml at
runtime. Full per-tool / per-slice completion log archived in
[PLAN-ARCHIVE.md → Stage 4 — tooling-port completion log](./PLAN-ARCHIVE.md#stage-4--tooling-port-completion-log-archived-2026-06-14).

**Remaining (minor, not retirement-blocking):**
- **Diagnostics surfacing layer** (mirror `lib/diagnostics.ml` — structured errors for the
  CLI + LSP): marked TODO; verify whether the native CLI's current error surfacing already
  covers it in practice before treating it as open.
- **Auxiliary port:** `coverage.ml` + `bench_runner.ml` — port last.

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

### Future idea (parked, not scheduled): stack-performance recursion lint

An **opt-in** compiler lint that flags self-recursive functions whose recursion is **neither tail**
(handled by `musttail`) **nor tail-modulo-constructor** (handled by TRMC #56) — i.e. functions that
will grow the native stack on deep input — to nudge users toward accumulator / tail-modulo-cons shapes
for better stack performance. **Nearly free once TRMC lands:** reuse TRMC's `trmcEligible` + the
tail-call classifier — the "neither" bucket *is* the warning. Surface through `medaka check` + LSP.

**Key design tension = NOISE.** Most non-tail recursion is perfectly safe (balanced-tree recursion is
O(log n) stack; bounded recursion never gets deep). A blanket warning fires on tons of legitimate code
and trains users to ignore it — which is exactly why **OCaml and GHC don't warn on non-tail recursion
by default.** So the principled version is **off by default** (a `--warn-stack` lint level /
annotation-suppressible), scoped to self-recursion over a **recursive data structure** in non-tail
non-TRMC position (the `length (x::xs) = 1 + length xs` accumulator-able shape), NOT all non-tail
recursion.

**Why parked:** QoL diagnostic, off the canonicalization critical path. Needs TRMC's classifier (do
after #56). The complement to the TRMC + big-stack stack-safety work, not a blocker.

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

- **Num-polymorphic numeric literals — ✅ DONE (2026-06-16, both compilers, run + build).**
  Integer literals in expression position are `Num a`-polymorphic in BOTH the OCaml oracle and
  the selfhost/native compiler; `x : Float; x = 0`, `1.0 + 2`, `g : Float -> Float; g x = x + 1`,
  and **polymorphic literal-bearing fns** (`inc x = x + 1` applied to `2.5` → `3.5`) all typecheck,
  `run`, AND `build` correctly (oracle == `medaka run` == `medaka build`). Full design + locked
  decisions: [`NUMLIT-DESIGN.md`](./NUMLIT-DESIGN.md). **Landing log:** Stages 0-2 OCaml (`eac278b`);
  Stages 3-4 selfhost+native (`7424b64`); **soundness fix** OCaml (`e7031e6`) + selfhost (`183b7b4`);
  **emitter Gap E/C4 closure** (`a8b95d7`). Mechanism: a transparent `ENumLit` AST node (renders
  identically to `ELit (LInt n)` so sexp/round-trip unaffected) carries a `Num` obligation; a
  **defaulting pass** at every generalization boundary grounds an *ambiguous* Num-constrained var
  (not arg-reachable) to `Int` (MR-for-Num, locked §0.2); a post-HM stamp elaborates the literal —
  concrete-Int → `LInt`, concrete-Float → `LFloat`, **still-polymorphic `Num a` → `fromInt n`
  (dict-dispatched)** so it honors Float at runtime. Locked scope (§0): **integer literals only**
  (no `Fractional`; `1.0` stays `Float`), patterns stay `Int`.
  - **Soundness hole found by verification + closed:** an interim version elaborated a polymorphic
    literal to a static `VInt`, so `inc 2.5` typechecked but panicked at runtime; the `fromInt`-routing
    fix (`e7031e6`/`183b7b4`) makes a surviving-polymorphic `Num` literal dispatch through the
    enclosing `Num` dict, like `core.mdk`'s `fromInt 0`.
  - **Pre-existing emitter gap #11 EXPOSED + closed (Gap E / C4 residual, `a8b95d7`):** the native
    emitter seeded a poly-`Num` param as `LTNum` (→ runtime `@mdk_num_*`) only when the fn had an
    explicit signature; an *unannotated* poly-`Num` fn at Float (`dbl x = x + x`) defaulted to
    `LTInt` → integer `add` on the Float box → silent garbage on `medaka build`. Fixed by seeding
    `LTNum` for any unannotated arith-used param + a `reservedCtorsOfType` fallback for the
    List/Option/Result/Ordering Foldable-dispatch sibling. Fixpoint C3a/C3b held byte-for-byte.
  - **Soak found 3 more native/oracle divergences (all closed) — #11 was bug-dense:** (3) native
    `check` accepted `g = f "hello"` (`f : Num a => a -> a`, a concrete `Num String` obligation at a
    let-binding) → typechecked then crashed; the selfhost constraint tracking was fused with the
    dict/emit machinery and empty on the plain check path — fixed with always-on
    `schemeObligationsRef`/`checkCallObligations` mirroring the oracle's `is_concrete` (`68d9da1`).
    (4) two typecheck differential gates went blind (goldens from a no-prelude probe that #11's
    `1`→`fromInt 1` breaks) — re-rooted onto the prelude-aware oracle (`bee51ba`, test-only).
    (5) native didn't apply **value-level** `Num` defaulting (`nums = [1,2,3]` → native `List a`
    vs oracle/§0.2 `List Int`) — the no-prelude driver wasn't recording the literal's `Num`
    obligation at all; fixed + a specialized default-method-body type error (`4fc5f47`/`18176ea`).
    **Native and the OCaml oracle now fully agree; all diff gates 0-failing, fixpoint C3a/C3b YES.**
  - **Tracked follow-up (capture-infra footgun):** `capture_goldens.sh tc` corrupts literal-bearing
    fixtures NOT in `PRELUDE_DEP_TC` (poly_let, index_default, effects, records, signatures,
    missing_field, unknown_field_create) to `Unbound variable: fromInt` (sourced from the no-prelude
    `tc_probe`). Goldens are currently correct; the trap only bites on recapture. Fix = widen
    `PRELUDE_DEP_TC` to all prelude-dependent literal fixtures. Low urgency, do before the next bulk
    `tc` recapture.
  - **Remaining (optional cleanup):** revert the `sum`/`product` `fromInt 0/1` workaround in
    `core.mdk` to literal `0/1` — **NOT safe** (the OCaml oracle's `fromInt`-routing misses the
    point-free seed position → it panics on Float while native is correct; see memory
    `project_oracle_fromint_pointfree_gap`). Keep the `fromInt` form. Closed as won't-do.

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

- **Phase 148 — ✅ DONE (2026-06-16, `7d755a9`, both compilers) — diagnose duplicate / non-contiguous top-level bindings.**
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

- **Phase 150 — ✅ DONE (2026-06-16, `5d11e77`, both compilers) — better error for `do` used on a non-monad.** Implemented via a transparent `EDoOrigin loc expr` node (desugar wraps the lowered do-chain; typecheck raises `DoRequiresMonad` on a non-monad shape). Using `do`
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
  self-hosted emitter (`selfhost/entries/llvm_emit_modules_main.mdk`, run as a subprocess
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
