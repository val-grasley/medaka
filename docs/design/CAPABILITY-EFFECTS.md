# Capability-safe effects — Medaka's headline direction

**Status:** PARTIAL — core effect tracking/manifest emission shipped (see below);
§6a's finite-set-lattice sketch is SUPERSEDED BY `CAPABILITY-EFFECTS-V2-DESIGN.md`
(parameterized effects v2, IMPLEMENTED). See `EFFECTS-CONFORMANCE-ROADMAP.md` for
the current authoritative completion record (WS-1 through WS-4 done; WS-5 standing
discipline open).

Status: **substantially complete** (Phase 146 in [`PLAN.md`](../../PLAN.md)). Effect
*propagation/inference* already shipped (Phase 79/79e); the laundering-soundness
holes that made the manifest forgeable are closed for the open/closed AND
closed-closed point-free cases (the latter via variance-aware covariant re-open),
and the **compiler mirror is done** (2026-06-06: full effect subsystem ported into
`compiler/types/typecheck.mdk` — path since reorganized into subfolders, was
`compiler/typecheck.mdk` at the time — byte-identical harnesses). User-definable effect labels
(gap 2: the `effect Foo` declaration form) shipped 2026-06-06 (reference + compiler
mirror). Cross-module effect label export (gap 3) shipped 2026-06-07. **Manifest
emission shipped 2026-06-21** (`medaka check-policy` + parameter-level policy +
`medaka manifest` TOML — WS-1a/1b/1c per `EFFECTS-CONFORMANCE-ROADMAP.md`).
See **§5a (current state)** for the precise done/remaining split. Companion to [`language-design.md`](../spec/language-design.md)
(effect rows as they exist today) and [`compiler/STAGE2-DESIGN.md`](../../compiler/STAGE2-DESIGN.md)
(effects are erased before codegen). The **platform/runtime architecture** that
consumes this feature (verification pipeline, plugin SDK model, worked plugin
examples) is in [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md).

One-line thesis:

> **A function's type already says which effects it may perform. Make that sound
> and fine-grained, and the type becomes a compiler-verified *capability manifest*
> — so the program tells you (and the platform that runs it) exactly what it can
> do.** This is Medaka's candidate "killer feature," aimed at WebAssembly edge /
> plugin / sandboxed compute, and it falls out of the effect system Medaka already
> has — **without** algebraic-effect handlers.

---

## 1. Why this exists (the wedge)

Medaka needs a *positive* reason to exist next to OCaml, Roc, Gleam, PureScript,
and MoonBit. "Strict Haskell" is a motivation, not a wedge — that niche is the most
crowded in typed FP. The wedge this document commits to is the convergence of four
things Medaka either already has or is already building:

- **Strong, predictable, approachable static checking** (Medaka's identity:
  Haskell-grade abstraction without the ivory tower).
- **An effect system in the types** (already present: `<IO>`, `<Rand>`,
  `<Async>`, row-tail forms `<IO | e> a`). Every effect label is a host
  capability — there is no internal/purity-tracking label class (`Mut`/`Panic`
  were removed 2026-07-14).
- **A native/Wasm backend** (Stage 2; the Core IR is a swappable seam, so a
  WasmGC backend can be a sibling consumer of the LLVM one).
- **The AI-guardrail reality**: in an AI-coding world the bottleneck shifts from
  *writing* code to *trusting* code — especially untrusted, generated, third-party
  code. A compiler that *verifies* what code can do is worth more, not less.

Those meet at one use case: **edge / plugin / serverless Wasm**, where the defining
question is *"what can this short-lived, untrusted, increasingly AI-generated module
actually do?"* Today that's answered by the runtime sandbox alone; the *language*
says nothing. Medaka can make the answer a **compile-time guarantee read off the
type**.

The customer this sells hardest to is the **platform** that must run untrusted
functions safely (Cloudflare Workers / Fastly / Fermyon-style hosts), not only the
developer writing them — and platforms are how languages get adopted by mandate
(cf. Swift/iOS). The flagship artifact is therefore plausibly a small **edge/plugin
runtime** that loads, verifies, and trusts Medaka modules — not a web framework.

See the session strategy discussion for the full wedge analysis (concurrency,
WebAssembly, web, AI, crypto) that led here; this doc captures the conclusion.

## 2. The load-bearing distinction: tracking ≠ handlers

"Effect system" smears together two independent things:

1. **Effect *tracking*** — the type lists which effects a function may perform; the
   compiler infers/checks it. A *type-system* feature.
2. **Effect *handlers*** (algebraic effects, à la Koka) — `perform`/`handle`/
   `resume`; implement async, generators, backtracking as library code. A
   *control-flow + runtime* feature needing delimited continuations.

**Medaka takes (1) and explicitly rejects (2).** Capability safety is entirely a
tracking property. Handlers are the academic, heavyweight half — and their runtime
(delimited continuations) is *especially* hostile to WebAssembly, so skipping them
is doubly correct for an edge target.

Contrast for calibration: **OCaml 5 chose handlers *without* tracking** (runtime
machinery, nothing in the types). Medaka wants the **opposite slice — tracking
without handlers** — which is the half that actually yields a security manifest.

> **The "handler" is the host.** In-language, Medaka only *tracks and bounds* what
> a function may do. The Wasm runtime *grants or denies* the actual capability at
> the module boundary. The effect row is a manifest the platform inspects before it
> loads the module; the platform is the handler.

## 3. The user-facing model (simple floor, opt-in ceiling)

The hard constraint, from the PureScript lesson in §5 and the approachability goal:
**the common case requires zero effect annotations.** Effects are inferred the way
HM infers types, and surface only where you want a boundary.

Illustrative syntax (NOT final — see Open Questions):

```
-- General code: no effect annotations. Inference computes the row.
greet name = putStrLn ("hi " ++ name)        -- inferred: String -> <IO> Unit

-- A platform declares the fine-grained capabilities it offers:
effect KV        -- a key/value store capability
effect Fetch     -- outbound HTTP
effect Log

-- A plugin entry point ANNOTATES its bound; the compiler verifies the body,
-- transitively, never exceeds it:
handler : Request -> <KV, Log> Response
handler req = ...
  -- if anything reachable from here performs <Fetch>, this is a COMPILE ERROR

-- The platform reads `handler`'s row as the capability manifest and grants
-- exactly { KV, Log } host imports — rejecting the module if it demands more.
```

Three audiences, three experiences:
- **Everyday code:** write normally, effects invisible (inferred).
- **A boundary** (plugin entry, a "this is pure" guarantee): annotate the bound; the
  compiler proves it holds transitively.
- **A platform:** reads the entry row as a verified manifest; grants precisely those
  capabilities.

No `handle`, no `resume`, no continuations, no category theory. Arguably *simpler*
than the monad world Medaka's effects already replaced.

### 3a. Effect-label declaration syntax (pinned, Phase 146 gap 2)

The atomic (no-parameter) declaration form is now implemented:

```
effect KV          -- declares the bare effect label KV, usable as <KV> in rows
effect Fetch
export effect Log   -- (parses; cross-module import of the label is future work)
```

**Surface syntax — the minimal thing that composes with the existing row grammar.**
A top-level `effect Foo` declaration, where `Foo` is an uppercase name (same lexical
class as type/constructor names, since labels appear in type position). It is a
top-level `decl` (`DEffect of bool * ident`, the bool mirroring every other decl's
`export` prefix) — so it admits `export effect Foo` for free and slots into the
`inner_non_data_decl` rule with **zero new parser conflicts**. The declared label
joins the built-in vocabulary (`IO, Async, Rand, Time`); using an
*undeclared* label in a row stays a resolve-time `UnknownEffect`. A row mentioning
the label (`<KV>`, `<KV, Log>`, `<KV | e>`) needs no new syntax — it is the existing
row grammar over a now-larger label set.

**Where the effect comes from.** A bare `effect KV` only *names* a capability; a
program performs it by calling something whose type carries `<KV>`. The platform
declares those host imports as ordinary externs — `extern kvGet : String -> <KV>
String` — which is exactly the "the handler is the host" model (§2): the label is
the manifest entry, the extern is the granted host function.

**Deliberately deferred:** the **parameterized** form (`effect Fetch (Str)`,
`<Fetch "idp.example.com">`) is Phase 146b (§6a). Cross-module export/import of a
declared label is **done (gap 3, 2026-06-07)** — see §5a.


## 4. Non-goals

- **No algebraic-effect handlers / resumptions / delimited continuations.** Ever,
  for capability safety. (A separate, later decision could add limited control
  effects, but it is out of scope here and not required by the wedge.)
- **Not Koka.** We take Koka's *effect-type* intuition, not its handler layer.
- **No mandatory ambient effect ceremony for all code.** Fine-grained effects are an
  **opt-in boundary feature**, not a tax on everyday programs (the PureScript
  mistake — §5).
- **No runtime cost.** Effects are erased after checking (§6).

## 5. What changes vs. today — a completion, not a pivot

Medaka's current effects are further along than this section originally claimed
(it predated Phase 79). Two gaps were named; their status is now split:

1. **Soundness via propagation/inference.** A claim like `<no Fetch>` must be
   *guaranteed* transitively. **Propagation shipped in Phase 79/79e**: effect
   rows carry tail variables, inference computes them, higher-order code composes
   (`map : (a -> <e> b) -> List a -> <e> List b` works on the real stdlib), and a
   binding-boundary check rejects an unsigned helper's effect escaping a pure
   signature. What was *still unsound* until this phase was **effect
   laundering**: an effectful closure stored in / annotated as a pure arrow
   (data field, value signature, callback parameter, typeclass-method impl body)
   silently dropped its labels, because `unify_row` was deliberately permissive.
   Those open/closed-row cases are **now closed** (see §5a). One narrower hole
   remains (closed-closed point-free aliasing) needing directional subsumption.
2. **Granularity + extensibility.** One coarse `<IO>` is useless as a capability;
   the point is fine-grained, **user/platform-definable** labels (`<KV>`,
   `<Fetch>`, `<Log>`, `<Clock>`). **Shipped (Phase 146 gap 2, 2026-06-06).** The
   `effect Foo` declaration form registers labels into the resolver vocabulary
   (builtins `IO, Async, Rand, Time` ∪ user-declared); an undeclared
   label in a row is still an `UnknownEffect`. `DExtern` is already a top-level
   decl, so a platform declares `<KV>` host imports as ordinary externs. Syntax +
   rationale in §3a; done/remaining in §5a. (Cross-module label export and the
   parameterized form §6a remain.)

Both are continuous with the original "show impurity in the type" intent — making it
*honest and fine-grained*, not a new paradigm.

## 5a. Current state (done / remaining)

**Done (Phase 79/79e):** effect rows + tail vars; effect inference; open/closed
rows; `perform_effect`; transitive escape through unsigned helpers; higher-order
`<e>` propagation through real stdlib; `EffectEscape` at binding boundaries.

**Done (Phase 146, 2026-06-05):** laundering soundness for open/closed-row
unification. `unify_row` now enforces that an OPEN row's labels are ⊆ the CLOSED
bound's labels (closed extras still flow into the open sink — legit calls
unchanged). New `EffectLeak` error. Closes: effectful lambda → pure value
signature; → pure-callback parameter; → pure-arrow data field; → typeclass-method
impl whose interface row is pure. **Zero regressions** across all unit suites,
`@thorough`, and the compiler typecheck/check/selfproc harnesses (no legitimate
code relied on the laundering). Regression tests in `test_typecheck.ml`
(`effects` group).

**Done (Phase 146, 2026-06-06):** closed-closed point-free laundering, via
**variance-aware re-opening on instantiation**. A concrete effectful value whose
row is *closed* (`putStrLn : String -> <IO> Unit`, an instantiated scheme) could
unify `None,None` against a closed pure bound (a value signature, a ctor field, a
list element) and silently drop its labels — symmetric `unify_row` can't tell
safe pure→effectful subsumption from unsafe effectful→pure escape. Fix:
`instantiate_raw` re-opens a closed-with-labels row to `<labels | ρ>` **only at
covariant (positive) positions** (the value's own arrows), so the existing
open/closed subset check fires. Contravariant rows (a ctor field / parameter the
scheme *accepts*, e.g. `VPrim (Value -> <IO> Value)`) stay closed, preserving
safe subsumption (a pure argument into an effectful-allowing slot is fine).
Measurement surfaced exactly **one** genuine latent unsoundness in the compiler
source — `concatMapList`'s pure callback signature hid an effect — fixed
by making it effect-polymorphic (`(a -> <e> List b) -> List a -> <e> List b`).
Zero spurious regressions across all unit suites, `@thorough`, and the compiler
harnesses (typecheck/check/check_modules/golden/selfproc/eval_run/eval_modules/
eval_dict). Tests: `test_typecheck.ml` `effects` group (`e_eff_leak_pointfree_*`,
`t_eff_subsume_pure_into_effectful_field`, `t_eff_over_annotation_pointfree`).

**Done (Phase 146 compiler mirror, 2026-06-06):** the full effect-tracking
subsystem was ported into what is now `compiler/types/typecheck.mdk` (path since
reorganized into subfolders). The earlier "remaining" note
("the `unify_row` subset rule and the instantiation re-opening are not yet
mirrored") understated it: compiler had **no effect rows at all** (effects were a
bare `List String` on `TFun`, discarded by unify; no effvars, no ambient state).
The port reproduces Phase 79 (propagation) + 79e (escape) + 146 (laundering) across
four committed stages (representation → propagation → escape → laundering). New
fixtures `effect_leak`/`effect_escape` (reject) and `effect_subsume` (accept),
verified against `dev/tc_probe.exe` first. Every `diff_compiler_*` typecheck/error/
golden/check/check_modules/selfproc/eval harness is byte-identical; `@thorough`
green. The self-hosted typechecker now rejects laundering identically to the
reference. (Expected proportionate cost: ~+20% per-decl typecheck overhead from
per-arrow effvar allocation — see `compiler/PERF-NOTES.md`.)

**Done (2026-06-21, WS-1a/1b/1c per `EFFECTS-CONFORMANCE-ROADMAP.md`):** manifest
emission. `medaka check-policy` ported to the native CLI (WS-1a), extended to
parameter-level policy checks via domain `dsub` (WS-1b), and `medaka manifest`
added to emit the verified security-row as TOML `[package.capabilities]` (WS-1c).
The Wasm custom-section half remains deferred (touches `wasm_emit.mdk`).

**Done (Phase 146 gap 3, 2026-06-07):** cross-module effect label export. An
`export effect Foo` declaration in one module is now visible across the loader
boundary — importing modules see `<Foo>` as a known label in effect rows rather
than `UnknownEffect`. Historical (`lib/` removed 2026-06-26): `exp_effects` was
added to `module_exports` in `lib/resolve.ml`; populated from public `DEffect`
decls + UseWild re-exports in `build_exports`; installed into `env.effects` on
import (same pattern as Phase 130 iface-methods). Selfhost mirror, still live,
in `compiler/frontend/resolve.mdk`: `expEffects` on
`ModuleExports`, `expEffectsDirect`/`reExpEffects`, `importedEffects`/
`oneImportEffects`, `buildEnvMM` extended. Fixtures: `effect_export` (valid) +
`effect_not_exported` (reject) in `test/resolve_module_fixtures/`; 2 inline
`test_resolve.ml` cases; diff_compiler_resolve_modules 10/10; @thorough green.

**Done (Phase 146 gap 2, 2026-06-06):** user/platform-definable effect labels. A
top-level `effect Foo` declaration (`DEffect of bool * ident`; `export effect Foo`
parses) registers `Foo` into the resolver's effect vocabulary, replacing the
hardcoded `built_in_effects` membership check with *builtins ∪ user-declared*; an
undeclared label in a row stays a resolve-time `UnknownEffect`. Threaded
lexer→parser→AST→resolve with **zero new parser conflicts** and no typecheck change
(the row-unify/subsumption path is label-agnostic — it already treats any label
uniformly, so user labels get Phase 146 laundering soundness for free). Labels are
erased before codegen with the rest of the row. Surface-syntax rationale in §3a.
Fixtures: `test_parser` (decl + export decl), `test_resolve`
(`v_effect_decl`/`v_effect_decl_export` accept, `e_unknown_effect` reject),
`test_typecheck` `effects` group (`t_eff_user_label_accept`,
`t_eff_user_label_subsume` accept, `e_eff_user_label_escape` reject). The
`=== TYPES ===`/`=== AST ===` diff golden stayed byte-identical (no existing program
uses an `effect` decl). Selfhost mirror: see below.

Note: contravariant "laundering" is not a soundness hole — effects are performed
by *calling* effectful functions, so a value only exposes the effects it will
itself perform at covariant positions; effects at contravariant (argument)
positions are attributed to whoever supplies the argument and checked there.
Covariant-only re-opening is therefore sufficient.

**The PureScript cautionary tale (decisive for the design).** PureScript shipped
exactly fine-grained row-effect tracking (`Eff (random :: RANDOM, console ::
CONSOLE) a`) and **removed it** (0.12, → untracked `Effect`) because it was more
ceremony than value *for general-purpose code*. The lesson is not "don't do it" — it
is: **don't make fine-grained effects mandatory ambient ceremony; make them an
opt-in boundary feature.** At a plugin/edge boundary the fine-grained row *is the
product* (the security manifest), so its cost is paid for; in everyday code it stays
inferred and invisible. This is the same "simple floor, opt-in ceiling" /
gradual-verification principle Medaka applies elsewhere.

## 6. Scope, cost, sequencing, risk

- **Bounded type-system work, not new runtime machinery.** Row unification over
  effects + effect inference + a label-declaration form, living almost entirely in
  the typechecker. Well-trodden ground (Koka, Links, Effekt, Frank, PureScript's old
  `Eff`). A meaty multi-part Phase, **not** a research project. The genuinely large,
  risky, Wasm-hostile work (handler semantics + continuations) is exactly what we
  skip.
- **Zero runtime cost.** Effects are **erased** after checking — consistent with
  STAGE2-DESIGN's "effects erased before codegen." The capability *manifest* is
  compile-time metadata the platform reads; nothing survives into generated code or
  the Wasm payload.
- **Interacts with the delicate core.** Effect rows must thread through HM
  inference, typeclass method signatures, and dict-passing — the fiddly part. Treat
  with the same care (and differential-testing discipline) as the dispatch work.
- **Approachability hinges on inference quality + error quality.** If users must
  annotate effects everywhere it becomes monad-transformer tax; if the common case
  infers to zero annotations it feels free. Boundary-violation errors must be
  rendered simply (the "errors as a feature" discipline) — and in the AI loop, the
  *agent* is a fine consumer of the more detailed ones.
- **Staging.** (a) Soundness/propagation first — prerequisite for *any* honest
  capability claim. (b) Fine-grained user labels + the platform-manifest emission
  when the edge runtime that consumes them is built. Sequences cleanly against
  Stage 2: effects erase before codegen regardless.

## 6a. Parameterized effects (the pinned-domain / scoped-KV layer — Phase 146b)

> **Superseded by [`CAPABILITY-EFFECTS-V2-DESIGN.md`](../../archive/design/CAPABILITY-EFFECTS-V2-DESIGN.md).**
> The finite-set-lattice sketch below is the pre-v2 thinking; the settled shape is a
> general refinement-domain representation (Prefix/Set/Product), IMPLEMENTED. Read
> the v2 doc for current ground truth; this section is kept for the design history.

Staged **after** the atomic-effect core (§6): a follow-on layer letting an effect
label carry a parameter — `<Fetch "idp.example.com">`, `<KV "ab:store42:abtest">` —
so a capability is bounded by *resource*, not just *kind*. The platform's strongest
guarantees (pinned network domains, namespaced storage; see
[`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §7a/§7b/§7) require this.

**Core decision: parameters are type-level literals from small built-in sorts — NOT
arbitrary values** (that would be dependent types). Sorts: `Str`, `Nat`, and
**finite sets** of these with a top `⊤` ("unconstrained"). A parameter denotes an
**upper bound on authority**; each sort is a lattice (for `Str`: finite sets ordered
by ⊆, `⊤` = any; join = ∪ saturating to `⊤`; `≤` = ⊆). Decidable; no SMT.

**Surface syntax** (a conservative extension of today's rows — a plain label is the
no-parameter case):
```
effect Fetch (Str)        -- declare a parameterized capability
effect KV    (Str)
verify : Token   -> <Fetch "idp.example.com"> AuthResult
abTest : Context -> <KV "ab:store42:abtest"> Context
h      : Request -> <Fetch {"a.com","b.com"}, Log> Response
p      : Request -> <Fetch _> Response          -- `_` = ⊤ (any)
```

**Semantics, four pieces:**
1. **Rows & atoms.** A row is `head → parameter` (+ optional tail var); at most one
   atom per head; same-head atoms merge by **joining** parameters.
2. **Sub-effecting `r₁ ≤ r₂`** (the platform admission check): every head in `r₁` is
   in `r₂` with `P₁ ≤_sort P₂`. So `<Fetch "a"> ≤ <Fetch {"a","b"}> ≤ <Fetch _>`,
   and crucially `<Fetch _> ⊄ <Fetch "a">`. Per-install policy intersection = per-head
   **meet**.
3. **Inference + literal-lifting (the one dependent-ish rule).** A function's row is
   the **join** of its sub-expressions' rows. Parameters are *created* only at a
   parameterized primitive, by lifting a **literal** argument: `fetch L` (L literal)
   ⇒ `Fetch {domainOf L}`; `fetch e` (non-literal) ⇒ `Fetch ⊤`. **Soundness
   invariant:** the inferred row is always an *over-approximation* of real authority
   (non-literal ⇒ `⊤` = max). A parameterized effect may be imprecise (too
   permissive) but never unsound — the correct failure direction for a security
   manifest.
4. **Polymorphism.** Effect-parameter variables, solved by row unification (same-head
   params combine by join, not equality), let forwarders thread a parameter:
   `withRetry : (a -> <Fetch d | e> b) -> a -> <Fetch d | e> b`.

**Free security payoff.** The `⊤`-fallback means a plugin pinned to
`<Fetch "idp.example.com">` *cannot fetch a runtime-computed URL* — it lifts to
`Fetch ⊤ ⊄ {"idp.example.com"}` → rejected. "No exfiltration to an attacker-chosen
destination" is not a separate check; it is literal-lifting doing its job. The only
way to satisfy a pinned bound is to use an allowed literal.

**Erasure + manifest.** Parameters are compile-time only (erased with the rest of
the row; zero runtime cost), but the *verified* parameters are emitted to the
capability manifest the platform reads to configure proxies (`Fetch {"idp…"}` →
domain-pinned proxy; `Fetch ⊤` → unconstrained network, granted-coarse or rejected
per policy).

**Cost / staging.** A layer on top of atomic effects (param terms + per-sort
finite-set lattices + literal-lifting + param-aware join/unification); polynomial as
long as sorts stay finite-set lattices. Do atomic capability effects (Phase 146
core) first; this is **Phase 146b**.

**Future extensions (noted, not v1):**
- *Structured parameters* (e.g. `*.example.com` wildcard domains) — needs a real
  partial order (prefix/suffix matching) instead of a finite-set lattice.
- *The `domainOf` literal→parameter projection: hard-coded per primitive vs.
  user-specifiable.* Start hard-coded; user-specifiable (a platform declares the
  projection) needs a small compile-time evaluator.

**Open — worthy of investigation before implementing (deferred, do not drill yet):**
- *Precision through wrappers via singleton-typed arguments.* A runtime URL passed
  through a wrapper collapses to `Fetch ⊤`; recovering precision needs
  singleton/refinement typing on *values* (`u : String[="idp.example.com"]`) — a real
  escalation beyond effect-only parameters. Not needed for the literal-at-call-site
  plugin pattern; investigate only if wrapper precision proves necessary.
- *Param-aware row unification × the typeclass/dict machinery.* Effect rows already
  thread through HM + typeclass methods + dict-passing (§6, "the delicate core");
  adding parameterized atoms to that unification is the part most likely to bite in
  implementation. Needs a focused design pass before coding.

## 7. Relationship to existing decisions

- **STAGE2-DESIGN.md** — effects already erased before codegen; this is compatible
  (manifest is metadata, not runtime state). A **WasmGC backend** (sibling to LLVM
  via the Core IR seam) is the natural target for the edge story; note WasmGC is
  *not* reached through LLVM (LLVM targets linear-memory Wasm) — it wants a direct
  emitter, like Kotlin/Dart.
- **RUNTIME-DESIGN.md** — the extern catalog's effect annotations become the
  primitive capability vocabulary the labels build on.
- **Row-polymorphism rejection (PLAN-ARCHIVE §8).** That rejection targeted
  general **extensible records**. *Effect*-row polymorphism is a distinct, scoped
  mechanism (a fixed grammar of effect labels, used only in effect position, not a
  general record calculus). This doc deliberately **revisits the rejection narrowed
  to effect rows only** — flagged here so the revisit is intentional, not an
  accidental contradiction.

## 8. Open questions

- **Ambient effects vs. capability *values* (ocap).** Ambient `<KV>` tracking is
  ergonomic (write normal code, infer the row). A pure object-capability model
  passes capability tokens as values (no ambient authority). A hybrid — ambient
  tracking for ergonomics, host-as-grantor at the boundary — looks best, but the
  attenuation story (a function *removing* a capability before calling another)
  needs design.
- **Effect-label declaration syntax** — **pinned & shipped** (gap 2 + gap 3 DONE): top-level `effect Foo` (gap 2, 2026-06-06) + cross-module `export effect Foo` visibility (gap 3, 2026-06-07). Both reference + compiler. See §3a and §5a.
- **Parameterized effects** — **DONE (2026-06-21, verified done 2026-06-22)**: `CAPABILITY-EFFECTS-V2-DESIGN.md` implemented in full (WS-1 through WS-4 per `EFFECTS-CONFORMANCE-ROADMAP.md`). `Prefix`/`Set`/`Product` domains; parameter-level `check-policy`; `medaka manifest` TOML emission. Two sub-questions from §6a remain deferred: precision through wrappers (singleton-typed args) and the Wasm custom-section manifest format.
- **Manifest emission/consumption** — **TOML `[package.capabilities]` DONE (2026-06-21, `medaka manifest`)**. Open: Wasm custom-section embedding (touches `wasm_emit.mdk`, deferred until WasmGC backend); mapping to WASI component-model world declarations (no blocking work — `CAPABILITY-EFFECTS-RESEARCH.md` §1 has the dual-layer design).
- **Typeclass interaction** — effects in method signatures and how they interact
  with dict-passing.
- **The flagship runtime** — build vs. partner; which edge/plugin host to target
  first.

## 9. Next steps (historical — all items now done as of 2026-06-21)

Propagation/inference (§5 gap 1) shipped in Phase 79/79e; laundering soundness
(open/closed rows + closed-closed point-free via instantiation re-opening)
shipped this phase (§5a) — gap 1 is now sound, and the **compiler mirror is done**
(full subsystem ported, 2026-06-06, §5a). The sequence was:

1. **Fine-grained labels** (gap 2): ✅ **shipped 2026-06-06** — the `effect Foo`
   declaration form + resolve registration (reference + compiler mirror), so the
   manifest vocabulary is user/platform-definable. §3a / §5a. (Cross-module label
   export: ✅ **DONE** as gap 3, 2026-06-07 — see §5a and PLAN.md.)
2. **Research** (for the manifest layer): ✅ **DONE** — `CAPABILITY-EFFECTS-RESEARCH.md`
   covers WasmGC/WASI status, Cloudflare/Fastly/Fermyon isolation models,
   object-capability literature, Roc/MoonBit/Grain comparisons, and the manifest
   format (TOML `[package.capabilities]` + WIT world dual-layer).
3. **Design note + manifest format**: ✅ **DONE** — `CAPABILITY-EFFECTS-V2-DESIGN.md`
   is the full v2 design (parameterized effects + IO decomposition); manifest
   emission shipped 2026-06-21 (`medaka manifest`/`medaka check-policy` — WS-1a/1b/1c
   per `EFFECTS-CONFORMANCE-ROADMAP.md`). Wasm custom-section deferred (WasmGC backend).

