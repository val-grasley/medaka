# Dictionary-Passing Semantics for Medaka Interfaces

**Status:** specification (theory-first). **Scope:** the elaboration of
constrained, interface-using source programs into an explicit
dictionary-passing core, and the conditions under which that elaboration is
sound and coherent.

## 0. Purpose and the non-derivation principle

Medaka's interface machinery — `interface`/`impl`, `=>` constraints,
`requires` — has been a recurring source of defects. The defects cluster:
return-position dispatch, nested/structured dictionaries, superclass
(`requires`) entailment, cross-module identity, and an eval-vs-emit split in
*where* a dispatch decision is made. These are symptoms of an implementation
that grew incrementally without one authoritative answer to two questions:

1. **What is a dictionary** (its shape), and
2. **How is evidence built and threaded** (its discipline).

This document fixes those answers **from the theory of qualified types**, not
from the current code. It is deliberately written without consulting
`resolve`, `method_marker`, `typecheck`, `dict_pass`, or either evaluator. The
intent is a target the implementation can be *audited against*. Where this
spec and the implementation disagree, that disagreement is a finding to
triage — the spec is not a description of present behavior.

Theory anchor: the **theory of qualified types** (Jones) and the
**dictionary-passing translation** for type classes (Wadler & Blott 1989; Hall,
Hammond, Peyton Jones, Wadler, "Type Classes in Haskell"). Dictionary passing
is exactly *evidence translation*: a constraint is discharged by constructing
an evidence value, and a class method is a projection out of that evidence.
"Theory, not code" is consistent with "anchored on prior work" — the theory is
external to Medaka's implementation.

Terminology bridge (Medaka surface → theory; no implementation terms):

| Medaka surface | This document |
|---|---|
| `interface C a` with methods | class `C` of arity-1 (the spec generalizes to n params) |
| `impl C T` | instance `C T` |
| `requires` on an interface | superclass predicate |
| `requires` on an impl / `=>` in a signature | instance context / qualifier predicate |
| dictionary (informal) | evidence value for a predicate |

---

## 1. Source language (the qualified fragment)

We model only what bears on dictionaries. Types and predicates:

```
τ  ::= a | T τ̄ | τ → τ              -- monotypes (a: type var; T: type ctor)
π  ::= C τ̄                          -- predicate: class C applied to type args
ρ  ::= P ⇒ τ                        -- qualified type
σ  ::= ∀ā. ρ                        -- type scheme
P  ::= {π₁, …, πₙ}                  -- predicate set (the constraint context)
```

A **class environment** `CE` records, for each class `C`:
- its parameter(s) `ā_C`,
- its **superclass predicates** `super(C) = {D₁ ā_C, …}` (Medaka `requires` on
  the interface), and
- its **method signatures** `m_i : ∀ā_C. C ā_C ⇒ τ_i` — every method's type
  mentions `C ā_C` as a constraint; `ā_C` may appear in argument position,
  result position, or not at all (see §5).

An **instance environment** `IE` records, for each declared `impl`, an
**instance declaration**

```
instance Q ⇒ C T̄        -- Q = the impl's own context (Medaka requires/=>)
```

where `T̄` are the instance head types and `Q` is the (possibly empty) set of
predicates the instance depends on. The instance also carries the method
implementations `{m_i ↦ e_i}` for `C`.

We write `⌜·⌝` for the core (target) language: source minus predicates, plus
explicit evidence abstraction and application (§7).

---

## 2. Evidence representation — what the theory dictates

This section answers question (1). The representation is **derived from the
entailment rules** of §3, not chosen for convenience: the shape of evidence is
whatever lets superclass and instance-context evidence be **resolved once at
construction** — reached thereafter by a projection or a captured closure — and
never re-resolved at the use site.

**Definition (dictionary).** Evidence for a predicate `C T̄` is a record

```
DictC⟨T̄⟩ = {
    methods:  m₁ ↦ v₁, …, mₖ ↦ vₖ    -- impl of each method at T̄, each closed over
                                       -- the instance-context evidence (§3 `inst`)
    supers:   D ↦ DictD⟨σ̄⟩            -- one per superclass D ā_C ∈ super(C),
                                       -- with σ̄ = [T̄/ā_C](D's args)
}
```

That is, a dictionary is **structured and nested**: it *contains* sub-evidence
for every predicate it transitively depends on — its superclasses appear as
`supers` sub-dicts, and its instance-context evidence is captured inside the
method closures — rather than naming them for later lookup. (Superclass head args
are written `[T̄/ā_C](D's args)`; for the common case `D ā_C` this is just `D T̄`.)

**Why nested, from the rules (not from code).** Entailment has two
non-assumption rules: superclass projection (§3, `super`) and instance use
(§3, `inst`). For `super` to be a total, side-effect-free *projection*
— `P ⊢ D T̄ ⇝ supers(e).D` — the `D`-evidence must already be *present inside*
the `C`-evidence. If instead a dictionary were a flat key (e.g. only an
instance identity) and superclass evidence were recovered by re-running
resolution at the use site, then:

- the use site re-derives `D T̄` independently of how the `C T̄` evidence was
  built, so the two can disagree when resolution is path-sensitive — a direct
  **coherence** break (§6); and
- nested constraints whose evidence is itself constraint-dependent (an
  instance context `Q` mentioning class parameters) cannot be reconstructed at
  all from a flat key: that evidence is captured in the method closures at
  construction time, and a flat impl-key discards it. This is the structural
  cause of the "nested element-dict" class of failures.

**Verdict:** evidence is a tree of dictionaries. Superclass predicates are
**`supers` fields**, resolved once at construction and thereafter only
projected; instance-context evidence is **captured in the method closures** at
construction, never re-resolved. A flat, impl-key representation is *unsound for
the general case* and admissible only as a representation **optimization** under
the side conditions of §8 (a dictionary with no superclasses whose methods
capture no context evidence is isomorphic to its instance identity, so it may be
represented by that identity — but the general shape is the tree).

Method values `v_i` are closed over their needed evidence — both the instance
context `Q` (captured at construction, §3 `inst`) and any constraints internal
to the method body — so projecting `methods.m_i` yields a directly-applicable
value. (Exception: a method whose *own* signature adds a constraint over a fresh
variable not fixed by the instance keeps that dictionary abstract; projection
then yields a value still awaiting that dict at the call site.)

---

## 3. Entailment: constructing evidence

The judgment

```
P ⊢ π ⇝ e
```

reads: under the in-scope predicate assumptions `P` (each available as an
evidence variable), predicate `π` is entailed, **witnessed by evidence `e`**.
`P` is the constraint context of the enclosing scope; its members are bound to
evidence variables `d_π`.

```
            (d_π : π) ∈ P
(assum)  ───────────────────
            P ⊢ π ⇝ d_π


            P ⊢ C T̄ ⇝ e        (D ā_C) ∈ super(C)
(super)  ──────────────────────────────────────────
            P ⊢ D T̄ ⇝ supers(e).D


            (instance Q ⇒ C T̄) ∈ IE
            φ a most-general matcher with  C τ̄ = φ(C T̄)
            for each πᵢ ∈ φ(Q):   P ⊢ πᵢ ⇝ eᵢ        -- ē = (e₁ … eₚ)
(inst)   ──────────────────────────────────────────────────────
            P ⊢ C τ̄ ⇝ DictC⟨τ̄⟩{
                  methods = φ(impl_C) closed over ē;
                  supers  = { D ↦ e_D | D ā_C ∈ super(C),
                                        P ⊢ [τ̄/ā_C](D ā_C) ⇝ e_D } }
```

Notes.

- **`assum`** is dictionary-variable use: a constraint already in scope is
  witnessed by its bound variable. This is the rule that makes a constrained
  function *receive* rather than *rebuild* its evidence.
- **`super`** is pure projection into the nested record — never a re-resolution.
  It is the formal meaning of `requires` on an interface.
- **`inst`** is the only rule that *builds* a fresh dictionary. It matches the
  goal against an instance head, recursively discharges the instance context `Q`
  (this evidence `ē` is captured in the method closures), fills `methods` from
  the impl, and fills each `supers.D` by resolving `D τ̄` through entailment — not
  through `super`, which would need the very dict being built. Its recursive
  premises are what force the representation to be a tree.

**Resolution determinism.** Entailment is intended to be a *function*: for a
given `(IE, CE, P, π)` at most one derivation exists up to evidence
equivalence (§6). `inst` must apply for at most one instance (no overlap), and
when both `assum`/`super` and `inst` could apply they must produce equivalent
evidence (the consistency condition of §6). Where multiple derivations exist
but agree, resolution picks any; where they could disagree, the program is
rejected as incoherent — it is **not** left to the evaluator to choose.

**Well-formedness (for entailment to be a total function).** Beyond non-overlap
(§6 C1), resolution is decidable only if (W1) the **superclass relation is
acyclic** — otherwise `super`-search loops — and (W2) **instance resolution
terminates** — each `inst` premise `πᵢ ∈ φ(Q)` must be structurally smaller than
the goal (a Paterson/coverage-style condition), otherwise the recursive
discharge of `Q` diverges. W1 + W2 + C1 together make entailment the function the
elaboration of §4 assumes it to be.

---

## 4. Elaboration: typing-with-translation

The judgment

```
P | Γ ⊢ e ⇝ e' : τ
```

elaborates source term `e` to core term `e'`. `Γ` binds variables to schemes;
`P` is the ambient constraint context (with evidence variables). The rules of
interest are those that *introduce* or *consume* dictionaries; ordinary
Hindley–Milner rules carry the translation through unchanged.

```
            x : ∀ā. Q ⇒ τ  ∈ Γ        S = [τ̄/ā]  (instantiation)
            for each πᵢ ∈ S(Q):   P ⊢ πᵢ ⇝ eᵢ
(var)    ────────────────────────────────────────────────
            P | Γ ⊢ x ⇝ x e₁ … eₙ : S(τ)


            P' = the predicates deferred to this binding (its principal context)
            (P, P') | Γ ⊢ e ⇝ e' : τ
(gen)    ───────────────────────────────────────────────────────────────
            P | Γ ⊢ (let x = e) ⇝ (let x = Λā. λ(d₁:π₁)…(dₘ:πₘ). e') : …
                where {π₁..πₘ} = P',  ā = generalizable vars


            P' = predicates deferred to the (mutually) recursive group
            d̄ = (d₁:π₁)…(dₘ:πₘ) fresh for P'
            (P, P') | Γ, x : ∀ā. P' ⇒ τ ⊢ e ⇝ e' : τ
            -- every recursive occurrence of x in e' is elaborated by (var) to
            -- (x d₁ … dₘ): the SAME dict params, NOT a fresh entailment
(gen-rec)──────────────────────────────────────────────────────────────────
            P | Γ ⊢ (let rec x = e) ⇝ (let rec x = Λā. λ d̄. e')
```

Reading.

- **`var`** is the **point of evidence application**. A use of a constrained
  binding instantiates its scheme, and *each residual predicate is discharged
  by entailment (§3)* and applied as an extra leading argument. The evidence is
  determined entirely by the instantiation `S` and the ambient `P` at the use
  site — statically, before evaluation.
- **`gen`** is the **point of evidence abstraction**. When a binding is
  generalized over a constraint set `P'`, the elaborated term abstracts a
  dictionary parameter for each predicate. Inside the body those parameters
  populate `P` and are consumed by `assum`. This is the dual of `var`: producers
  abstract, consumers apply, and the two must agree on **order and arity** of
  the dictionary parameters (§8 makes this a per-binding, identity-keyed fact —
  the source of the cross-module collision when arity is keyed by bare name).

- **`gen-rec`** is `gen` for a (mutually) recursive group, and it is the rule the
  recurring mutual-recursion dictionary bugs (#44) turn on. The recursive
  occurrences of `x` inside its own body must be applied to the **same** dict
  params `x` abstracts — `var` resolves them to the in-scope `d₁…dₘ`, **not** a
  fresh entailment. Re-resolving instead rebuilds a divergent or duplicated
  dictionary at each recursive step (non-termination, or evidence that disagrees
  with the caller's). A mutually-recursive group shares **one** `λ d̄.` prefix
  over the whole group.

The arity and order of `(d₁:π₁)…(dₘ:πₘ)` are part of the binding's elaborated
type and **travel with the binding's identity**, not its surface name.

---

## 5. Method dispatch, including return position

A class method `m : ∀ā_C. C ā_C ⇒ τ_m` is, at the core level, a **projection**:

```
            P ⊢ C T̄ ⇝ e
(method) ──────────────────────────────
            ⌜m at C T̄⌝  =  methods(e).m
```

The dispatch type is `C`'s parameter `ā_C := T̄`. Crucially, **`T̄` is fixed by
the instantiation of `C` at the use site (§4 `var`), regardless of where `ā_C`
appears in `τ_m`.** Three cases:

- **Argument position** (`ā_C` occurs in an argument of `τ_m`, e.g. `eq : a → a
  → Bool`): the dispatch type is recoverable from a runtime argument's head, so
  arg-tag dispatch is a *sound refinement* (see below).
- **Result position** (`ā_C` occurs only in the result, e.g. `pure : a → F a`
  with class on `F`, or a `fromInt : a` with class on the result `a`): there is
  **no argument** whose runtime tag reveals the instance. Dispatch is possible
  *only* because `e` was determined statically by `var`/entailment. This is the
  formal reason return-position dispatch must go through the dictionary and
  cannot be an evaluator-time argument inspection.
- **Phantom position** (`ā_C` absent from `τ_m`): same — only the static
  dictionary determines it.

**Arg-tag dispatch is an optimization, not a semantics.** Inspecting a runtime
value's constructor to select an impl is sound **iff** the class parameter
occurs in an argument position whose head constructor uniquely determines the
instance head, *and* that argument is evaluated. It is a refinement of
`(method)` valid under a side condition. It is **never** the meaning of
dispatch and must never be the *only* mechanism, because result/phantom-position
methods have no such argument. A semantics that decides dispatch in the
evaluator is therefore wrong in general; §7 makes the evaluator dictionary-
directed and demotes arg-tag to an admissible optimization.

---

## 6. Coherence

**Definition (coherence).** Elaboration is *coherent* if the meaning of a
source program is independent of the elaboration derivation: whenever
`P | Γ ⊢ e ⇝ e₁ : τ` and `P | Γ ⊢ e ⇝ e₂ : τ`, then `e₁ ≡ e₂` (observationally
equivalent in the core). Equivalently, every predicate has a *unique* evidence
value up to `≡`.

Coherence is the property the recurring bugs violate. It is guaranteed by the
following conditions; the implementation must enforce them or reject the
program.

- **C1 — Unique instances (no overlap).** For any ground `C τ̄`, at most one
  instance head in `IE` matches. (Overlap makes `inst` nondeterministic and
  breaks uniqueness directly.)
- **C2 — Superclass consistency (an invariant, largely implied by C1+C3+C4).**
  For every instance `Q ⇒ C T̄` and every `D ā_C ∈ super(C)`, the evidence in
  `supers.D` must be `≡` to resolving `D T̄` independently via §3 — the nested
  superclass dict equals the canonical `D`-dict. Since `supers.D` *is* built by
  that same resolution under one global `IE`, C2 follows from deterministic
  resolution (C3) over unique instances (C1, C4); it is the invariant to check,
  not an independent obligation. The **transitive (diamond) form** is the part
  worth stating outright: if `C` reaches a base class `B` along two superclass
  paths (via `D` and via `E`), both must yield `≡` `B`-evidence — again
  guaranteed by C1+C3, but the first thing a flat or path-sensitive
  representation breaks.
- **C3 — Resolution determinism.** Entailment (§3) returns the same evidence
  regardless of search order; with C1 holding, `inst` is deterministic and
  `assum`/`super` agree with `inst` by C2.
- **C4 — Single instance environment.** `IE`/`CE` are *global* after import
  resolution (§8). Two modules resolving the same predicate must consult the
  same instance set and produce the same evidence — otherwise C1/C2 hold only
  locally and coherence fails across module boundaries.

**Coherence theorem (target).** If C1–C4 hold, elaboration is coherent.

---

## 7. Core operational semantics and the single-evaluator law

The core language is the source minus predicates, plus: dictionary records
(§2), evidence abstraction `λ(d:π). e'` and application `e' e`, field
projection `methods(e).m` / `supers(e).D`. Dictionaries are
**ordinary values**; there is nothing class-specific in the core's evaluation
rules.

```
(proj)   methods(DictC{…, m ↦ v, …}).m  ⟶  v
(papp)   (λ(d:π). e') V                  ⟶  e'[d ↦ V]
```

**The single-evaluator law.** *All dispatch is resolved during elaboration
(§3–§5). The core evaluator makes no dispatch decision; it only constructs,
projects, and applies dictionary values.* Consequently:

- Any concrete evaluator (a tree-walker, a native code emitter) is a *refinement
  of one core semantics*. Two evaluators may differ in representation and speed
  but must agree, value-for-value, on every elaborated core program.
- A dispatch decision taken at evaluation time (e.g. selecting an impl by
  inspecting a runtime tag *instead of* projecting a statically-built
  dictionary) is admissible **only** as an optimization that provably refines
  `(method)` under §5's side condition, and must be applied **identically** by
  every evaluator. A fork in which one evaluator threads dictionaries and
  another decides by argument tag is, by this law, two different semantics — a
  spec violation, even if they happen to agree on tested programs.

This law is the formal statement of the unification the implementation has been
moving toward: elaboration is the *only* place dispatch is decided, and the
evaluators are interchangeable refinements.

---

## 8. Identity, arity, and cross-module elaboration

Dictionary discipline is a property of **bindings**, and bindings have
module-qualified identity.

- **I1 — Evidence abstraction is keyed by binding identity.** The dictionary
  parameters a generalized binding abstracts (§4 `gen`) — their count, order,
  and predicates — are part of *that binding's* elaborated type, identified by
  its module-qualified name, never by its bare name. Two distinct bindings that
  share a surface name (different modules) have independent dictionary arities.
  Conflating them (keying arity by bare name) forces phantom dictionary
  parameters onto an unconstrained binding, whose use sites then under- or
  over-apply — a coherence and a type-preservation break at once.

- **I2 — Global instance environment after import resolution.** Per C4, `IE`
  and `CE` are assembled across the whole import graph before entailment runs.
  Instance lookup in `inst` uses qualified instance identity; method projection
  uses the resolved class. Import scoping affects *visibility* of names, not the
  *identity* of the evidence a predicate resolves to.

- **I3 — Evidence travels, it is not re-derived.** When a constrained binding
  crosses a module boundary, its callers discharge its residual predicates from
  *their* ambient `P` (§4 `var`); the binding itself does not re-resolve them.
  This keeps a single derivation per predicate-occurrence and preserves C2/C3
  across modules.

---

## 9. Soundness statements (targets for a later proof/audit)

- **Type preservation.** If `P | Γ ⊢ e ⇝ e' : τ`, then in the core,
  `⌜Γ⌝, (d:π for π∈P) ⊢ e' : ⌜τ⌝`. Elaboration maps a well-typed qualified
  program to a well-typed core program with dictionaries explicit.
- **Semantic adequacy.** `e'` computes the value the source program denotes
  under its intended class semantics; method calls reduce to the impl selected
  by the statically-determined instance.
- **Coherence.** Under C1–C4, the elaboration is unique up to `≡` (§6), so
  "the value the source denotes" is well-defined.
- **Evaluator interchangeability.** Under the single-evaluator law (§7), any two
  refining evaluators agree on every elaborated program.

---

## 10. How to read the recurring defects against this spec

**Audit completed 2026-06-21 — see [`DICT-CONFORMANCE-AUDIT.md`](DICT-CONFORMANCE-AUDIT.md); all D1–D10 divergences closed.** The lens below remains useful for diagnosing future regressions.

Each known trouble area maps to a
specific clause; that mapping is the audit's starting point.

- **Return-position dispatch** → §5: dispatch must come from the static
  dictionary; an evaluator that can only inspect arguments cannot do
  result/phantom position. Suspect any path where dispatch is argument-directed.
- **Nested / element dictionaries** → §2 + §3 `inst`: evidence is a tree —
  superclass sub-dicts in `supers`, instance-context evidence captured in method
  closures; a flat impl-key discards the captured context and cannot reconstruct
  it. Suspect flattening.
- **Mutually-recursive constrained bindings** → §4 `gen-rec`: recursive uses must
  reuse the group's dict params, not re-resolve. Suspect a recursive call site
  that re-enters entailment instead of passing `d₁…dₘ`.
- **Superclass (`requires`) entailment** → §3 `super` + C2: superclass access is
  projection of a field that must equal the canonical dict. Suspect re-resolution
  at the use site.
- **Cross-module same-name collision** → §8 I1: dictionary arity keyed by bare
  name instead of binding identity. Suspect any bare-name arity table.
- **Eval-vs-emit dispatch fork** → §7 single-evaluator law: dispatch decided in
  an evaluator rather than in elaboration. Suspect any evaluator-time impl
  selection that is not a uniformly-applied, side-condition-guarded refinement
  of `(method)`.

---

## References

- P. Wadler, S. Blott. *How to make ad-hoc polymorphism less ad hoc.* POPL 1989.
  (The dictionary-passing translation.)
- M. P. Jones. *Qualified Types: Theory and Practice.* (Evidence/entailment,
  the `P ⊢ π` discipline and the coherence problem.)
- C. Hall, K. Hammond, S. Peyton Jones, P. Wadler. *Type Classes in Haskell.*
  (Class/instance environments, superclasses, the translation in practice.)
