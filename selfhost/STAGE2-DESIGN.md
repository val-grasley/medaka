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

- `EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))`
  ([`ast.mdk:182`](ast.mdk:182)) — a return-position method occurrence: the route
  the typechecker fills, plus instance-`requires` and method-constraint dict routes.
- `EDictAt String (Ref (List Route))` ([`ast.mdk:187`](ast.mdk:187)) — a
  constrained-function occurrence, one route per `=>` constraint.
- `Route = RNone | RKey String (List Route) | RDict String | RDictFwd String`
  ([`ast.mdk:38`](ast.mdk:38)): `RKey` is a concrete impl head tag (with nested
  per-instance requires routes); `RDict`/`RDictFwd` read a named dict parameter at
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
  runtime, so this blocks neither's execution — and the "frozen Core IR"
  (`PLAN.md:200`) now **defines** how effect-polymorphic code is represented when
  erased: full erasure, no runtime witness, effect-poly ≡ monomorphic (§2.3,
  DONE 2026-06-07).

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
  harness shape, no new oracle. **Current: 19/19, 0 deferred (~1.5s)** (the
  19th, `effect_poly`, is the §2.3 item-3 effect-erasure regression).
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
representation of erased effect-polymorphism (defined: full erasure, no runtime
witness — see the §2.3 item below). Each fix validated against the
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
- ✅ **DONE (2026-06-07) — Erased effect-polymorphism in Core IR.** The frozen-IR
  contract is **full erasure — no runtime representation**, the opposite of
  typeclass polymorphism. Established empirically, not assumed: effects are
  TYPE-level only (`TyEffect` in `ast.mdk`; `EffRow`/`Effvar` arrows in
  `typecheck.mdk`), never standalone expression nodes, and the language has **no
  runtime effect construct** (no perform/handle/resume — Phase 146 is a
  typecheck-time discipline: open-row inference, propagation, escape, laundering).
  So effects erase WITH types at lowering (`lower (EAnnot e _) = lower e`,
  `core_ir_lower.mdk`), `CExpr` carries no `Ty`/`EffRow` field, and the runtime has
  nothing to witness. **Representation after erasure, frozen:** an
  effect-polymorphic function is represented IDENTICALLY to a monomorphic one — no
  effect node, no effect parameter, no effect-directed dispatch (dispatch is
  type-head directed, so erasure cannot perturb a `Route`). Contrast `=>`
  constraints, which DO carry a runtime witness (`CMethod`/`CDict`); `<e>` rows
  carry none. The contract is documented in the `core_ir.mdk` header (the new
  "EFFECTS FULLY ERASED" bullet beside DESUGARED / PRIMITIVE / LEXICALLY ADDRESSED
  / DICTS EXPLICIT). Gate: `test/eval_fixtures/effect_poly.mdk` — a combinator
  `runTwice : (a -> <e> a) -> a -> <e> a` whose row is instantiated at `<Mut>`
  (a `set_ref` callback) and at the pure row; iterated by all three engine
  harnesses (`diff_selfhost_eval.sh` / `diff_selfhost_core_ir.sh` /
  `diff_selfhost_eval_bytecode.sh`, `FIXDIR=.../eval_fixtures`) so the AST
  tree-walker, the Core IR evaluator, AND the bytecode VM produce byte-identical
  output, proving erasure is semantics-preserving on all three. The Core IR dump
  carries **0** effect tokens. No new IR node (a dead field would contradict the
  Phase-146 erasure design); no typechecker change.

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
  with `core_ir_main.mdk`), `../runtime/medaka_rt.c` (`mdk_alloc` → Boehm `GC_malloc`
  since 2026-06-07, was malloc-and-leak; + `mdk_print_int/bool/float`). Gate:
  `test/diff_selfhost_llvm.sh` (emit → `clang <ll> medaka_rt.c -lgc` → run →
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
  lowers to a **boxed heap cell** (RUNTIME-DESIGN.md §8.4 "Option A") **iff it has
  fields**: a one-word
  header (the constructor's tag — a dense per-type ctor-ordinal composite since
  2026-06-07, `cellTag`; an i64 string-hash through the original slice-3 spike) followed by the field
  words, allocated via `@mdk_alloc` — the slice-1 Float-box path extended to N
  fields; the word carried in registers is the cell pointer (`ptrtoint`, low bit 0,
  disjoint from the immediate-int low-bit-1 encoding). A NULLARY ctor is instead the
  IMMEDIATE word `(cellTag<<1)|1` (no alloc, since 2026-06-07; §8.1). A `match` lowered to a
  `CDecision` decision tree (the same Maranget tree `core_ir_lower` already
  produces) becomes an **LLVM CFG**: each `CTSwitch` tests the focus value's head
  (a constructor head reads the tag via `loadDiscriminant` — branch on the low bit:
  immediate ⇒ `ashr 1`, boxed ⇒ load header — then `icmp eq` → `br`; immediate
  compare for int
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
  surfaced (not silently taken):** (1) ~~**nullary constructors are boxed** (a 1-word
  alloc), where §8.1 says they should be **free/immediate**~~ — **DONE 2026-06-07:**
  the spike now emits nullary ctors as the §8.1 IMMEDIATE word `(cellTag<<1)|1` (no
  alloc), generalising the Bool immediate; a `match` head reads the tag via
  `loadDiscriminant` (branch on the low bit: immediate ⇒ `ashr 1`, boxed ⇒ load
  header), so a type mixing nullary + boxed ctors (Option = None immediate + Some
  boxed) discriminates without dereferencing an immediate. Adversarial fixture
  `test/llvm_fixtures/adt_imm_mixed.mdk` (ordinal-0 nullary + boxed ctor).
  (2) the **i64 string-hash tag** was LLVM-convenient (no ctor→ordinal table) but
  foreshadowed neither backend's real tag and carried collision risk — **RESOLVED
  2026-06-07: the spike now emits the ratified dense per-type ctor-ordinal**
  (`cellTag`, a composite `typeId<<32 | ordinal`; low half is the `br_table` ordinal,
  high half a per-type id retained only for the spike's runtime cross-type arg-tag
  dispatch). Ports to LLVM/WasmGC `br_table`; collisions impossible.
  (3) the encoding (`ptrtoint`/`inttoptr` i64 words, byte-offset `getelementptr`,
  tagged word) is the **native** physical rep and intentionally NOT WasmGC-portable —
  §8.6 reconciles this (no single physical rep; the **Core IR** is the shared
  portable layer; a WasmGC sibling emitter would use `i31ref` + typed structs).
  **Reserved-name aliasing bug (FIXED 2026-06-07 — PLAN.md Compiler/language):** a
  user constructor literally named `Cons`/`Nil`/`Unit` used to alias the built-in
  list/unit heads in `core_ir_lower.decodeHead` and was mis-decomposed at match time
  — `check` accepted it, the AST walker ran it, but the **Core IR `ceval` path**
  crashed. Fixed by having `canonPat` lower the built-in forms to reserved synthetic
  head names (`__cons__`/`__nil__`/`__unit__`) so a user ctor keeps its own name and
  lowers to `HCon`; the fixtures' `Node`/`Empty` workaround was unwound to `Cons`/`Nil`.

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
  in switches. (i) Ref cells use `@mdk_alloc` (Boehm `GC_malloc`) — **the first mutation
  site in the spike**, the first place a GC write barrier would be needed; under Boehm
  the plain store is safe, but a later precise/generational GC must add a barrier on
  the `set_ref` store path.

**2.4a-2 — Slice 5b (BUILT-IN LIST/TUPLE MATCH HEADS + RECURSIVE CLOSURES).** Three
  decision-tree/closure forms that previously panicked, all reusing the slice-3/4
  machinery: **(1) built-in list heads.** A `match` on list-literal / `::` patterns
  lowers — via `canonPat` → `core_ir_lower.decodeHead` — to `HCons`/`HNil` switch
  heads rather than `HCon` (a user ctor named `Cons`/`Nil` keeps its own name and
  lowers to `HCon` — see the reserved-name fix below). `emitSwitch`/`emitConChain`
  now route any constructor-LIKE head
  through one helper, `conHeadInfo : CHead -> Option (String, Int)`, which maps
  `HCon c a → (c, a)`, `HCons → ("Cons", 2)`, `HNil → ("Nil", 0)`, `HTuple n →
  ("$tuple", n)` — i.e. the SAME tag (`cellTag`) the constructor/tuple alloc
  site stamps, so construction and match agree by construction (and `HCons` and a
  user `HCon "Cons"` resolve to the same per-type ordinal, so the spike is byte-identical either way).
  `bindPattern` gains
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
  inline recursive function-`let`, `tuple_match` multi-arm tuple match). **Reserved-name
  bug (since FIXED 2026-06-07 — PLAN.md):** `decodeHead` used to key built-in heads by
  NAME, so a user ctor named `Cons`/`Nil` aliased the built-in head — harmless in the
  LLVM spike (the symmetric hashed-tag discipline above) and in the AST tree-walker, but
  the Core-IR `ceval` path panicked (`core_ir_eval.mdk:151`) because it routed
  `HCons`/`HNil` to the built-in `VList` shape. Now fixed (`canonPat` reserves synthetic
  `__cons__`/`__nil__` head names; user ctors lower to `HCon`), so `list_sum`/
  `list_filter` are byte-identical across all backends. Still **not** the real backend
  (at slice 5b): arrays /
  dispatch / GC, `HUnit` heads, guarded/range/record-arm patterns, non-empty `PList`
  binding, partial application, and Ref capture remain out of scope and panic.

**2.4a-3 — Slice 6 (TYPECLASS DISPATCH).** The largest remaining Core-IR feature
  gap and the one the bootstrap needs: the self-host compiler dispatches
  return-position via `RKey` ([`README.md:57`](README.md)). Two Core-IR nodes lower
  here (no change to `core_ir.mdk` — Axis-1: `llvm_emit.mdk` is a sibling consumer of
  the unchanged IR): `CMethod name route implRoutes methRoutes` (a method occurrence)
  and `CDict name routes` (a `=>`-constrained-function occurrence). Each `Route =
  RNone | RKey String (List Route) | RDict String | RDictFwd String`. **The key
  tractability property:** an `RKey` route is STATICALLY resolved — the typechecker
  already pinned the concrete type head, so the impl is known at COMPILE time and the
  site lowers to a DIRECT call to that impl's lifted `@mdk_impl_<tag>_<method>`, with
  NO runtime tag inspection. `RKey` alone covers the bootstrap. `RDict`/`RDictFwd`
  read a named dict PARAMETER at run time, so they lower to an inline if-chain
  switching on the dict witness word over the method's impls (corpus completeness —
  the dict-passing fixtures). This mirrors `core_ir_eval`'s
  `methodAtNarrow`/`applyDicts`/`narrowMethod` one-to-one, resolving the same routes
  in emitted control flow instead of walking `VMulti` values; `bytecode.mdk`'s
  `IMethod`/`IDict` lower the identical routes. **Spike-rep notes (extending the
  slice-3/4/5 (a)–(i) log):** **(j) dicts** — a dict is a uniform i64 WITNESS word =
  `hashName(impl-head-tag)` (the same djb2 the ADT cell header uses), opaque: it never
  reaches an arithmetic/print site, only an `icmp eq` against an impl's tag. `RNone ⇒
  0`. Nested per-instance requires dicts (a non-empty `RKey _ reqs`) are OUT — the
  one-level fixtures carry none; a non-empty set panics. **(k) impl functions** — each
  tagged impl method (`CImplTagged`, read out of `CProgram`'s impl-entry list, the new
  eighth `Emit` ref) lowers to a top-level `@mdk_impl_<tag>_<method>(params…)` emitted
  alongside the ordinary fn defines (`emitImpls`); a nullary return-position impl
  (`def`/`zero`) is a zero-arg fn the use site CALLs for its value, a parameterized
  impl takes its params; untagged interface defaults (`CImplDefault`, the arg-tag
  fallback) are skipped. **(l) dispatch** — `RKey ⇒` a direct call; `RDict`/`RDictFwd
  ⇒` an inline if-chain comparing the dict witness to each impl's `hashName` tag, with
  an `unreachable` default (the typechecker proves the dict names a real impl). **(m)
  constrained fns** — a `CDict name routes` at a call lowers to a direct
  `@mdk_<name>(dictWords ++ argWords)`; `dict_pass` already gave `name` the matching
  leading dict params, so the constrained fn is an ORDINARY `emitFn` define and only
  the call site is new. **Driver + oracle.** Dispatch needs types, so this slice adds
  a TYPED emit driver (`llvm_emit_typed_main.mdk`: desugar → `elaborateDict`
  route-stamp + `dict_pass` → lower → emit) and a separate gate
  (`diff_selfhost_llvm_typed.sh`) over `test/llvm_fixtures_typed/`. The oracle is NOT
  `eval_probe` — being untyped it leaks the dispatch wrapper (`<impl@Int:7>`); it is
  the TYPED Core-IR tree-walker (`core_ir_dict_pp_main.mdk`, the SAME lowered IR
  ceval'd), so the proven equivalence is `emit→clang→run == ceval` over one typed IR.
  Fixtures are prelude-free (own interface + impls, reduce `main` to a scalar Int) and
  pass ONLY `runtime.mdk`, so `elaborateDict` resolves every route without pulling
  `core.mdk` into the scalar module. **3/3 byte-identical** (`disp_single`
  single-impl `RKey`, `disp_multi` one method narrowed at Int and Flag via distinct
  `RKey`s, `disp_dict` a `=>`-constrained fn dispatched through the dict at both Int
  and Flag) and the **35/35 plain-harness fixtures stay byte-identical** (dispatch
  emission only fires when the impl list is non-empty). Slice 6 deferred arg-tag /
  arg-position dispatch and multi-clause impl methods to slice 7 (§2.4a-4 below);
  nested requires dicts and arrays / GC remain out of scope and panic.

**2.4a-4 — Slice 7 (ARG-POSITION / arg-tag DISPATCH).** The symmetric remaining
  dispatch gap, also bootstrap-critical (`eq`/`compare`/`show` over values). **Key
  representation finding (corrects the slice-6 "RNone arm" framing):** arg-position
  dispatch does NOT lower to a `CMethod` node at all. Running the gate front-end
  (`elaborateDict`) on `eq Off Off`, the call site stays a bare `CVar "eq"` — the
  marker rewrites only RETURN-position occurrences to `CMethod`; an arg-dispatched
  occurrence is left a plain `CVar` that resolves at run time to the coalesced `VMulti`
  and is dispatched by the argument's runtime constructor type
  (`ceval`→`applyOpt`→`collectPartials`→`matchPat`). So there is no `CMethod RNone` to
  fill; the work lives at the bare-`CVar` call site (`emitApp`) and in the impl-method
  defines. Tracing the runtime, the `VMulti` is applied ARG-BY-ARG — at each column,
  candidate clauses whose pattern fails `matchPat` drop, the leftmost fully-matching
  clause wins — which is exactly **Maranget column specialization**, so the lowering's
  decision-tree compiler is a faithful port. **Axis-1 note:** this slice exports
  `compileTree`/`canonPat` from `core_ir_lower.mdk` — the Axis-1 table designates the
  Maranget decision-tree compilation as the backend-neutral pass shared by both
  backends ("Yes, the tree … only leaf emission differs"), so surfacing it for its
  second consumer is the intended reuse, not an IR change. **Spike-rep notes (extending
  (a)–(m)):** **(n) call site** — a bare `CVar` naming a tagged-impl method, applied to
  args, is the arg-dispatch site (return-position methods are `CMethod`, never a bare
  applied `CVar`, so the impl-method-name set cleanly identifies these). One impl group
  (method has impls at a single type) ⇒ a DIRECT `@mdk_impl_<tag>_<method>` call, no
  runtime test (a well-typed call always reaches it); several groups ⇒ load the
  discriminating arg's cell tag and emit an if-chain testing whether it is one the
  group's TYPE owns (`OR` over `ctorsOfType`'s `cellTag`s, the new ninth `Emit` ref =
  `CProgram`'s ctor→type map), `unreachable` default. ADT-only — `loadTag` needs a
  boxed cell. **This cross-type test is exactly why the ordinal tag is a composite,
  not a bare per-type ordinal:** every type has an ordinal-0 ctor, so bare ordinals
  collide across the candidate groups (a `Color` value of ordinal 1 would spuriously
  match `Animal`'s `{0,1}` test); the per-type id in the tag's high half restores
  global uniqueness. The real backend resolves these sites statically / by dictionary
  and keeps only the low-half ordinal. **(o) multi-clause / pattern-param impls** — the Core IR carries one
  `CImplEntry` PER CLAUSE; same-`(method,tag)` entries are COALESCED into one lifted fn
  whose body is a decision tree built by the shared `compileTree`. By arity: 0 (the
  slice-6 nullary `zero`/`def`) emits the body in tail position, byte-for-byte the old
  path; 1 uses the lone param as the scrutinee; ≥2 wraps the params in a synthetic
  tuple `(a0,a1,…)` so the multi-param match reduces to a single scrutinee, reusing
  `emitDecision`/`emitTree`/`bindPattern` VERBATIM (one extra `$tuple` alloc per call —
  acceptable for the spike). The matrix rows are `canonPat`-normalised (else `PTuple`
  isn't recognised as a constructor head and the column is wrongly dropped — a real bug
  caught in development); the arms keep RAW patterns for `bindPattern`. **(p) bool
  constructors** — impl bodies render `True`/`False` as `CVar "True"`/`"False"`;
  `emitVar` maps them to the `3`/`1` immediate-Bool words (matching `emitLit (LBool …)`).
  **6/6 typed gate** (the 3 slice-6 + `disp_arg_single` single-impl multi-clause,
  `disp_arg_multi` two impls at distinct ADTs, `disp_arg_clauses` the `eq Flag`
  three-clause wildcard fall-through) and **35/35 plain harness** stay byte-identical.
  Still out of scope: arg-tag dispatch on non-ADT args (Int immediates have no cell to
  `loadTag`), nested requires dicts, arrays / GC.

**2.4a-5 — Slice 8 (ARRAYS + RANGES).** The four remaining array/range Core-IR
  nodes: `CArray`, `CRangeArray`, `CIndex`, `CSlice`.  **Scope decision:** CList and
  CRangeList deferred to slice 9 — adding list construction in this slice would
  have expanded scope beyond the array-focused increment; the existing fixtures
  cover list MATCH (HCons/HNil from slice 5b) without list construction, and
  arrays are self-contained.  **Rep decision (extends (q)–(t)):**
  **(q) ARRAY CELL** — layout `[ i64 raw_len | elem0 | elem1 … ]` (header word =
  raw element count, NOT a constructor hash; elements at offsets 8*(i+1) via the
  slice-3 `storeFields`/`loadField` convention).  `loadTag` reads the raw count.
  `emitArrayAlloc` handles static-size (CArray) and `emitArrayDynAlloc` the dynamic
  case (ranges and slices); both reuse `@mdk_alloc` (Boehm `GC_malloc`).
  **(r) BOUNDS CHECK** — `emitArrayIndex` emits two icmps (idx < 0 || idx ≥ len),
  OR'd to a single i1, and branches to an `@mdk_oob()` block (noreturn helper added
  to `runtime/medaka_rt.c`, call + unreachable) on OOB — matching `eval.mdk`'s
  panic.  Fixtures are in-bounds so the check never fires in practice.
  **(s) RANGE LOOP (CRangeArray)** — the spike's FIRST non-recursion loop.  Uses an
  alloca-counter pattern (consistent with the existing alloca/store/load merge
  convention — avoids phi nodes): alloca i64 counter ic, init 0, `br loopCond`; in
  `loopCond` load iv, `icmp sge iv count` → done/body; in `loopBody` compute
  `tagInt(lo_raw + iv)`, GEP to `(iv+1)*8`, store, increment iv, `br loopCond`.
  CFG is a well-formed natural loop (dominators: loopCond dominates body and done;
  single back-edge body→cond).  **(t) SLICE LOOP (CSlice)** — same alloca-counter
  pattern; each iteration loads element `(lo_raw+i)` from the source array via the
  new `loadFieldDyn` helper (dynamic GEP `(idx+1)*8`) and stores it to dest field i.
  Both inclusive (`incl=True`) and exclusive (`incl=False`) ranges/slices are
  supported; the `hi_adj` computation is a compile-time Medaka branch on the `incl`
  field.  **39/39 plain harness** (4 new fixtures: `arr_index`, `arr_range_sum`,
  `arr_slice`, `arr_range_excl`) and **6/6 typed gate** stay byte-identical.
  Still out of scope (addressed in slice 9): CList/CRangeList. Remaining gaps:
  arg-tag dispatch on non-ADT args; nested requires dicts; GC.

**2.4a-6 — Slice 9 (LISTS: CList + CRangeList).** The last two list-construction
  Core IR nodes, completing the non-GC Core IR surface.  Both lower via the
  existing `emitCtorAlloc` path (Cons/Nil boxed cells, the same `cellTag "Cons"`/
  `cellTag "Nil"` tags the slice-5b HCons/HNil match heads test, so construction
  and match agree by construction).  **Spike-rep notes (extending (a)–(t)):**
  **(u) CList [e0…en] INLINE RIGHT-FOLD** — N+1 `emitCtorAlloc` calls emitted in
  straight-line code from innermost (tail) to outermost (head); zero loops, no
  runtime overhead beyond the allocations.  Consistent with `emitTuple` (static
  arity → static unroll).  **(v) CRangeList lo hi incl BACK-TO-FRONT LOOP** —
  two allocas (`acc` = current list head, `ic` = loop counter); init `acc=Nil`,
  `ic=count-1`; while `ic≥0`: prepend `Cons(tagInt(lo+ic), acc)`, decrement.
  Back-to-front guarantees the resulting list is ascending without a separate
  reverse pass.  An empty range (`count≤0`) sets `ic=-1` and exits immediately,
  returning Nil.  CFG shape mirrors the slice-8 alloca-counter loop (no phi nodes,
  consistent `alloca/store/load` discipline).  **Scope decision (stated):** loop
  chosen over a define-recursive helper for stack safety on large ranges and
  consistency with slice 8; the inline-fold chosen for CList because the list size
  is compile-time-known (no recursion-depth risk).  **43/43 plain harness** (4 new
  fixtures: `list_lit`, `list_range_incl`, `list_range_excl`, `list_range_combo`)
  and **6/6 typed gate** stay byte-identical.  Still out of scope: arg-tag dispatch
  on non-ADT args; nested requires dicts; GC.

**2.4a-7 — Native extern catalog slice 1 (STRINGS + minimal string/IO externs).**
  The first slice of item 2 below (native extern catalog), not a Core IR-surface
  slice — unblocked by the just-landed Boehm GC, since a heap String is GC-managed
  for free.  It LOCKS the **String representation** (RUNTIME-DESIGN.md §4/§7
  decision 2, previously OPEN): **UTF-8 bytes + a cached codepoint count**, boxed as
  one cell `[ i64 header | i64 byte_len | i64 cp_count | bytes… | NUL ]` over the
  §8.1/§8.4 one-word-header discipline.  **Spike-rep notes (extending (a)–(v)):**
  **(w) STRING CELL** — two metadata words (`byte_len`, `cp_count`) ahead of the
  inline UTF-8 bytes; the value word is the cell pointer (low bit 0), so Boehm
  tracks it and scans the bytes harmlessly.  Caching `cp_count` makes `stringLength`
  **INTRINSIC** (the §5 `(rep)` row resolves header-read, not O(n) scan).
  **(x) STRING LITERAL** — `CLit (LString _)` emits a private module-scope
  `@.str.N = … [N x i8] c"…"` global (every byte escaped `\HH`, byte-faithful to the
  source; the emitter re-encodes source codepoints to UTF-8 via `utf8Bytes`) and a
  run-time `@mdk_str_lit(ptr, i64)` call that boxes it.  Globals ride the lifted-
  lambda side buffer (LLVM module-item order is irrelevant).  **(y) STRING EXTERN
  `intToString`** — the first LEAF extern that RETURNS a Medaka value: it lowers to a
  direct C-ABI `@mdk_int_to_string(i64)` call that untags the immediate, renders
  decimal, and allocates the result String through `mdk_str_lit → mdk_alloc`
  (proving the §2a contract — extern output lives in the GC heap, never a native
  buffer).  **(z) PRINT PATH** — `main` reducing to a String auto-prints via
  `@mdk_print_str(i64)` (raw bytes + newline), matching `Eval.pp_value (VString s) =
  s` + the oracle's trailing newline; chosen over `putStr`/`putStrLn` to fit the
  spike's type-directed auto-print of `main` (a Unit-returning `putStr` would double
  the output with `pp_value VUnit`).  **5/5 new plain fixtures** (`str_lit`,
  `str_escape`, `str_unicode`, `str_int`, `str_int_neg`) and **2/2 new typed
  fixtures** (`str_lit`, `str_int`) byte-identical; the prior 46 plain / 6 typed and
  the core_ir/eval gates unaffected.  **Covered:** String literals, raw print,
  `intToString`.  **Remaining catalog work is scoped as ordered slices 2–16** in
  [`../PLAN.md`](../PLAN.md) §"Native extern catalog — slice breakdown" (each sized
  to this same template for a Sonnet agent): the mechanical string/char/array/IO
  slices, the `Char`-rep lock (slice 8) and reserved-built-in-ADT-tag precursor
  (slice 10) that gate the rest, and the separately-flagged non-mechanical ones
  (`→MEDAKA` sorts, RNG, `hash`→method).

**2.4a-8 — Native extern catalog slice 2 (NUMERIC conversions + constants).**
  Seven externs: three conversions (`intToFloat`, `floatToInt`, `floatToString`)
  and four constants (`pi`, `e`, `intMaxBound`, `intMinBound`).  All mechanical
  per the slice template.  **Spike-rep notes (extending (a)–(z)):** **(aa)
  INTRINSIC CONVERSIONS** — `intToFloat` is `untagInt` + `sitofp i64 → double` +
  `boxFloat`; `floatToInt` is `unboxFloat` + `fptosi double → i64` + `tagInt`
  (truncates toward zero, matching OCaml `int_of_float`).  Both are intercepted in
  `emitApp`'s `CVar` arm (new `isNumExtern`/`emitNumExtern` helpers beside the
  existing `isStrExtern`/`emitStrExtern`).  **(bb) LEAF `floatToString`** — a new
  C helper `mdk_float_to_string(double) -> long long` appended after
  `mdk_int_to_string` in `runtime/medaka_rt.c`; it copies `mdk_print_float`'s
  `%.12g` + trailing-dot logic EXACTLY but returns `mdk_str_lit(buf, strlen(buf))`
  instead of printing — same bytes, GC-managed String cell.  Declared in
  `emitPreamble` and intercepted in `emitNumExtern`.  **(cc) CONSTANTS** —
  `pi`/`e` are intercepted in `emitVar` (like `True`/`False`) and box a decimal
  double literal inline via `boxFloat`; `intMaxBound`/`intMinBound` emit the
  already-tagged word as a literal string (`"9223372036854775807"` /
  `"-9223372036854775807"`) to avoid overflow in the self-host's 63-bit Int
  (`n*2+1` would silently wrap for these boundary values).  **58/58 plain + 9/9
  typed fixtures byte-identical**; core_ir/eval gates unaffected.

**2.4a-9 — Native extern catalog slice 3 (IO OUTPUT + Unit).**
  Four externs: `putStr`/`putStrLn` (stdout) and `ePutStr`/`ePutStrLn` (stderr).
  All return Unit, introducing `LTUnit` to the emitter's `data LTy`.  **Spike-rep
  notes:** **(dd) LTUNIT** — a new `LTUnit` variant in `data LTy`; the Unit operand
  word is an arbitrary immediate (`"1"`) never inspected, only auto-printed.
  `emitPrint e _ LTUnit` calls `@mdk_print_unit()` which does `printf("()\n")`,
  matching `Eval.pp_value VUnit = "()"`.  **(ee) IO-OUTPUT C HELPERS** — a shared
  `mdk_fwrite_str(w, out, nl)` reads the string cell (bytes at offset 24, `byte_len`
  at offset 8) and writes to the given `FILE`; `mdk_putstr`/`mdk_putstrln` pass
  `stdout`, `mdk_eputstr`/`mdk_eputstrln` pass `stderr`.  `mdk_print_str` kept
  unchanged (used by the String auto-print path).  **(ff) TYPED GATE ORACLE GAP** —
  `core_ir_dict_pp_main.mdk` does not execute the stdout side effect of `putStrLn`,
  so a stdout-writing typed fixture would diverge (`ref="()"` vs `self="hi\n()"`).
  Fix: the typed fixture uses `ePutStrLn "err"` (stderr-only side effect, dropped by
  `2>/dev/null` on both sides → both produce `"()"` on stdout).  **3/3 new plain
  fixtures** (`io_putstr`, `io_putstrln`, `io_eputstrln`) and **1/1 new typed fixture**
  (`io_putstrln` — actually `ePutStrLn`-bodied) byte-identical; all 61 plain + 10
  typed pass; core_ir/eval gates unaffected.

**2.4a-10 — Native extern catalog slice 4 (ABORT: panic + exit).**
  Two process-terminating externs: `panic (String -> a)` and `exit (Int -> a)`.
  `mdk_panic` reads the string cell via `mdk_fwrite_str(w, stderr, 1)` then calls
  `exit(1)`; `mdk_exit` untags the Int (`tagged >> 1`) and calls `exit(n)`.  Both are
  declared `noreturn` in C.  Emitter: `isAbortExtern`/`emitAbortExtern` intercept in
  `emitApp`'s `CVar` arm (same pattern as slice 3); the call emits `call void
  @mdk_panic/exit(i64 arg)`; returns `("1", LTUnit)` so the downstream `emitPrint
  LTUnit` is dead code (the terminate call precedes it).  Gate model: both oracle and
  native produce empty stdout (oracle: `Eval_error` → stderr; native: `mdk_panic/exit`
  terminates before auto-print runs) — empty == empty is a valid compile+link+terminate
  proof.  Stronger fixture (`abort_exit_after_output`) prints "before" then exits,
  proving ordering.  4/4 new fixtures; all 65 plain pass; typed/core_ir/eval gates
  unaffected.

**2.4a-11 — Native extern catalog slice 6 (ARRAY INTRINSICS).**
  Three pure-inline externs: `arrayLength`, `arrayGetUnsafe`, `arraySetUnsafe`.
  No C helper (no `runtime/medaka_rt.c` change); all emit directly via existing
  helpers.  `arrayLength` = `loadTag` (header word = raw count) + `tagInt`.
  `arrayGetUnsafe` = `untagInt` index + `loadFieldDyn` (CIndex path minus bounds-check).
  `arraySetUnsafe` = `untagInt` index + new `storeFieldDyn` helper (mirrors
  `loadFieldDyn` but ends with `store i64 val, ptr fp` and returns `Unit`).
  Intercepted via `isArrIntrinsic`/`emitArrIntrinsic` in `emitApp`'s `CVar` arm.
  `arrayGetUnsafe` returns `LTInt` (matching `CIndex`'s hardcoded `LTInt`; spike array
  fixtures are Int-element).  `arraySetUnsafe` returns `("1", LTUnit)`.  Four new plain
  fixtures: `arr_length` (→3), `arr_get` (→20), `arr_set_get` (mutate-then-read →99,
  proves store visibility), `arr_set_unit` (→`()`).  One typed fixture: `arr_get`
  (→20).  **75/75 plain + 12/12 typed byte-identical**; core_ir/eval gates unaffected.

**2.4a-12 — Native extern catalog slice 8 (CHAR REP LOCK + char scalars).**
  First Tier B slice. Locks `Char` = immediate codepoint word `(cp << 1) | 1` (same
  low-bit-1 encoding as `Int`). `LChar` literal: extract codepoint via
  `charCode (arrayGetUnsafe 0 (stringToChars c))`, emit `cp * 2 + 1`.  `charCode` is
  INTRINSIC — identity re-type `LTChar → LTInt`, no instruction.  `charToStr` → new
  C helper `mdk_char_to_str`: `mdk_utf8_encode` (static helper, ≤4 bytes) + `mdk_str_lit`.
  `charMinBound = "1"` (cp 0 → `(0<<1)|1`), `charMaxBound = "2228223"` (cp 0x10FFFF →
  `(0x10FFFF<<1)|1`).  `LTChar` auto-print → `@mdk_print_char` (UTF-8 bytes + newline).
  `isCharExtern`/`emitCharExtern` wired into `emitApp`'s `CVar` arm alongside the other
  extern families.  **86/86 plain + 14/14 typed byte-identical**; unicode round-trip
  (`☕` = U+2615) verified; core_ir/eval gates unaffected.

**2.4a-13 — Native extern catalog slice 10 (RESERVED ADT-TAG PRECURSOR).** First
  Tier C slice; the gating precursor for every ADT-**returning** extern (11/12/13).
  A C extern cannot stamp a program-dependent `cellTag`, so the runtime ADTs (`List`
  Cons/Nil, `Option` Some/None, `Result` Ok/Err, `Ordering` Lt/Eq/Gt) get a FIXED
  reserved tag block: `reservedTag` in `llvm_emit.mdk` returns
  `(reservedTypeBase + typeId) * 2^32 + ordinal` (base 65536, typeIds 0–3), consulted
  first in `cellTag`; `runtime/medaka_rt.c` hardcodes the same `MDK_TAG_*` constants.
  Both alloc and every match-head test route through `cellTag`, so reserving keeps
  construction (C builders) and match consistent by construction. Runtime constructors:
  `mdk_some`/`mdk_ok`/`mdk_err`/`mdk_cons` (boxed cells) + `mdk_none`/`mdk_nil`/
  `mdk_lt`/`mdk_eq`/`mdk_gt` (immediate words). Canary `charFromCode : Int -> Option
  Char` (`isAdtExtern`/`emitAdtExtern`): `adt_some` (boxed `Some`, charCode 65) +
  `adt_none` (immediate `None`, surrogate 0xD800 → -1) prove both reps round-trip
  through `match`. **103/103 plain byte-identical**; core_ir/eval unaffected (existing
  list/option/ordering fixtures re-pass). No typed fixture — the typed gate loads only
  `runtime.mdk`, so the self-hosted typecheck has no `Option` ctor (scalar-only). KNOWN
  LIMITATION: a user type reusing a reserved ctor name aliases the reserved tag
  (internally consistent; the real backend resolves statically).

**Spike status after slice 10 — what's next.** The de-risking spike has now lowered
the **full non-GC Core IR surface** (scalars → top-level fns + `musttail` →
ADTs/decision-tree match → closures/HOFs → records/tuples/refs → built-in
list/tuple heads + recursive closures → return-position dispatch → arg-tag
dispatch → arrays/ranges → lists), proving the decided toolchain (textual LLVM IR +
`clang`, no llc/opt/bindings) end-to-end against the tree-walker oracle. Its job is
done: it is **not** the real backend, and continuing to add spike slices buys little
— the remaining items are the decision-dense ones deferred to the real backend by
design. The near-term sequence (mirrored in [`../PLAN.md`](../PLAN.md) §"Native
backend (Stage 2) — near-term sequence"):
1. ✅ **Value representation + calling convention RATIFIED (2026-06-07)** — Option A
   (uniform tagged word) as the native encoding *under §8.6's shared abstract
   contract* (WasmGC-compatible by construction); constructor tag = **dense i32
   ctor-ordinal per type** (replaces the spike's i64 hash — `br_table`-ready, no
   collisions); uniform one-word header kept; `Float` boxed-first.
   [`RUNTIME-DESIGN.md`](./RUNTIME-DESIGN.md) §8.
2. **Promote the spike to the real backend** — ~~integrate a GC (Boehm to start; the
   spike is malloc-and-leak)~~ **GC DONE 2026-06-07** (`mdk_alloc` → Boehm `GC_malloc`,
   conservative; verified collecting — ~3 MB RSS on a 2×10⁸-cons churn vs ~614 MB
   leaking); re-implement the native extern catalog (per-extern
   disposition in RUNTIME-DESIGN) — **catalog slice 1 DONE 2026-06-07** (Strings:
   rep locked UTF-8 + cached codepoint count; `mdk_str_lit`/`mdk_print_str`/
   `mdk_int_to_string`; §2.4a-7), **slices 2/3/4 DONE 2026-06-07** (numeric/IO/abort;
   §2.4a-8–10), **slice 5 DONE 2026-06-07** (`stringLength` INTRINSIC: GEP to
   `cp_count@16` + tag; `stringConcat` LEAF: `mdk_string_concat` walks built-in List
   by low-bit, sums `byte_len`s, one alloc + blit via `mdk_str_lit`; 71/71 plain +
   11/11 typed byte-identical), **slice 6 DONE 2026-06-07** (`arrayLength` INTRINSIC:
   `loadTag` + `tagInt`; `arrayGetUnsafe`/`arraySetUnsafe` INTRINSIC: `loadFieldDyn`/
   `storeFieldDyn`; 75/75 plain + 12/12 typed byte-identical), **slice 7 DONE
   2026-06-07** (`arrayMake`/`arrayCopy`/`arrayBlit`/`arrayFill`/`arrayFromList` LEAF:
   C helpers in `mdk_array_*`; array cell = raw-length header, no tag; `arrayFromList`
   walks built-in List by low-bit; 80/80 plain + 13/13 typed byte-identical; Tier A
   complete), **slice 8 DONE 2026-06-07** (`Char` rep locked as immediate codepoint
   word `(cp << 1) | 1`; `charCode` INTRINSIC identity; `charToStr` LEAF via
   `mdk_char_to_str`; `LChar` literal → tagged immediate; `LTChar` auto-print via
   `mdk_print_char`; 86/86 plain + 14/14 typed byte-identical; unicode round-trip
   verified; Tier B slice 8 unblocks slices 9 + 14), **slice 9 DONE 2026-06-07**
   (`stringToChars` LEAF: `mdk_string_to_chars` walks UTF-8, emits one Char immediate
   per codepoint into a raw-length Array cell; `stringFromChars` LEAF: two-pass sum +
   alloc + encode via `mdk_string_from_chars`; `stringSlice` LEAF: clamped codepoint
   indices via `mdk_utf8_byte_offset` + `mdk_string_slice`; `mdk_utf8_decode` added;
   Array result is `LTCon`, no auto-print; 91/91 plain + 15/15 typed byte-identical;
   unicode round-trip `wörld` + codepoint slice `café→af` verified), **slice 14 DONE
   2026-06-07** (`charIsAlpha/Space/Upper/Lower/Punct`, `charToUpper/Lower`,
   `stringToUpper/Lower`; nine C helpers in `medaka_rt.c`; `isUnicodeExtern`/
   `emitUnicodeExtern` in `selfhost/llvm_emit.mdk`; predicates call C and tag raw 0/1
   to Bool via `tagInt`; `charIsPunct` is a switch over Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps
   ASCII members, NOT `ispunct()` — `+`/`$`/`=`/`^`/`|`/`~` return `False`; string
   case-map is byte-wise ASCII, UTF-8 multi-byte bytes pass through; 101/101 plain +
   16/16 typed byte-identical; full-Unicode deferred to RUNTIME-DESIGN §6), **slice 10
   DONE 2026-06-07** (reserved ADT-tag precursor: `reservedTag`/`reservedTypeBase`
   65536 in `llvm_emit.mdk` + matching `MDK_TAG_*` in `medaka_rt.c`; runtime cell
   builders `mdk_some`/`ok`/`err`/`cons` + `mdk_none`/`nil`/`lt`/`eq`/`gt`; canary
   `charFromCode` via `isAdtExtern`; `adt_some`/`adt_none` prove boxed + immediate
   round-trip; 103/103 plain; gates the ADT-returning slices 11/12/13) — and close the spike's out-of-scope gaps (arg-tag
   dispatch on non-ADT/Int args, nested-requires dicts). ~~emit the ratified dense
   i32 ctor-ordinal tags~~ **DONE 2026-06-07** — the spike already stamps them
   (`cellTag`; composite `typeId<<32 | ordinal`, hashName gone from every ctor tag);
   last spike-vs-real tag gap closed. Gate native stdout against
   **both** the tree-walker and the bytecode VM (the second, single-steppable
   oracle — the disambiguation LLVM-first cannot have).
3. **Bootstrap closure** — the self-hosted compiler + LLVM backend compiles itself
   to a standalone native binary.

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
