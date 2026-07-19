# Dictionary-Passing Semantics for Medaka Interfaces

**Status:** specification (theory-first). **Scope:** the elaboration of
constrained, interface-using source programs into an explicit
dictionary-passing core, and the conditions under which that elaboration is
sound and coherent — including overlapping instances resolved by
most-specific-wins specialization (§3, §6).

## 0. Purpose and the non-derivation principle

Medaka's interface machinery — `interface`/`impl`, `=>` constraints,
`requires` — has been a recurring source of defects. The defects cluster:
return-position dispatch, nested/structured dictionaries, superclass
(`requires`) entailment, cross-module identity, selection among overlapping
instances, and an eval-vs-emit split in *where* a dispatch decision is made.
These are symptoms of an implementation
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

**Revision (2026-07-16): overlapping instances are specified.** Overlap with
specialization — `impl Foo Int` alongside `impl Foo a`, the more specific
instance winning — is an **intended Medaka feature** (owner decision); the
implementation deliberately accepts such pairs. The original spec forbade all
overlap (the old C1), which left the tie-break *unspecified* — and "overlap
makes `inst` nondeterministic" was not a hypothetical: with no written
tie-break, the implementation's several resolution paths diverged on which
overlapping instance wins (#203, an S0 across all four execution paths). This
revision defines the specificity order (§3), makes `inst` select by it, and
relaxes C1 (§6) to "unique most-specific match", so that entailment remains a
**total, coherent function** and every resolution position — top-level,
argument, return, nested `requires`, superclass projection — is obligated to
the *same* winner. Points where a defensible alternative design exists are
collected in §6.1 rather than silently chosen.

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
implementations `{m_i ↦ e_i}` for `C`. Distinct instances of the same class
**may have overlapping heads** (two heads that unify); §3's specificity order
and §6 C1 govern when that is legal and which instance a goal resolves to.

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

**Uniformity of nested resolution.** Every piece of sub-evidence in the tree —
each `supers.D` field, and each instance-context dict captured in a method
closure — is built by the **same entailment judgment** (§3) as a top-level
goal, at the types of the *construction site's* goal instantiation. Under
overlapping instances this is load-bearing: a nested obligation (the
`requires` context of a general instance, discharged at a now-concrete type)
must select the most-specific instance at that type exactly as a top-level
goal there would. Sub-evidence is therefore **never pre-baked at the instance
declaration** against the general head — a polymorphic instance's context and
supers are resolved per construction goal — and never resolved by a different
lookup (first-match, declaration order, "the instance syntactically at hand")
than top-level goals use. A construction path with its own weaker lookup
agrees with top-level resolution on non-overlapping instance sets and
diverges precisely under overlap; that is the defect class of #203 (§10).

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

### Specificity

Instance heads may overlap; the `inst` rule below therefore needs a
**tie-break**, and the tie-break must be a property of the instances and the
goal alone — never of search order, declaration order, or resolution position.

**Definition (specificity, `⊑`).** For instances `I_A = (Q_A ⇒ C Ā)` and
`I_B = (Q_B ⇒ C B̄)` of the same class (head variables taken disjoint),

```
I_A ⊑ I_B    iff    ∃σ.  σ(C B̄) = C Ā
```

— `I_A` is *at least as specific as* `I_B` iff `I_A`'s head is a substitution
instance of `I_B`'s head. The relation compares **heads only**; the contexts
`Q_A`, `Q_B` play no role (§6.1, choice-point 1). Write `I_A ⊏ I_B`
(*strictly more specific*) for `I_A ⊑ I_B ∧ ¬(I_B ⊑ I_A)`.

`⊑` is a **preorder on instances** — reflexive (`σ = id`) and transitive
(compose the substitutions) — and descends to a **partial order** on heads
up to renaming: mutual substitution instances are equal up to a variable
bijection (antisymmetry modulo α). Two instances with α-equal heads are
`⊑`-equivalent yet distinct, which C1 (§6) rejects as ambiguous — duplicate
heads never tie-break.

For a goal `π = C τ̄`, define the **matching set**

```
match(IE, π) = { I ∈ IE  |  ∃φ.  φ(head(I)) = π }
```

Overlap — `|match(IE, π)| > 1` at some goal — is **permitted**. What §6 C1
requires is a unique winner: `match(IE, π)` must have a **unique ⊑-minimal
element**, the goal's *most-specific matching instance*, written
`min⊑(match(IE, π))`. (The matching set is finite, and in a finite preorder a
unique minimal element is a minimum — equivalently, one matching instance is
`⊑` every other matching instance.) If two `⊑`-incomparable instances match
and no matching instance lies `⊑`-below both, no minimum exists and the goal
is **ambiguous overlap** — rejected, not chosen from.

*Example (the #203 shape).* Let `IE` contain `DL_a = (Default a ⇒ Default
(List a))` and `DL_Int = (Default (List Int))`. Then `DL_Int ⊏ DL_a` (via
`σ = [Int/a]`). The ground goal `Default (List Int)` is matched by both;
`min⊑` is `DL_Int`, so **its** evidence witnesses the goal — at *every*
resolution position: as a top-level goal, and equally as the nested context
obligation that arises when `DL_a` is selected for the goal
`Default (List (List Int))` (matched only by `DL_a`) and its context
`Default a` is discharged at `a := List Int`. A path that hands that nested
obligation to `DL_a`'s evidence has changed the program's meaning.

### The rules

```
            (d_π : π) ∈ P
(assum)  ───────────────────
            P ⊢ π ⇝ d_π


            P ⊢ C T̄ ⇝ e        (D ā_C) ∈ super(C)
(super)  ──────────────────────────────────────────
            P ⊢ D T̄ ⇝ supers(e).D


            I = (instance Q ⇒ C T̄) ∈ IE
            I = min⊑(match(IE, C τ̄))      -- the unique most-specific match;
                                          -- none/no-unique ⇒ rule inapplicable
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
- **`inst`** is the only rule that *builds* a fresh dictionary. It selects the
  goal's **unique most-specific matching instance** `I` — when the matching set
  has no `⊑`-minimum the program is rejected as ambiguous overlap (§6 C1) —
  and resolves to *`I`'s* evidence: it recursively discharges **`I`'s own
  context `φ(Q)`** at the goal's (specific) instantiation through this same
  judgment — so nested obligations themselves resolve most-specifically —
  captures that evidence `ē` in the method closures, fills `methods` from
  `I`'s impl, and fills each `supers.D` by resolving `D τ̄` through entailment
  — not through `super`, which would need the very dict being built. Its
  recursive premises are what force the representation to be a tree.

**Resolution determinism.** Entailment is intended to be a *function*: for a
given `(IE, CE, P, π)` at most one derivation exists up to evidence
equivalence (§6) — now **the unique most-specific derivation**, not the
unique derivation. Instance heads may overlap; `inst` stays deterministic not
by forbidding overlap but through its minimality premise: it applies only for
`min⊑(match(IE, π))`, which §6 C1 requires to exist uniquely wherever `inst`
fires. Two `⊑`-incomparable matches with no common `⊑`-lower match are
**ambiguous overlap** and the program is rejected — most-specific-wins is a
total tie-break, never "pick one". That reject is an `inst`-vs-`inst` rule and
scopes to `inst` alone.

When both `assum`/`super` and `inst` could apply, **`assum`/`super` takes
precedence**: a predicate already in scope is used, and `inst` fires only when
no assumption matches (GHC's rule). This is what makes this section's "nested
obligations themselves resolve most-specifically" realisable, and with it
§2's "never pre-baked at the instance declaration": inside the body of a
parametric instance the `requires` context is *in scope as an assumption*, so
the body forwards the dict built at the **construction site's** goal rather
than re-resolving its own rigid goal through `inst` to the general instance.
The two are therefore not in tension — they resolve at different types, and
`assum` is the one holding the construction goal's evidence. Note the
precedence is only reachable when an assumption actually **matches** the goal:
matching is structural, on rigid variables, never unification (§6.1.3) — given
`S a`, the goal `S (List a)` is *not* an assumption in scope, `assum` stays
silent, and `inst` correctly commits to the general instance.

In particular, the choice among overlapping instances is made **here, once,
during elaboration** — never re-made per resolution position, per engine, or at
run time (§6 "uniform resolution", §7).

**Well-formedness (for entailment to be a total function).** Beyond unique
most-specific matches (§6 C1), resolution is decidable only if (W1) the
**superclass relation is acyclic** — otherwise `super`-search loops — and (W2)
**instance resolution terminates** — each `inst` premise `πᵢ ∈ φ(Q)` (the
context of the *selected* instance) must be structurally smaller than the goal
(a Paterson/coverage-style condition), otherwise the recursive discharge of
`Q` diverges. Most-specific selection itself adds no termination risk:
`match(IE, π)` is a finite subset of a finite `IE`, membership is one
one-sided matching problem per instance, and `⊑` between two heads is one
more — so `min⊑` is computed by finitely many decidable comparisons, before
any recursion. W1 + W2 + C1 together make entailment the function the
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


            x :: ∀ā. Q_sig ⇒ τ   (ascribed signature)
            P'ᵢ = the predicates the body infers on ā
            Q_sig ⊩ P'ᵢ          (entailment under `requires`-closure, §3)
            (P, Q_sig) | Γ ⊢ e ⇝ e' : τ
(gen-sig)───────────────────────────────────────────────────────────────────
            P | Γ ⊢ (let x : Q_sig ⇒ τ = e) ⇝ (let x = Λā. λ d̄_sig. e')
                where d̄_sig = (d₁:π₁)…(dₖ:πₖ),  {π₁..πₖ} = Q_sig
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

- **`gen-sig`** is `gen` for a binding carrying an **ascribed signature** (#619).
  The distinction from `gen` is which set becomes the binding's principal context.
  `gen` reads it off the body (`P'` = the inferred deferred predicates); `gen-sig`
  takes it **from the signature**: `Q_sig` — not the inferred `P'ᵢ` — is the
  principal context, so the abstracted dictionaries `d̄_sig`, the displayed scheme,
  and every caller's discharged predicates (`var`) all come from `Q_sig`. A
  signature is a **contract the body must satisfy, not a floor it can raise** (the
  standard qualified-types reading — Jones; Hall–Peyton-Jones–Wadler). The body's
  inferred `P'ᵢ` is therefore **checked, not merged**: the side condition
  `Q_sig ⊩ P'ᵢ` demands every inferred predicate be entailed by the ascribed
  context, closed under `requires` (§3). If it fails — the body genuinely needs a
  predicate `Q_sig` does not license — the program is **rejected**
  (`T-MISSING-CONSTRAINT`), never silently widened to `Q_sig ∪ P'ᵢ`. Two
  consequences fall out, and both are the point of the rule:
    - a declared predicate the body never dispatches on is **still abstracted** —
      it is part of the contract (`sz2 : Sz a ⇒ a → Int` whose body ignores `Sz`
      still has `Sz a` in its scheme and every caller discharges it);
    - a predicate the body infers that `Q_sig` **already entails via a superclass**
      is **dropped, not displayed** (`when : Thenable m ⇒ …` whose body's `pure`
      infers `Applicative m` has scheme context exactly `Thenable m`, since
      `Thenable requires Applicative`). Merging it in — the pre-#619 behaviour —
      was sound but produced a redundant `(Applicative m, Thenable m) ⇒` display
      and propagated a superclass-redundant predicate to every caller.
  When `Q_sig` is empty the rule degenerates to the ordinary monomorphic-signature
  case, and `gen-sig` still fires (a signed binding with no `⇒` has principal
  context `∅`, so a body that infers **any** predicate on `ā` is rejected — the
  usual `Could not deduce … add '… ⇒'` error).

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
**most-specific matching instance** (§3), *and* that argument is evaluated.
Overlap narrows this side condition sharply: a head tag alone does not
separate overlapping instances below one constructor — a `List` tag cannot
distinguish the `List Int` instance from the `List a` instance — so for any
class with such overlap, arg-tag selection at that constructor is *unsound*,
not merely incomplete. It is a refinement of `(method)` valid under a side
condition. It is **never** the meaning of
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

- **C1 — Unique most-specific instance.** For any ground `C τ̄`, the matching
  set `match(IE, C τ̄)` (§3) has a **unique ⊑-minimal element** —
  equivalently (the set is finite), a `⊑`-minimum: one matching instance at
  least as specific as every other. Overlap — more than one matching head —
  is permitted *iff* this holds. Two `⊑`-incomparable matching instances with
  no matching instance `⊑`-below both make the goal **ambiguous overlap**,
  and the program is rejected; so are α-equal duplicate heads (mutually `⊑`,
  no *unique* minimal instance). This is the retained coherence guarantee:
  most-specific-wins is a total tie-break, not a licence to pick. (The old
  C1 — "at most one match" — is the special case where every matching set is
  a singleton, which is why the relaxation is conservative over previously
  legal programs.)
- **C2 — Superclass consistency (an invariant, largely implied by C1+C3+C4).**
  For every instance `Q ⇒ C T̄` and every `D ā_C ∈ super(C)`, the evidence in
  `supers.D` must be `≡` to resolving `D T̄` independently via §3 — the nested
  superclass dict equals the canonical `D`-dict. Since `supers.D` *is* built by
  that same resolution under one global `IE`, C2 follows from deterministic
  resolution (C3) over unique most-specific matches (C1, C4); it is the invariant to check,
  not an independent obligation. The **transitive (diamond) form** is the part
  worth stating outright: if `C` reaches a base class `B` along two superclass
  paths (via `D` and via `E`), both must yield `≡` `B`-evidence — again
  guaranteed by C1+C3, but the first thing a flat or path-sensitive
  representation breaks. Under overlap, C2 additionally pins **which**
  `D`-dict: `supers.D` must be the evidence of the *most-specific*
  `D`-instance at the construction goal's instantiation — which is exactly
  what §3 builds, since `supers` is filled by entailment at construction, not
  pre-baked against the (possibly general) instance head at its declaration.
  A super-projection that reaches a general `D`-dict while an independent
  top-level goal `D τ̄` resolves to a specific one is a C2 violation even
  though both are `D`-evidence; no genuine most-specific/C2 conflict remains
  once supers are resolved per construction goal (§6.1, point 4).
- **C3 — Resolution determinism.** Entailment (§3) returns the same evidence
  regardless of search order; with C1 holding, `inst` is deterministic — the
  `⊑`-minimum is unique, so most-specific selection cannot reintroduce order
  sensitivity. Where more than one rule could fire, determinism does **not**
  rest on the rules agreeing: §3's **precedence** (`assum`/`super` before
  `inst`) makes the choice, so entailment is a function of the goal *and the
  scope* `P`, never of search order. `assum` and `super` both discharge a goal
  with evidence resolved at the **construction site's** instantiation; C2 is
  what pins that evidence to be the most-specific one *there*. Neither is
  required to equal what an independent `inst` would build at a **rigid**
  use-site goal — and where they differ, the in-scope evidence wins (§3). That
  is exactly what makes §2's uniformity of nested resolution realisable, and it
  is not an incoherence: coherence quantifies over derivations of the **same**
  judgment, and a rigid use-site goal and the construction goal its evidence was
  built at are different judgments (§6.1.3).
- **C4 — Single instance environment.** `IE`/`CE` are *global* after import
  resolution (§8). Two modules resolving the same predicate must consult the
  same instance set and produce the same evidence — otherwise C1/C2 hold only
  locally and coherence fails across module boundaries.

**Uniform resolution (corollary of C1+C3+C4 and the single judgment).** There
is exactly one entailment judgment (§3), and *every* resolution position
consults it: a top-level goal, a `var`-site residual predicate (§4), a method
dispatch whether the class parameter sits in argument, result, or phantom
position (§5), a nested instance-context (`requires`) obligation (§3 `inst`),
and a superclass projection target (C2). All of them therefore resolve a
given goal to the same — most-specific — evidence. This corollary is worth
stating because it is what #203 violated: an implementation with several
resolution code paths must make **all** of them perform `min⊑` selection; a
path that agrees with the others on non-overlapping instance sets but falls
back to first-match (or declaration order, or crashes) under overlap is
exactly the defect class of §10.

**Coherence theorem (target).** If C1–C4 hold, elaboration is coherent.
(Argument sketch under overlap: W1+W2+C1 make entailment total on the goals
elaboration poses, and a function of `(IE, CE, P, π)` — `assum` is keyed by
`P`, `super` by the already-unique sub-derivation, and `inst` by the unique
`⊑`-minimum, which no search order can vary (C3). C4 fixes one global `IE`,
so "the" minimum is the same at every site. Two derivations of the same
judgment thus produce `≡` evidence pointwise, and elaborated terms differ at
most in the derivation path, not the evidence — the same argument as the
non-overlapping theorem with "the unique match" replaced by "the unique
minimum".)

### 6.1 Design choice-points in the overlap regime (owner-visible)

Most-specific-wins has principled variants. This spec commits to the choices
below; each is **flagged** because a defensible alternative exists and moving
to it later is a semantics change, not a bug fix.

1. **Specificity compares heads only, not contexts.** `⊑` (§3) ignores the
   instance contexts `Q` — this matches the motivating intuition
   (`impl Foo Int ⊏ impl Foo a`) and GHC's `OVERLAPPING` regime.
   *Alternative:* treat a more-constrained instance as more specific
   (`Eq a ⇒ C (List a)` beating `C (List a)`). **Rejected here:** the winner
   would then depend on what is *provable* at the goal site, making selection
   a function of the ambient `P` rather than of `(IE, π)` — the same ground
   goal could resolve differently under different contexts, which forfeits C3
   and reintroduces path-sensitivity, the exact disease this revision cures.
   Consequence to accept knowingly: two instances with α-equal heads and
   different contexts are *ambiguous*, never ranked. **Recommended: head-only
   (as specified).**

2. **Per-goal unique minimum, not total order, not global comparability.**
   Three candidate coherence conditions, strongest first:
   - (a) *global comparability*: any two instances of a class whose heads
     unify must be `⊑`-comparable — checkable once at declaration time,
     earliest errors; implies (b);
   - (b) *per-goal total order*: at every ground goal the matching set is
     totally ordered by `⊑`; implies (c);
   - (c) *per-goal unique minimum*: at every ground goal the matching set has
     a unique `⊑`-minimal element — what C1 states.
   (c) is exactly what `inst`-determinism requires — no more. The separating
   case: `C (Pair Int a)`, `C (Pair a Int)`, `C (Pair Int Int)` all declared.
   At the goal `C (Pair Int Int)` the first two are incomparable, but the
   third is `⊑` both — (c) accepts with an unambiguous winner; (a)/(b)
   reject. **Recommended: (c) as the semantics** (it is also GHC's condition),
   with the check performed at each `inst` application during elaboration —
   still fully static, never at run time. An implementation MAY additionally
   warn at declaration time on (a)-violations as an early diagnostic, but
   acceptance is per-goal. Note the task-level intuition "overlap is allowed
   iff totally ordered by specificity at each ground goal" is condition (b):
   sound, slightly stronger than needed, and the difference only shows on
   instance sets like the `Pair` triple above.

3. **Non-ground goals: selection commits at the elaboration site
   (specialization is not retroactive).** `inst` fires on the goal *as it
   stands where it is resolved*. A goal over **generalizable** variables is
   deferred by §4 `gen` (abstracted as a dict parameter) — standard, and it
   preserves the caller's ability to supply most-specific evidence. But a
   goal over a **rigid** (signature-bound) variable — e.g. `Default (List a)`
   inside `f : ∀a. Default a ⇒ …` — matches only the general instance and is
   discharged there, once, when `f` is elaborated. If `f` is later used at
   `a := Int`, `f`'s body still runs the general instance's evidence (closed
   over the caller's `Default Int` dict); it is **not** retroactively
   re-resolved to `Default (List Int)`. So a ground predicate can receive
   different evidence at two *different* judgments — one where it was ground
   at resolution time, one arising by instantiating an already-elaborated
   polymorphic binding. This does **not** violate §6 coherence (which
   quantifies over derivations of the *same* judgment) and is the standard
   price of specialization under separate elaboration — GHC behaves
   identically — but it is real and observable, and this spec states it
   loudly rather than letting it be discovered.
   *Alternatives:* (i) reject `inst` at any non-ground goal that a strictly
   more specific instance *unifies* with (a substitution-stability
   requirement) — restores "one evidence per ground predicate, globally" but
   rejects most of the generic code that motivates the general instance at
   all, since such code is precisely "use `C (List a)` at unknown `a`";
   (ii) monomorphize/re-elaborate per instantiation — whole-program
   compilation, incompatible with §8's separate, identity-keyed elaboration.
   **Recommended: commit-at-elaboration-site (as specified). FLAG:** this is
   the one place most-specific-wins is weaker than it may look from the
   surface; the owner should confirm this trade explicitly.

4. **Superclasses and diamonds under overlap — no conflict, one obligation.**
   Could most-specific selection fight C2? Only if sub-evidence were resolved
   at a different goal than top-level evidence. The rule that prevents it:
   supers and instance contexts are discharged **at the construction goal's
   instantiation** (§3 `inst`, §2 "uniformity"), so a general `C`-instance
   constructed at a ground goal carries the *specific* `D`-super-dict for
   that ground type, and both arms of a superclass diamond resolve `B` through
   the same judgment at the same types, yielding `≡` evidence (C1+C3). The
   tempting-but-wrong implementation is pre-resolving a polymorphic
   instance's supers once, against its general head, at declaration — that
   turns every ground construction into a C2 violation under overlap. (At a
   *rigid-variable* construction goal the super-dict is the general one, by
   point 3 — consistently with what top-level resolution at that same goal
   would produce, so uniformity is preserved there too.)

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

Most-specific selection is part of elaboration, hence inside this law:
`min⊑` (§3) is computed once, statically, and its result is frozen into the
elaborated core. No evaluator, backend, or optimization level may re-derive,
re-order, or approximate it — an overlapping-instance program on which the
engines disagree (as in #203, where the tree-walker, the Core-IR interpreter,
and native at different opt levels each did something different) is by this
law a spec violation of exactly the same kind as an eval-vs-emit dispatch
fork, regardless of which engine happens to print the intended value.

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
  by the statically-determined, most-specific instance (§3).
- **Coherence.** Under C1–C4, the elaboration is unique up to `≡` (§6), so
  "the value the source denotes" is well-defined.
- **Evaluator interchangeability.** Under the single-evaluator law (§7), any two
  refining evaluators agree on every elaborated program.
- **Signature authority (§4 `gen-sig`, #619).** For a binding with an ascribed
  signature, its principal context is the declared `Q_sig`, and elaboration abstracts
  exactly `Q_sig`. The body's inferred context `P'ᵢ` is admitted **iff** `Q_sig ⊩ P'ᵢ`
  (`requires`-closed entailment, §3); otherwise the program is rejected. Equivalently:
  a well-typed signed binding never has a scheme context that differs from — is neither
  a superset nor a subset of — the predicates it wrote, so no caller discharges a
  predicate the author did not declare, and none is silently dropped that the body
  genuinely needs. The entailment side condition is **vector-valued** on multi-parameter
  predicates: `Q_sig = {Ix a b, Ix c d}` does **not** entail an inferred joint `Ix a d`
  (each argument appears in `Q_sig`, but the predicate does not), so that binding is
  rejected rather than widened — the per-argument reading would be unsound.

---

## 10. How to read the recurring defects against this spec

**Audit completed 2026-06-21 — see [`archive/DICT-CONFORMANCE-AUDIT.md`](../../archive/DICT-CONFORMANCE-AUDIT.md) (archived); all D1–D10 divergences closed.** (That audit predates the
overlap extension of §3/§6; D1–D10 concerned the non-overlapping regime. The
overlap regime's conformance target is the 2026-07-16 revision, driver #203.)
The lens below remains useful for diagnosing future regressions.

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
- **Most-specific divergence (overlapping instances, #203)** → §3 `inst` +
  §6 C1 + uniform resolution: with overlap now *specified*, the defect class
  is no longer "overlap exists" — it is **a resolution path that fails to
  select the `⊑`-minimal matching instance** the spec mandates: a nested
  `requires` obligation discharged to the general instance, a super-projection
  built against the declaration head instead of the construction goal, or an
  engine that crashes/diverges where another selects correctly. Suspect any
  resolution code path that stops at the *first* matching instance, iterates
  `IE` in declaration order, keys instances by class-plus-head-constructor
  alone (which cannot separate `List Int` from `List a`), or resolves
  nested/super obligations through a different lookup than top-level goals.

---

## References

- P. Wadler, S. Blott. *How to make ad-hoc polymorphism less ad hoc.* POPL 1989.
  (The dictionary-passing translation.)
- M. P. Jones. *Qualified Types: Theory and Practice.* (Evidence/entailment,
  the `P ⊢ π` discipline and the coherence problem.)
- C. Hall, K. Hammond, S. Peyton Jones, P. Wadler. *Type Classes in Haskell.*
  (Class/instance environments, superclasses, the translation in practice.)
- S. Peyton Jones, M. Jones, E. Meijer. *Type classes: an exploration of the
  design space.* Haskell Workshop 1997. (Overlapping instances and the
  specificity ordering among the surveyed design choices — prior art for §3's
  `⊑` and §6.1.)
