# Stage 2 backend architecture — bytecode VM first, or straight to LLVM?

Status: **design proposal** (no code yet). Decides the *shape* of Stage 2 (the
North star's native-codegen stage; see [`../PLAN.md`](../PLAN.md) §"Stage 2 — LLVM
backend"). Companion to [`README.md`](./README.md) §Performance and
[`PERF-NOTES.md`](./PERF-NOTES.md).

Stage 1 is done: a Medaka-written front-end (lex → parse → desugar → resolve →
mark → typecheck → exhaust) plus a tree-walking interpreter (`eval.mdk`), all
running on the OCaml reference and validated stage-by-stage byte-for-byte. The
self-hosted compiler processes its own source. Stage 2 makes it emit fast code.

## The central question

> **Option 1 — Bytecode interpreter first, LLVM later.** Introduce a Core IR +
> bytecode VM as a "Stage 1.5" between today's tree-walker and a native backend;
> port to LLVM afterward.
>
> **Option 2 — Straight to LLVM, no intermediate bytecode step.**

The README records the bytecode option as a hypothesis with a strong claim
attached (`README.md:772`):

> Bytecode VM as a "Stage 1.5" … removes per-node AST re-dispatch, gets lexical
> addressing for free, and **its Core IR is largely the IR LLVM wants (so it's an
> on-ramp, not throwaway).**

This doc treats that claim as a hypothesis to test against *this* codebase, not a
given. The conclusion (recommend Option 1, conditionally) is reached on the
evidence below, and the strongest argument turns out **not** to be the one the
README leads with.

---

## What the codebase already provides (the ground truth)

Three facts about the current tree-walker and elaborated AST drive the whole
analysis. All are in the self-hosted source.

**1. Execution is per-node AST dispatch over a by-name environment.**
`eval : EvalEnv -> Expr -> <Mut> Value` ([`eval.mdk:610`](eval.mdk:610)) matches
on the `Expr` constructor for every node, every time it is reached. The
environment is a stack of assoc-list frames —
`EvalEnv (List (List (String, Ref Value)))` ([`eval.mdk:51`](eval.mdk:51)) — and
every `EVar` is a linear frame walk with string `==` per binding
([`lookupFrames`, `eval.mdk:231`](eval.mdk:231);
[`lookupFrameCell`, `eval.mdk:253`](eval.mdk:253)). The OCaml reference
interpreter has the same shape; its assoc-list→Hashtbl env rewrite was the single
biggest perf win of the overnight session (`PERF-NOTES.md` commit `f06727c`,
~10–30× across harnesses), but that only swapped the *data structure* for by-name
lookup — it is still by-name.

**2. Dispatch is already elaborated into explicit, routed nodes.** The typed
pipeline rewrites method/constrained-function occurrences into two nodes that
carry a *resolved* dispatch decision:

- `EMethodAt String (Ref Route)` ([`ast.mdk:141`](ast.mdk:141)) — a
  return-position method occurrence, with a route the typechecker fills.
- `EDictAt String (Ref (List Route))` ([`ast.mdk:146`](ast.mdk:146)) — a
  constrained-function occurrence, one route per `=>` constraint.
- `Route = RNone | RKey String | RDict String` ([`ast.mdk:34`](ast.mdk:34)):
  `RKey` is a concrete impl head tag; `RDict` reads a named dict parameter at
  runtime.

The routes are computed in `typecheck.mdk` (`elaborate`/`elaborateDict`
[`:1175`](typecheck.mdk:1175); `resolveSite` [`:1266`](typecheck.mdk:1266)), and
the tree-walker consumes them in three short arms — `narrowMethod` /
`applyDicts` / `dictPass` ([`eval.mdk:618-621`](eval.mdk:618), and
[`narrowMethod`/`applyDicts`, `eval.mdk:506-558`](eval.mdk:506)). **This is
already a dictionary-passing IR in all but name.** PLAN Stage 2's "dictionaries
explicit … the existing elaboration already inserts `EMethodRef`/`EDictApp` —
that is the foundation" (`PLAN.md:204-208`) is describing nodes that exist today.

**3. The Maranget pattern-matrix analysis is already ported** — `specialize` /
`default` / `head_ctors` / `useful` in `exhaust.mdk` (the guard-coverage pass).
A decision-tree match compiler is driven from exactly this analysis.

The performance picture is equally concrete (`PERF-NOTES.md`, instrumented, not
guessed): after the env-Hashtbl win and the string-build O(n²) fix, the dominant
remaining interpreter cost is by-name env lookup — **~28% of eval, 49.7M
string-compares marking `parser.mdk`, avg frame depth 2.80, 74% local hits**
(`PERF-NOTES.md:140`, `:394-411`). The fix named everywhere is **lexical
addressing**: resolve assigns each `EVar` a `(frame, slot)` address; lookup
becomes array indexing. It is "the single most promising un-attempted lead,"
parked for a supervised session because it threads `resolve.ml + ast.ml +
eval.ml`. Note carefully: **resolve emits no slot today** (`grep` for
`slot`/`frame`/`index` in `resolve.mdk` is empty) — the `(frame,slot)` hook does
not yet exist anywhere.

---

## Axis 1 — Throwaway vs. on-ramp

Decompose a bytecode VM into the artifacts it forces you to build, and ask which
survive a later LLVM port.

| Artifact | Reused by LLVM? | Notes |
|---|---|---|
| Lexical addressing `(frame,slot)` in resolve | **Yes, fully** | LLVM needs the same analysis for closure-env field offsets / `alloca` slots. The resolve-pass work is backend-neutral. |
| Decision-tree match compilation (from Maranget) | **Yes, the tree** | A decision tree is a backend-neutral transform; bytecode emits `SWITCH`/`TEST_TAG` leaves, LLVM emits `switch`/`br`. Only leaf emission differs. Half-built already in `exhaust.mdk`. |
| Dict/dispatch *routing* (`RKey`/`RDict`, who supplies the dict) | **Yes, fully** | Already done in `typecheck.mdk`; both backends consume the routed `EMethodAt`/`EDictAt`. |
| Core IR design (desugared, typed, dicts explicit, lexically addressed) | **Yes** — but *shared regardless* | You design this for LLVM whether or not a VM exists. It is not a *product of* the bytecode step. |
| Runtime dict *representation* (flat `VDict String` tag, [`eval.mdk:47`](eval.mdk:47)) | **Partly** | A VM can keep the flat string-tag dict; LLVM wants a real dict struct / vtable pointer. Routing reused, representation rewritten. |
| **Bytecode ISA + the VM dispatch loop** | **No** | This is the genuinely-discarded part. |

So the README's "on-ramp, not throwaway" is **substantially true but mis-attributed**.
The reused artifacts (lexical addressing, decision trees, routing) are reused
because they are *Core-IR-level passes*, not because they are *bytecode*. The
bytecode's own contribution — the ISA and the interpreter loop — is the throwaway
part. The phrase "its Core IR is largely the IR LLVM wants" is only true under a
discipline the README leaves implicit:

> **Design principle: Core IR is backend-neutral and lives *above* the ISA.**
> Core IR → bytecode is a *lowering*, not an identity. If you let the IR *be* the
> stack/register bytecode, LLVM has to climb back out of it and the step becomes a
> detour. Keep the throwaway part (ISA + VM loop) cleanly below the reused part
> (Core IR + its passes), and the on-ramp claim holds. This is the load-bearing
> condition on recommending Option 1.

**Verdict:** on-ramp, *conditionally* — the IR-and-passes work transfers; the
VM-loop work does not; the condition is keeping the IR above the ISA.

## Axis 2 — Effort, risk, and differential testability

This is where the project's own methodology breaks the tie, and it is specific to
*this* codebase, not a generic VM-vs-LLVM argument.

**The whole project is differential testing against the OCaml reference,
byte-for-byte, per stage.** Every stage has an oracle (`dev/lextok.exe`,
`dev/astdump.exe`, `dev/diagdump.exe`, `dev/tc_probe.exe`, `dev/eval_probe.exe`)
and the `=== TOKENS/AST/TYPES/EVAL ===` golden sections. A stage "is done when all
pass." The decisive question for a *backend* is therefore: **what is its
differential oracle?**

**Bytecode VM — the oracle already exists: the tree-walker.** A bytecode VM
consumes the *same elaborated AST / Core IR* the tree-walker consumes and must
produce the same `pp_value` / same stdout. So it drops into the existing
`diff_selfhost_eval*.sh` harness shape with a new `eval_bytecode_main.mdk` entry,
diffed against `eval_modules` / `eval_probe` over the **entire existing fixture
corpus** (`test/eval_fixtures/`, the 16 `=== EVAL ===` goldens, the stdlib + the
selfhost source itself). **Zero new oracle infrastructure**, and crucially the
*first slice* (arithmetic + vars + calls) is testable in isolation — the VM
reuses the host `Value`/GC/externs, so it can run before records/closures/dispatch
exist, exactly the easy-first slicing `eval.mdk` itself used (slices 1→4b).
Intermediate state is diffable too: dump the bytecode, single-step it, compare the
value stack against tree-walker values at call boundaries.

**LLVM — the oracle gap is wide and the gate is late.** You can still diff native
stdout against the tree-walker (the EVAL goldens are stdout). But:

- **No first-slice test.** The smallest runnable native program needs allocation,
  closures, the print externs, and integers — i.e. a memory model, a GC, and a
  re-implemented extern catalog *before a single test runs*. PLAN Stage 2 lists
  exactly these (`PLAN.md:206-214`) and calls them "decision-dense; the real cost
  of going native." There is no analog to "test eval slice 1."
- **Failures are un-localizable.** A wrong byte from the bytecode VM is a bug in
  IR-lowering or the VM loop — both Medaka/OCaml you instrument with the same
  tools. A wrong byte (or segfault, or GC corruption) from LLVM could be in
  lowering, instruction selection, the calling convention, value
  representation/boxing, the GC, the native extern re-implementation, or LLVM
  itself. The diff tells you *that* it is wrong, not *where*; the reference-gap the
  oracle has to span is now the entire native runtime.
- **No intermediate diffability.** A native binary's intermediate state means lldb
  on optimized code, not a value-stack dump.

**Where each surfaces latent self-host compiler bugs.** Porting every Stage-1
stage surfaced real bugs by adding a *new consumer* of the elaborated AST (Phase
134 cross-module dict-passing; Phase 138 recursive-value force; the
`registerVariants`/`EVariantUpdate`/`cell.value` fixes in `check_modules`). A
bytecode VM is another consumer of the same AST: it will surface
elaboration-routing, dict-arity, and `VThunk` force/laziness-ordering bugs — the
*front-end* class, exactly the class still listed open (README §"Still out of
scope", §"Known limits"). It surfaces them **against the cheap tree-walker oracle.**
LLVM surfaces that same front-end class *plus* a new memory/GC/codegen class
*simultaneously and confounded* — you cannot tell which class a failure belongs
to. Whichever backend goes first pays to harden the elaborated-AST contract that
*both* backends depend on; doing it against the tree-walker is the cheap place to
pay.

**Relative cost.** `eval.mdk` is ~1538 lines. A Core IR → bytecode compiler + VM
loop reusing the host `Value`/externs is plausibly the same order (~1.5–2.5k
lines), all testable against the existing oracle. The LLVM path's *first runnable
artifact* sits behind the full `PLAN.md:206-214` list (memory model, GC, runtime
re-implementation of the entire extern catalog incl. Unicode via `uucp`, calling
convention, FFI). Bytecode-first reaches a tested, runnable artifact for strictly
less upfront work, and most of that work is reused.

**Verdict:** decisively favors bytecode-first, on *methodology fit* — the project's
core competency (per-stage differential testing) amplifies a bytecode VM and is
largely squandered by LLVM-first.

## Axis 3 — Performance: what each actually buys, and does the win need LLVM?

The README frames the ceiling: by-name env lookup is ~28% of eval now that the
string-build quadratic is gone, and a bytecode VM "gets lexical addressing for
free." Test it.

**The #1 measured lever does not require LLVM — or even a bytecode VM.** Lexical
addressing is a resolve-pass + env-representation change. It is capturable in the
*tree-walker itself* (the parked supervised rework), in a bytecode VM (which can't
emit `LOAD_LOCAL slot` without it, so gets it for free), and in LLVM. So the
single biggest interpreter win is **orthogonal to this whole decision.** That
reframes the perf case sharply:

- A **bytecode VM's** *unique* perf contribution beyond "lexical addressing in the
  tree-walker" is removing per-node AST re-dispatch (the `match` on `Expr` at
  [`eval.mdk:610`](eval.mdk:610) runs for every node, every visit), enabling
  compiled decision-tree matches, and confirming static dispatch (routes resolved
  at elaboration aren't re-searched in `VMulti` at runtime). Real, structural, and
  *all three transfer to LLVM* — but a more modest increment than "lexical
  addressing" alone. It does **not** remove per-opcode interpretation overhead,
  boxing, or GC pressure.
- **LLVM** removes interpretation entirely (native instructions), and unlocks
  unboxing, monomorphization, and register allocation — a much higher ceiling, but
  gated behind the entire native runtime.

The honest consequence: **bytecode-first forfeits little perf.** It captures the
interpretation-structural tier early and cheaply; the lexical-addressing win is
captured on *either* path (and should be captured regardless); only the
native-execution tier waits for LLVM, and that tier was always the expensive,
deferred-by-design part (`PLAN.md:195-217`).

A blunt corollary worth stating because it keeps the recommendation honest: **if
pure throughput-sooner were the only goal, the cheapest move is lexical addressing
in the tree-walker, not a whole VM.** The bytecode VM therefore justifies itself
primarily as an *IR + on-ramp + observability* play (Axes 1–2), with perf as a
secondary, transferable benefit — not as a perf play in its own right. Anyone
arguing Option 1 on raw speed alone is overselling it.

## Axis 4 — Self-hosting interaction: what each needs closed first

Both backends must eventually compile the self-host compiler itself, and the
self-host source is favorable: it uses **only `RKey` return-position dispatch** —
every site is at a concrete type (the `Parser` monad, no `=>` constraints,
`README.md:660`). So:

- **Bootstrap minimum (either backend):** `RKey` return-position dispatch + the
  untyped per-module-frame execution semantics `eval_modules` already implements.
  The full `=>`-dictionary-passing system is **not required to compile the
  compiler.** A bytecode VM needs exactly what `eval_modules` does today.
- **Arbitrary-program completeness (either backend):** the front-end gaps PLAN /
  README flag as still open feed *whatever* consumes the elaborated AST.
  Inferred (unsignatured) constraints and **prelude dict-passing** (`when`/`unless`'s
  `pure`, incl. the higher-kinded constraint var) are now **DONE** (`README.md`
  "Dictionary passing"); the remaining residuals are method-level-constraint
  dicts (`foldMap`'s Monoid), instance-`requires` dicts, and
  **nested/structured (non-flat) dictionaries** (`README.md:711-716`). The current
  runtime dict is a flat `VDict String` ([`eval.mdk:47`](eval.mdk:47)) — single
  level only. LLVM's "dictionaries explicit" Core IR forces the structured-dict
  question; a VM can defer it (keep the flat tag) and still run everything the
  bootstrap needs.
- **Effect propagation** is fully ported (Phase 146 selfhost mirror, 2026-06-06):
  the self-hosted typechecker now does open-row inference, propagation, escape, and
  laundering checks — no longer annotation-only. Both backends *erase* effects at
  runtime, so this blocks neither's execution — but a "frozen Core IR"
  (`PLAN.md:200`) should still define how effect-polymorphic code is *represented*
  even when erased.

**Verdict:** neutral between the options on *what must close* — both need the same
gaps closed for arbitrary programs, neither needs them for the RKey-only
bootstrap. The asymmetry is *when and against what oracle* you close them, which is
Axis 2: bytecode-first closes them against the tree-walker and hands LLVM a
validated front-end; LLVM-first debugs them confounded with native-runtime bugs.

## Axis 5 — Sequencing and the migration story

**Bytecode-first → LLVM.** If Core IR is the shared, serializable codegen input
(the discipline from Axis 1), the bytecode VM and LLVM are *sibling consumers* of
it. Migration = swap the consumer. The lexical-addressing resolve pass, the
decision-tree match compiler, and the elaboration routing are reused; the ISA and
VM loop retire. The VM has, by then, *executed* the IR over the whole corpus —
proving the IR is semantically complete and correct — so it hands LLVM a
battle-tested IR **and a second oracle**: when a native program misbehaves, the
single-steppable VM localizes whether the bug is in the (shared, already-trusted)
front-end/IR or in the (new) native lowering/runtime. That second oracle is
precisely the localizing instrument LLVM-first lacks. The bounded, known throwaway
is the ISA + loop.

**Straight-to-LLVM.** You skip the build-then-discard VM loop and reach native
sooner *if everything goes right*. What is lost is intermediate observability: you
design Core IR on paper and first discover whether it is right when native codegen
misbehaves — confounded with memory/GC/runtime bugs, with no second oracle to
disambiguate. You keep differential testing for the (done) front-end stages, but
lose the per-slice execution gate that carried the whole project this far.

**The risk that makes Option 1 a detour, and its mitigation.** The failure mode is
the VM becoming a *destination* — over-investing in VM-only optimizations (inline
caches, superinstructions, threaded dispatch, a JIT) that don't transfer.
Mitigation, stated as policy: treat the VM as a *correctness + observability + IR-
validation* tool; time-box its optimization to the **structural** wins that
transfer (lexical addressing, decision-tree matches, static dispatch) and
explicitly build **no** VM-only micro-opts. The on-ramp stays an on-ramp only if
you do not pave it into a parking lot.

---

## Recommendation — Option 1 (bytecode first), conditionally

Build a Core IR + bytecode VM as Stage 1.5, then port to LLVM — **subject to two
conditions** that convert the README's claim from aspiration into fact:

1. **Core IR is backend-neutral and lives above the ISA.** Bytecode is a lowering
   target, never the IR. This is what makes the step an on-ramp instead of a
   detour (Axis 1).
2. **Capture lexical addressing in resolve *first*, before the VM.** It is the #1
   measured lever (Axis 3), it is backend-independent, it is the `(frame,slot)`
   hook *both* backends need and that **does not exist anywhere yet**, and it is
   validatable output-identical on the tree-walker. Doing it first means the Core
   IR is *born* lexically addressed.

The recommendation rests on the project's own methodology, not on generic
preference: differential testing against the reference is this project's core
competency, a bytecode VM has a perfect pre-existing oracle (the tree-walker) and
slots into the existing harness shape with zero new infrastructure, and it closes
the open front-end/dict/effect gaps in the cheap setting before LLVM inherits
them. Perf is a *secondary*, fully-transferable benefit — the case does not rest
on it.

**When Option 2 would be right instead** (stated to keep this non-foregone): if the
team had deep LLVM/runtime expertise making the VM-loop pure overhead; if
native-tier throughput were needed *now* and interim VM speed were worthless; or
if Core IR were already validated by something else. None hold here — which is why
the methodology is the tiebreaker.

---

## Staged, differentially-testable plan for Option 1

Mirrors the Stage-1 cadence: easy-first slices, each gated byte-for-byte against a
reference. The reference is the tree-walker (`eval_modules` / `eval_probe` and the
`=== EVAL ===` goldens) unless noted.

**2.0 — Observability + lexical addressing (backend-independent; do first).**
- Add the cheap observability `PERF-NOTES.md` already asks for: per-phase timing +
  an allocation counter, to attribute cost rather than guess.
- Land the parked `(frame,slot)` rework: `resolve.mdk` emits a lexical address on
  each `EVar`, `eval.mdk` indexes array frames. Must preserve `VThunk` forcing
  ([`eval.mdk:238`](eval.mdk:238)), the `FTable` globals, and Phase-112
  `lookup_method`'s deliberate shadow-bypass.
  - **EMIT half DONE (2026-06-05).** `ast.mdk` gained `data Addr = ALocal Int Int
    | AGlobal` and a new node `EVarAt String Addr` (a *separate* node rather than
    the "new optional field on `EVar`" first sketched here — a field changes all
    125 `EVar` sites across 9 files incl. eval/parser; the separate node confines
    the change to `ast.mdk` + `resolve.mdk`). `resolve.annotateProgram` (exported,
    intentionally **unwired**) rewrites `EVar n` → `EVarAt n addr` with a framed
    scope mirroring `EvalEnv` exactly. Every existing golden is byte-identical (the
    pass is uncalled; the node reaches no dump). The address model is empirically
    verified against eval's current frames.
  - **CONSUME half — the supervised rework that remains.** Add an `EVarAt` arm to
    `eval.mdk` (array-frame indexing) preserving VThunk + the shadow-bypass; wire
    `annotateProgram` into the typed eval pipeline; switch frames to arrays.
- **Gate:** every `=== EVAL ===` golden byte-identical on the tree-walker (output
  unchanged — this is a representation change only). **Measure** the predicted
  ~28%/49.7M-compare win. This is the supervised rework `PERF-NOTES.md` flags; it
  belongs here because the Core IR must inherit slots.

**2.1 — Core IR definition + lowering (no new execution engine yet).**
- Define the serializable Core IR: desugared, typed, effects erased, dictionaries
  explicit (the `Route`/`EMethodAt`/`EDictAt` decisions, made structural),
  decision-tree matches (from the `exhaust.mdk` Maranget analysis), lexically
  addressed (from 2.0). Keep it *above* any ISA (Axis-1 discipline).
- Write `elaborated-AST → Core IR` lowering.
- **Gate (the net-new-IR oracle problem):** there is no OCaml reference for Core IR
  — it is new. So validate by *re-evaluation*: a trivial Core-IR tree-walker
  evaluates the lowered IR; diff its stdout against the AST tree-walker over the
  whole corpus. Core IR is correct iff evaluating it matches evaluating the AST —
  the same "AST→AST validated by re-running" shape desugar/mark used.
  - **SLICE 1 DONE (2026-06-05).** New files: `core_ir.mdk` (the IR type),
    `core_ir_lower.mdk` (`lower`/`lowerProgram` — elaborated AST → Core IR),
    `core_ir_eval.mdk` (the direct Core-IR tree-walker `ceval`/`cevalProgram`),
    `core_ir_main.mdk` (driver: parse → desugar → `annotateProgram` → lower →
    eval). Gate: `test/diff_selfhost_core_ir.sh` diffs `pp_value` against
    `dev/eval_probe.exe` (the AST tree-walker) over the 9 prelude-free engine
    fixtures in `test/eval_fixtures/` the slice covers — **9/9 byte-identical**.
    Engine core covered: literals, lexically-addressed vars, application,
    lambdas, let/letrec/let-groups, match (+guards, fall-through), if, primitive
    binops, unary ops, tuples, lists, ADTs, blocks, externs, single-/multi-clause
    recursion. The Core-IR evaluator REUSES eval.mdk's host runtime (`Value`,
    env, `apply`/dispatch/fall-through, `matchPat`, externs, `pp_value`) — the
    only eval.mdk change is one additive `Value` variant `VClosureF EvalEnv
    (List Pat) (EvalEnv -> <Mut> Value)` (the host-fn closure the IR evaluator
    builds, so multi-clause/guard fall-through run the SAME `VMulti`+
    `VFallthrough` path) plus the helper `export`s it imports; all existing eval
    harnesses stay byte-identical. Axis-1 discipline honoured: the IR lives above
    any ISA, and the surface→primitive collapse is real — `&&`/`||`→`CIf`,
    `|>`→`CApp`, `>>`/`<<`→`CLam`, type annotations erased, the typechecker's
    mutable `Ref Route` dispatch cells *read out* into immutable `CMethod`/`CDict`.
    Lexical addressing is wired: `annotateProgram` (2.0's EMIT half) rewrites
    every `EVar`→`EVarAt`, so each `CVar` carries a real `Addr` (empirically
    confirmed — panicking the plain-`EVar` lowering arm still passes 9/9). The
    slot-indexing *consume* half is still 2.0's parked rework, so `ceval` resolves
    by name; the addresses ride along unconsumed, exactly as `EVarAt` does in the
    tree-walker.
  - **SLICES 3 & 5 DONE (2026-06-05).** Slice 3 (records / refs / arrays /
    ranges / index / slice / blocks) and slice 5 (typeclass dispatch) are in
    `ceval`. Slice 3's `ceval` arms reuse `eval.mdk`'s value-level helpers
    (`evalIndex`/`evalSlice`/`evalRange`/`evalRecordUpdate`/`evalField`/…) verbatim
    — they only thread `ceval` over sub-expressions and hand the Values to the
    shared host runtime. Slice 5 lowers each impl-method clause + interface
    default into a Ty-free `CImplEntry` (tag / dispatch positions / specificity
    score reused from `eval.mdk`'s `declImplEntries`), and `cevalProgram` installs
    them as the same arg-tag-dispatched `VMulti`s the AST walker builds (via the
    reused `coalesceImpls`); the `CMethod`/`CDict` arms narrow return-position
    routes on the typed path. The gate now spans four corpora — engine (16),
    prelude (5), list (2), typed (2: the only one driving `CMethod` / RKey
    return-position dispatch) — all byte-identical to the AST tree-walker via the
    new `core_ir_prelude_main.mdk` / `core_ir_typed_main.mdk` drivers and
    `test/diff_selfhost_core_ir{,_prelude,_list,_typed}.sh`. Reuse discipline: the
    only `eval.mdk` change across slices 1/3/5 is the additive `VClosureF` variant
    + new `export`s; no runtime forked.
  - **SERIALIZER + ROUND-TRIP DONE (2026-06-05).** `core_ir_sexp.mdk` —
    `cprogramToSexp : CProgram -> String` (and all sub-serializers: `cexprSexp`,
    `cbindSexp`, `ctreeSexp`, `cheadSexp`, `cimplEntrySexp`, …). Lossless structural
    S-expression format: every `CVar` carries its `Addr`, every `CMethod`/`CDict`
    carries its `Route`, every `CImplEntry` carries its tag/iface/positions. The
    companion deserializer `core_ir_sexp_parse.mdk` — `parseCProgram : String ->
    CProgram` — tokenizes and pattern-matches every tagged form back to typed ADTs.
    Two new gates: `test/diff_selfhost_core_ir_sexp.sh` (snapshot: 18 golden
    `.sexp` files in `test/core_ir_sexp_fixtures/`, regenerable) and
    `test/diff_selfhost_core_ir_roundtrip.sh` (the real "frozen IR is faithful"
    gate: lower → `cprogramToSexp` → `parseCProgram` → `cevalMain` → diff vs
    `eval_probe`; **18/18 byte-identical**). A deserialized `CProgram` evaluates
    identically to the freshly-lowered one — the serialization is semantics-faithful.
    This is the LLVM-contract input: an LLVM backend can consume the sexp file
    without touching the Medaka runtime or any in-memory state.

**2.2 — Bytecode compiler + VM, slice by slice.** Compile Core IR → bytecode; the
VM interprets it reusing the host `Value` ([`eval.mdk:18`](eval.mdk:18)),
externs, and GC. Slices mirror `eval.mdk`'s own progression:
1. ✅ **DONE (2026-06-05)** arithmetic + variables (slot-indexed) + application;
2. ✅ **DONE (2026-06-05)** `match` via compiled decision trees;
3. ✅ **DONE (2026-06-05)** ADTs / records / refs;
4. ✅ **DONE (2026-06-05)** closures + letrec + `VThunk` laziness (replicate
   force-on-first-lookup memo exactly — a mismatch is a localizable diff);
5. ✅ **DONE (2026-06-05)** typeclass dispatch from the elaborated routes (`RKey`
   narrow, `RDict` forward — port the `narrowMethod`/`applyDicts` logic to opcodes);
6. ✅ **DONE (2026-06-06)** multi-module (`eval_modules` per-module-frame semantics).
- **Gate per slice:** `eval_bytecode_main.mdk` output byte-identical to the
  tree-walker over the existing fixtures — the exact `diff_selfhost_eval*.sh`
  harness shape, no new oracle. **Current: 18/18, 0 deferred (~1.5s).**
- **Capstone DONE (2026-06-06):** the VM runs the self-hosted lexer stage through
  `eval_bytecode_modules_main.mdk` and reproduces `selfproc_lex_probe.mdk` output
  byte-for-byte against the OCaml oracle. Harness: `test/diff_selfhost_bytecode_selfproc.sh`
  (3/3 ok — 1 real lex-probe pass + 2 documented expected-gaps for parse/tc probes
  that require return-position dispatch, scoped to §2.3). Performance measured
  intra-process via `vm_perf_modules_main.mdk` (min-of-3 on the lex probe):
  tree-walker 0.240s, bytecode VM 0.657s → **2.74× slower** under double
  interpretation. The predicted structural win (no AST re-dispatch + O(1) slots +
  compiled matches) does not materialize under double interpretation; it will
  when §2.4 emits native code for the VM loop. See `PERF-NOTES.md` §"§2.2 Capstone".
  **Policy:** no VM-only micro-opts (Axis 5) — the capstone confirms this is a
  correctness + IR-validation exercise, not a performance play.

**2.3 — Close the front-end gaps the VM surfaces.** Harden the elaborated-AST / IR
contract LLVM will inherit: dict-passing residuals (prelude constrained fns,
nested/structured dicts beyond the flat `VDict String`), and the Core IR's
representation of erased effect-polymorphism. Each fix validated against the
tree-walker oracle — the cheap setting, before any native runtime exists.

Concrete §2.3 items (surfaced by the §2.2 capstone harness,
`test/diff_selfhost_bytecode_selfproc.sh`):

- ✅ **DONE (2026-06-06) — Typed multi-module bytecode VM path** —
  `eval_bytecode_typed_modules_main.mdk` (the `eval_typed_modules_main.mdk`-analog
  for the bytecode VM): loads → `elaborateModules` (route-stamping) → `annotateProgram`
  per module → `bcEvalModulesOutput`. All three selfproc probes (lex/parse/tc) now
  pass byte-for-byte through the typed bytecode VM. This also required adding
  `CVariantUpdate` to the Core IR (lowering `EVariantUpdate` — named-field constructor
  update syntax used in `typecheck.mdk`'s `DImpl`/`DInterface` update clauses) through
  the full pipeline: `core_ir.mdk` (new `CVariantUpdate String CExpr (List CField)` node),
  `core_ir_lower.mdk` (lowering + `ctorFieldOrdersRef` set by `lowerProgram`),
  `core_ir_eval.mdk` (`ceval` arm + `ctorFieldOrdersRef` set in `cevalModules`),
  `bytecode.mdk` (`IVariantUpdate` opcode + `ctorFieldOrdersRef` set in `bcEvalModules`),
  `core_ir_sexp.mdk`/`core_ir_sexp_parse.mdk` (serializer/deserializer). Field order
  (needed to reconstruct `VCon` positionally from named updates) is collected once
  from `allDecls` before lowering via `eval.ctorFieldOrdersRef` (a global ref, set in
  `<Mut>` context — reads are pure so `lower : Expr -> CExpr` stays pure).
  Gate: `test/diff_selfhost_bytecode_selfproc.sh` §2.3 section — 3/3 typed VM passes.
- ✅ **DONE (2026-06-06) — Dict-passing corpus through typed bytecode VM** —
  `eval_bytecode_typed_dict_main.mdk` (the `eval_dict_main.mdk`-analog for the
  bytecode VM): desugar → `elaborateDict` (typecheck stamps routes + dict_pass
  prepends leading dict params) → `lowerProgram` → `bcEvalOutput`. All 17
  `test/eval_dict_fixtures/` pass byte-for-byte against the OCaml oracle. This
  required fixing the Core IR lowering of `EMethodAt`: `lower (EMethodAt ...)` was
  dropping `implRef` (instance-`requires` element dicts, Phase 83/84) and
  `methodRef` (method-level constraint dicts, Phase 69.x-e). The fix extends
  `CMethod String Route` → `CMethod String Route (List Route) (List Route)` (adding
  `implRoutes`/`methRoutes`), updates lowering, `ceval`/`step` (which now mirror the
  tree-walker's `methodAtNarrow + applyDicts(methRoutes) + applyDicts(implRoutes) +
  applyValues(fwdReqs)` chain), sexp serializer/parser, `llvm_emit`'s ctag, and
  exports `methodAtNarrow`/`applyValues` from `eval.mdk`.
  Gate: `test/diff_selfhost_bytecode_eval_dict.sh` — **17/17**. Also: `diff_selfhost_eval_dict.sh`
  still **17/17**, `diff_selfhost_bytecode_selfproc.sh` still **6/6**.
- **Erased effect-polymorphism in Core IR** — a "frozen Core IR" should define
  how effect-polymorphic code is *represented* after erasure (Phase 146 erases
  effects at runtime; the Core IR carries no effect annotations today).

**2.4 — LLVM backend, same Core IR.** Swap consumers: Core IR → LLVM IR. The
lexical addressing (2.0), decision-tree matches, and routing (2.1) are reused; the
ISA + VM loop retire. Build the native runtime slice by slice per `PLAN.md:206-214`
(memory model, closure layout, tagged ADTs/records, GC — Boehm to start, extern
catalog re-implementation, calling convention, FFI). The per-extern disposition
for all 71 primitives (intrinsic / leaf-native / unicode / IO / GC-control /
rewrite-in-Medaka / convert-to-typeclass) — and the argument that the extern ABI
should be proven at the §2.2 VM stage, against the tree-walker oracle, *before*
LLVM — is in [`RUNTIME-DESIGN.md`](./RUNTIME-DESIGN.md).
- **Gate:** native stdout diffed against the tree-walker (EVAL goldens) **and**
  against the bytecode VM — the VM is now a *second oracle* and a single-steppable
  reference that localizes whether a native failure is front-end/IR (shared,
  trusted) or native lowering/runtime (new). This is the disambiguation LLVM-first
  cannot have.
- **Bootstrap closure (the finish line, `PLAN.md:216`):** the self-hosted compiler
  + LLVM backend compiles itself to a standalone native binary.
- **DE-RISKING SPIKE DONE (2026-06-05) — ahead of the strict VM-first ordering, by
  design** (front-loads the riskiest lift; runs fully parallel to the §2.2 VM work,
  uses only the tree-walker oracle). Proves the decided toolchain (EMIT textual LLVM
  IR + shell out to `clang`, no llc/opt, no C++/Rust bindings) end-to-end on the
  *simplest subset only* — the slice-1 equivalent: integer/float arithmetic,
  comparisons, unary `-`/`!`, `let`, `if`, top-level value bindings, a type-directed
  print. **No** closures/functions/ADTs/records/dispatch/GC (out-of-scope nodes
  *panic* rather than mis-lower). New files: `llvm_emit.mdk` (Core IR → textual LLVM
  IR, a sibling consumer of the same Core IR `core_ir_eval`/the bytecode VM consume
  — Axis-1 discipline in miniature), `llvm_emit_main.mdk` (driver: parse → desugar →
  `annotateProgram` → `lowerProgram` → emit, sharing the entire front-end + lowering
  with `core_ir_main.mdk`), `../runtime/medaka_rt.c` (a malloc-and-leak `mdk_alloc`
  + `mdk_print_int/bool/float`; GC deferred — `brew install bdw-gc` is the later
  step). Gate: `test/diff_selfhost_llvm.sh` (emit → `clang <ll> medaka_rt.c` → run →
  diff vs `dev/eval_probe.exe`) over 8 prelude-free scalar fixtures in
  `test/llvm_fixtures/` — **8/8 byte-identical**, including OCaml's trailing-dot
  float rendering (`14.`), `true`/`false`, negatives, and truncating `sdiv`/`srem`.
  Value rep is a **PROVISIONAL** uniform 64-bit tagged word (low-bit-1 immediate
  `Int`, boxed `Float`) — *deliberately* exercising the rep so it surfaces the real
  decision; the tag/box arithmetic lives in the emitted IR (visibly), and the rep is
  revisable in one place (`llvm_emit.mdk` + `medaka_rt.c`). The ratified-by-a-human
  proposal (tagged word vs NaN-box vs boxed-everything, + the `musttail` calling
  convention) it fed is [`RUNTIME-DESIGN.md`](./RUNTIME-DESIGN.md) §8.
- **SPIKE SLICE 2 DONE (2026-06-05) — top-level functions + direct calls.** Extends
  the spike from scalars to top-level functions and saturated direct calls, still
  against the same tree-walker oracle. Each `name p… = …` lowers to
  `define i64 @mdk_<name>(i64 %arg0, …)`; a `CApp` spine with a known-function head
  lowers to `call i64 @mdk_<name>(…)`. **The `musttail` calling convention is now
  exercised, not just proposed:** a function body is emitted in tail position, so a
  *self-recursive* tail call lowers to `musttail call` immediately followed by `ret`
  (self-recursion guarantees the caller/callee prototypes match, which `musttail`
  requires). Empirically TCO-correct under `clang -O0` — a 5,000,000-deep
  tail-recursive `sumTo` returns the right total with no stack growth, where an
  ordinary `call` overflows. **Decisions surfaced (not silently taken):** (1)
  function boundaries are **Int-only** — params/returns are i64 Int words; a
  Bool/Float-typed parameter or result is out of scope (the same static-type-only
  limitation slice 1 already exposes for the print routine, now at the call ABI).
  (2) cross-function tail calls (mutual recursion) stay an ordinary `call` —
  guaranteed-TCO across *distinct* prototypes needs prototype-match checking, a
  later increment. (3) function-body references to top-level *value* bindings
  (globals) are out of scope — fixtures pass globals as call arguments instead.
  Value rep is **unchanged** (no rep edit — the calling convention rides on the
  existing uniform i64 word). Gate now spans **13/13** fixtures (the original 8 +
  5 function fixtures: `fn_factorial` non-tail self-recursion, `fn_tailsum`/`fn_gcd`
  musttail self-recursion, `fn_mutual` cross-function tail calls, `fn_compose`
  nested non-recursive calls + a value-binding argument). Still **not** the real
  backend: higher-order values / closures / ADTs / records / dispatch / GC remain
  out of scope and panic.
- **SPIKE SLICE 2b DONE (2026-06-06) — Bool/Float function boundaries.** Closes the
  Int-only function-boundary limitation slice 2 documented. Core IR is type-erased,
  so a **two-pass signature inference** recovers each function's parameter and
  return type before its body is emitted (`inferSigs` → `typeOf` + `paramUseTy` in
  `llvm_emit.mdk`): a parameter's type comes from its **first typed use** — an
  `if`-condition or `!` operand ⇒ `Bool`, an arithmetic/comparison operand shares
  its **sibling**'s type (so `x * 2.0` ⇒ `x : Float`, `n == 0` ⇒ `n : Int`), and an
  argument passed to a known function takes that function's parameter type; the
  return type then follows structurally. `typeOf` is the pure, non-emitting twin of
  the type-recovery `emitExpr` already does inline. Two passes settle a
  caller→callee→sibling chain and mutual recursion (the subset has no deeper
  type-flow). With the signature table, a call site reports the **callee's** return
  type (so a Bool-returning function prints `true`/`false`, not as an Int) and a
  function binds each parameter at its inferred type (so a Float parameter
  unboxes/reboxes). **Value rep is UNCHANGED — no rep edit.** Every value is the
  same uniform i64 word at the ABI regardless of type (Int immediate, Bool
  immediate `0`/`1`, Float boxed-pointer-as-i64), so there is **no `define`/`call`
  prototype change and `musttail`'s prototype-match invariant is untouched** — the
  recovered type drives only int-vs-float instruction selection in the body and the
  print routine for a result, not the calling convention. Gate now spans **17/17**
  fixtures (the prior 13 + 4 boundary fixtures: `fn_float_param` Float param +
  Float return, `fn_bool_return` Bool return → `print_bool`, `fn_bool_param` Bool
  param used as an `if` condition, `fn_float_chain` Float param propagating across a
  two-hop call chain). Decisions surfaced (not silently taken): (1) param types are
  **inferred structurally from use**, not threaded from the typechecker — the spike
  re-derives what the erased Core IR dropped, the same structural-recovery posture
  slice 1 used for the print routine; (2) because Bool and Int share the immediate
  encoding, an *Int*-returning function whose body is a comparison would still be
  typed `Bool` here — harmless for the spike (the rep can't yet tell them apart, a
  limitation slice 1 already documents), but a real backend with a distinguishing
  rep must carry the type, not re-infer it. Still **not** the real backend:
  higher-order values / closures / ADTs / records / dispatch / GC remain out of
  scope and panic.
- **SPIKE SLICE 3 DONE (2026-06-06) — ADT constructors + pattern matching.** The
  first **heap-allocated, non-scalar** values, and the first `match`. A constructor
  lowers to a **boxed heap cell** (RUNTIME-DESIGN.md §8.4 "Option A"): a one-word
  header (the constructor name string-hashed to an i64 tag) followed by the field
  words, allocated via `@mdk_alloc` — the slice-1 Float-box path extended to N
  fields; the word carried in registers is the cell pointer (`ptrtoint`, low bit 0,
  disjoint from the immediate-int low-bit-1 encoding). A `match` lowered to a
  `CDecision` decision tree (the same Maranget tree `core_ir_lower` already
  produces) becomes an **LLVM CFG**: each `CTSwitch` tests the focus value's head
  (load tag → `icmp eq` → `br` for constructors; immediate compare for int
  literals) and descends into the matched cell's fields as the new focus columns; a
  leaf re-matches its arm's pattern against the scrutinee (`getelementptr` field
  loads) to bind variables, evaluates the body into an `alloca` result slot, and
  branches to the decision's end block. It mirrors `core_ir_eval`'s
  `cevalDecision`/`cevalTree`/`cevalSwitch` **one-to-one** (value-walk → block-emit),
  reusing the untouched Core IR lowering — the Axis-1 "backends are sibling
  consumers" discipline, now over a structural type. Gate now spans **22/22**
  fixtures (the prior 17 + 5 ADT/match: `adt_option` two-branch `Maybe`, `adt_list_fold`
  recursive fold with an Int field in arithmetic, `adt_nested` two-level `Wrap (Leaf x)`
  occurrence-stack descent, `adt_multi_arm` three-branch switch + `unreachable`
  default, `adt_lit_field` an int-literal `HLit` switch on a field). **Decisions
  surfaced (not silently taken):** (1) **nullary constructors are boxed** (a 1-word
  alloc), where §8.1 says they should be **free/immediate** — a divergence from the
  recommended *native* rep, deferred to the real backend (spike-rep notes below).
  (2) the **i64 string-hash tag** is LLVM-convenient (no ctor→ordinal table) but
  foreshadows neither backend's real tag and carries collision risk; a **dense i32
  ctor-ordinal** would port to both LLVM and WasmGC `br_table` cleanly (deferred).
  (3) the encoding (`ptrtoint`/`inttoptr` i64 words, byte-offset `getelementptr`,
  hash tag) is the **native** physical rep and intentionally NOT WasmGC-portable —
  §8.6 reconciles this (no single physical rep; the **Core IR** is the shared
  portable layer; a WasmGC sibling emitter would use `i31ref` + typed structs).
  **Latent bug surfaced (filed, not fixed — PLAN.md Compiler/language):** a user
  constructor literally named `Cons`/`Nil`/`Unit`/`__tuple__` aliases the built-in
  list/tuple/unit heads in `core_ir_lower.decodeHead` and is mis-decomposed at match
  time — `check` accepts it, the AST walker runs it, but the **Core IR path**
  (`ceval` + both backends) crashes; the fixtures sidestep it with `Node`/`Empty`.

- **Slice 4 — closures + higher-order functions (2026-06-06).** Each `CLam` is
  **lambda-lifted** to a top-level `define i64 @mdk_lamN(i64 %clos, i64 %arg…)`; at
  its site a **boxed closure cell** `{header, code_ptr, captured…}` is allocated
  (the slice-3 ctor alloc reused **verbatim** with "fields" = `[code_ptr,
  capture…]`, so code_ptr is field 0 and capture i is field i+1). The CAPTURED set
  is `freeVars(body) − params` intersected with the live emit env (free names not in
  the env are top-level globals — known fns / ctors — needing no capture). An
  application whose head is **not** a known fn/ctor (a closure-valued param,
  let-binding, returned closure, or immediately-applied lambda) lowers to an
  **indirect call**: load code_ptr from the cell, `call` the loaded pointer passing
  the closure word as the **leading argument** (RUNTIME-DESIGN.md §8.5). A named
  top-level fn used as a **value** is **eta-wrapped** into a captureless static
  closure whose lifted body forwards to `@mdk_<name>`, so every call is uniformly
  indirect (`applyTo double 21` works). The lifted defines accumulate in a side
  buffer (LLVM forbids nested defines) and are appended after `@main` (define order
  is irrelevant). `musttail` self-tail-calls (slice 2) survive unchanged. Gate now
  spans **27/27** fixtures (the prior 22 + 5 closure/HOF: `clo_apply` let-bound
  no-capture lambda, `clo_capture` a fn returning a param-capturing closure,
  `clo_hof` a lambda passed to a HOF and called indirectly, `clo_hof_named` a named
  fn eta-wrapped as a value, `clo_adt` a closure mapped over a user list ADT then
  summed). **Decisions surfaced (not silently taken; spike-rep notes below):**
  (d) the closure cell carries a **one-word header before code_ptr** (matching §8.5
  and reusing the slice-3 ADT cell shape), not code_ptr-at-offset-0 — the real
  backend may drop the never-inspected header. (e) **saturated calls only** — the
  type-erased Core IR can't see a closure's arity at the call site, so the spike
  emits a flat indirect call over the whole spine and relies on controlled fixtures;
  partial application (under-application → residual closure) and over-application are
  out, and the real backend must **carry arity in the cell** (or per-arity apply
  trampolines). (f) captureless named-fn-as-value is eta-wrapped per use; a real
  backend could intern one static closure per top-level fn once arities are carried.
  Still **not** the real backend (at slice 4): arrays / dispatch / GC, the built-in
  list match heads, guarded/range/record-arm patterns, recursive (`CLet True`)
  closures, tuples, records, and Ref remain out of scope and panic. (Records,
  tuples, and Ref added in slice 5a — §2.4a below; built-in list/tuple match heads
  and recursive closures in slice 5b — §2.4a-2 below.)

**2.4a — Slice 5a (RECORDS, TUPLES, MUTABLE REFS).** The three remaining Core-IR
  structural forms added, all lowering via the existing `emitCtorAlloc`/`storeFields`/
  `loadField` verbatim: **Records** become boxed cells with `header = hashName(name)`,
  fields in source declaration order (a scan of `CRecord` nodes at `emitProgram` time
  builds the per-name field-order table so `CFieldAccess` can recover a positional
  index without type information). **Tuples** use the same cell shape with a fixed
  `header = hashName("$tuple")`; tuple destructuring `let (a,b,c) = t` (a `CLet PTuple`
  / `CBlock CSLet PTuple` node) binds elements by `loadField` without touching the
  switch machinery. **Mutable refs** are lowered inline (no new runtime functions):
  `Ref x` → `emitCtorAlloc "$ref" [x]`; `set_ref r x` → `inttoptr` + `getelementptr`
  offset 8 + `store`; `r.value` → `loadField 0`; `Ref`/`set_ref` are intercepted by
  name in `emitApp` before the ctor/known-fn checks. Gate now spans **31/31** fixtures
  (the prior 27 + 4: `rec_build` record creation+field access, `rec_update` record
  update copy+overwrite, `ref_counter` Ref create+read+write×2, `tuple_fst` tuple
  construction + `let (a,_,_) = t` destructuring). **Decisions surfaced (spike-rep
  notes):** (g) records are positional-by-declaration-order — name-keyed
  access at runtime would need a name→offset map; the spike sidesteps this by reading
  the declaration at emit time. (h) tuple header is `hashName "$tuple"` — headerless
  tuples would save one word but break the uniform cell discipline used for tag-testing
  in switches. (i) Ref cells use `@mdk_alloc` (malloc-and-leak) — **the first mutation
  site in the spike**, the first place a GC write barrier would be needed; the real
  runtime must add one on the `set_ref` store path.

**2.4a-2 — Slice 5b (BUILT-IN LIST/TUPLE MATCH HEADS + RECURSIVE CLOSURES).** Three
  decision-tree/closure forms that previously panicked, all reusing the slice-3/4
  machinery: **(1) built-in list heads.** A `match` on `Cons`/`Nil` (or list-literal
  patterns) lowers — via `core_ir_lower.decodeHead` — to `HCons`/`HNil` switch heads
  rather than `HCon`. `emitSwitch`/`emitConChain` now route any constructor-LIKE head
  through one helper, `conHeadInfo : CHead -> Option (String, Int)`, which maps
  `HCon c a → (c, a)`, `HCons → ("Cons", 2)`, `HNil → ("Nil", 0)`, `HTuple n →
  ("$tuple", n)` — i.e. the SAME hashed tag (`hashName`) the constructor/tuple alloc
  site stamps, so construction and match agree by construction. `bindPattern` gains
  `PCons h t` (a 2-field `[head, tail]` extraction) and `PList []` (binds nothing).
  **(2) tuple switch heads.** A multi-arm tuple match yields a `CTSwitch HTuple n`
  head (one branch, all arms being n-tuples), handled identically to a constructor
  test against `hashName "$tuple"` — the `PTuple` leaf binding from slice 5a is
  unchanged. **(3) recursive closures.** A function-`let` (`let f p… = … in e2`)
  lowers to `CLet True (PVar f) (CLam …)`; `emitRecLam` lambda-lifts it like any
  `CLam` but EXCLUDES `f` from the capture set (it is the closure cell itself) and,
  inside the lifted `define`, binds `f → %clos` (the leading closure pointer) so the
  self-call `f …` is an indirect call back into the same cell. Gate now spans
  **35/35** fixtures (the prior 31 + 4: `list_sum` `data … = Cons … | Nil` recursive
  fold, `list_filter` list construct+match across two recursive fns, `rec_local`
  inline recursive function-`let`, `tuple_match` multi-arm tuple match). **Latent
  bug surfaced (PLAN.md):** `decodeHead` keys built-in heads by NAME, so a user ctor
  named `Cons`/`Nil` aliases the built-in head — harmless in the LLVM spike (the
  symmetric hashed-tag discipline above) and in the AST tree-walker, but the Core-IR
  `ceval` path panics (`core_ir_eval.mdk:144`) because it routes `HCons`/`HNil` to
  the built-in `VList` shape. Still **not** the real backend (at slice 5b): arrays /
  dispatch / GC, `HUnit` heads, guarded/range/record-arm patterns, non-empty `PList`
  binding, partial application, and Ref capture remain out of scope and panic.

**2.4b — WasmGC as a planned second backend (the wedge's delivery vehicle).** The
capability-effects wedge ([`../CAPABILITY-EFFECTS.md`](../CAPABILITY-EFFECTS.md) /
[`../CAPABILITY-PLATFORM.md`](../CAPABILITY-PLATFORM.md)) ships on WebAssembly, so
WasmGC is a *planned* sibling backend, not someday-maybe — reached by a **direct
WasmGC emitter** (LLVM targets only linear-memory Wasm, not WasmGC). The discipline
is a **soft pivot**, decided 2026-06-06: LLVM stays the *first* backend (serves the
bootstrap, the general-purpose target, and the cleaner tree-walker-oracle story),
but **WASM's constraints are design inputs to the shared layers NOW** so both
backends implement *identical* semantics — avoiding "one language that is secretly
two":
- **Value representation to the WasmGC intersection** — boxed/nominal, no
  pointer-tagging/NaN-boxing, `i31ref` small ints, `Int` 64-bit logically; LLVM
  matches it, tagging is an LLVM-only opt behind identical semantics
  (`RUNTIME-DESIGN.md` §7.1).
- **Capability/runtime surface parameterized** so native FFI (C ABI) vs. WASM host
  imports/WIT bind *below* identical semantics; native-only powers (threads, raw FS)
  are capabilities the edge target omits, surfaced in types (`RUNTIME-DESIGN.md`
  §6a).
- **Guaranteed tail calls assumed uniformly** (verified below).
- **Threading not baked into core semantics** — WASM edge is single-threaded
  per-instance; offer concurrency (if ever) as a native-only capability, not a core
  assumption.

**Tail-call + WasmGC viability — VERIFIED 2026-06-06.** WebAssembly 3.0 (W3C
standard, Sept 2025) standardizes both tail calls and WasmGC. Tail calls
(`return_call`/`_indirect`/`_ref`) are Baseline across browser engines since
2024-12-11 and on-by-default in **Wasmtime ≥ 22.0** (Cranelift; x86-64/aarch64/
riscv64); WasmGC is complete in **Wasmtime ≥ 27.0** and Baseline in browsers. So
both wedge backends — **V8** (→ Cloudflare Workers, tracks Chrome stable weekly) and
**Wasmtime** (→ Fastly Compute) — support guaranteed TCO matching LLVM `musttail`,
and WasmGC is viable. **Caveat:** confirm the *deployed* engine version per provider
at integration time, and note a since-patched Wasmtime advisory re: tail-calls +
host stack traces. Sources: web.dev (WasmGC/tail-call Baseline, 2024-12-11);
v8.dev/blog/wasm-tail-call; Wasmtime 22.0 & 27.0 release notes (bytecodealliance);
webassembly.org Wasm 3.0 (2025-09-17).

---

### One-paragraph summary

A bytecode VM is a *conditional* on-ramp: its reused artifacts (lexical addressing,
decision-tree match compilation, dict routing) transfer to LLVM because they are
Core-IR passes, not bytecode; only the ISA + interpreter loop are thrown away, and
only if you keep the IR above the ISA. The case for doing it first is not
performance — the #1 measured lever (lexical addressing, ~28% of eval) is
backend-independent and should be captured regardless — but **methodology**: a
bytecode VM is differentially testable against the existing tree-walker oracle,
per slice, byte-for-byte, with zero new infrastructure, and it closes the open
front-end/dict/effect gaps in the cheap setting so LLVM inherits a validated IR
and a second, single-steppable oracle. Straight-to-LLVM reaches native sooner only
if nothing goes wrong, and forfeits exactly the per-slice, localizable validation
that carried Stage 1 to completion.
