# Capability-safe effects — Medaka's headline direction

Status: **partially implemented** (Phase 146 in [`PLAN.md`](./PLAN.md)). Effect
*propagation/inference* already shipped (Phase 79/79e); the laundering-soundness
holes that made the manifest forgeable are closed for the open/closed AND
closed-closed point-free cases (the latter via variance-aware covariant re-open),
and the **selfhost mirror is done** (2026-06-06: full effect subsystem ported into
`selfhost/typecheck.mdk`, byte-identical harnesses). Remaining: user-definable
effect labels (gap 2) and manifest emission. See **§5a (current state)** for the
precise done/remaining split. Companion to [`language-design.md`](./language-design.md)
(effect rows as they exist today) and [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md)
(effects are erased before codegen).

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
- **An effect system in the types** (already present: `<IO>`, `<Mut>`, `<Rand>`,
  `<Panic>`, row-tail forms `<IO | e> a`).
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
   `<Fetch>`, `<Log>`, `<Clock>`). **Still open.** Today the vocabulary is a
   fixed list (`IO, Mut, Async, Panic, Rand, Time`) hardcoded in `resolve.ml`
   (`built_in_effects`), validated with `UnknownEffect`. Fix: an effect-label
   declaration form (`effect KV`) + resolve registration. `DExtern` is already a
   top-level decl, so a platform can declare `<KV>` host imports once labels are
   user-definable.

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
`@thorough`, and the selfhost typecheck/check/selfproc harnesses (no legitimate
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
scheme *accepts*, e.g. `VPrim (Value -> <Mut> Value)`) stay closed, preserving
safe subsumption (a pure argument into a `<Mut>`-allowing slot is fine).
Measurement surfaced exactly **one** genuine latent unsoundness in the selfhost
source — `concatMapList`'s pure callback signature hid a `<Mut>` effect — fixed
by making it effect-polymorphic (`(a -> <e> List b) -> List a -> <e> List b`).
Zero spurious regressions across all unit suites, `@thorough`, and the selfhost
harnesses (typecheck/check/check_modules/golden/selfproc/eval_run/eval_modules/
eval_dict). Tests: `test_typecheck.ml` `effects` group (`e_eff_leak_pointfree_*`,
`t_eff_subsume_pure_into_effectful_field`, `t_eff_over_annotation_pointfree`).

**Remaining:**
- **Selfhost mirror — DONE (2026-06-06).** The earlier note ("the `unify_row`
  subset rule and the instantiation re-opening are not yet mirrored") understated
  it: `selfhost/typecheck.mdk` had no effect rows at all. The full effect-tracking
  subsystem (Phase 79 propagation + 79e escape + 146 laundering) was ported in four
  committed stages (representation → propagation → escape → laundering). New
  fixtures `effect_leak`/`effect_escape` (reject) and `effect_subsume` (accept),
  verified against `dev/tc_probe.exe` first. Every `diff_selfhost_*` typecheck/
  error/golden/check/check_modules/selfproc/eval harness is byte-identical;
  `@thorough` green. The self-hosted typechecker now rejects laundering identically
  to the reference.
- **Gap 2 labels** — the `effect Foo` declaration form (above).
- **Manifest emission** — unbuilt (waits on the edge runtime, §9).

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
- **Effect-label declaration syntax** (`effect KV`?) and module/visibility rules.
- **Parameterized effects** — `<Fetch "api.example.com">` (capability *with*
  constraints) vs. plain `<Fetch>`. Big expressiveness gain, real complexity cost;
  probably a later layer.
- **Manifest emission/consumption** — concrete format the Wasm host reads, and how
  it maps to WASI / the component model's own capability story (don't reinvent what
  the component model already expresses).
- **Typeclass interaction** — effects in method signatures and how they interact
  with dict-passing.
- **The flagship runtime** — build vs. partner; which edge/plugin host to target
  first.

## 9. Next steps

Propagation/inference (§5 gap 1) shipped in Phase 79/79e; laundering soundness
(open/closed rows + closed-closed point-free via instantiation re-opening)
shipped this phase (§5a) — gap 1 is now sound. The remaining sequence:

1. **Selfhost mirror** of the `unify_row` subset rule + the instantiation
   re-opening into `selfhost/typecheck.mdk` (parity), with a laundering fixture.
2. **Fine-grained labels** (gap 2): the `effect Foo` declaration form + resolve
   registration, so the manifest vocabulary is user/platform-definable.
3. **Research** (for the manifest layer): WasmGC status + who targets it and how;
   WASI Preview 2 / component-model capability model; Cloudflare/Fastly/Fermyon
   isolation models; object-capability & effects-as-security literature; Roc's
   platform model; MoonBit + Grain (closest competitors — has either touched
   capability/effect safety?).
4. **Design note + manifest format**: concrete surface syntax + a worked plugin
   example + the manifest format, pressure-tested against 2–3 realistic plugin
   shapes, then the manifest emission/consumption when the edge runtime is built.
