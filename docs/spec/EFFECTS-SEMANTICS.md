# Effect-and-Capability Semantics for Medaka

**Status:** specification (theory-first, *idealized*). **Scope:** the typing,
inference, and meaning of Medaka's effect rows — including **parameterized
effects** (effect labels refined by a domain-drawn parameter) — and the
conditions under which the effect discipline is *sound*, the inference *principal*,
and the resulting row a trustworthy **capability manifest**.

## 0. Purpose and the non-derivation principle

Medaka annotates function types with **effect rows** (`<IO>`, `<Net "a.com/*">`,
`<Rand, Clock>`, `<IO | e>`). The intent is bigger than "track side effects": a
sound, fine-grained row is a **compiler-verified capability manifest** — the type
tells you (and the platform that runs the module) exactly what authority the code
exercises. The hard part is **parameterized effects**: a label like `Net` carries
a *parameter* (which hosts? which paths?) drawn from a refinement domain, and the
parameter must be tracked soundly through inference so that a module pinned to
`<Net "idp.example.com/*">` provably cannot reach `evil.com`.

This document fixes the semantics **from the theory of type-and-effect systems
and capability safety**, not from the current code. It is written to be a *target
the implementation is audited against* — deliberately *idealized*: where the
theory points past what is built (e.g. richer parameter domains, more precise
abstraction, interprocedural authority tracking), the spec follows the theory and
the gap becomes an audit finding, not a constraint on the spec. Where spec and
implementation disagree, that disagreement is a finding to triage; the spec is
**not** a description of present behavior.

Theory anchors:

- **The type-and-effect discipline** — Gifford & Lucassen (FX, 1986/88);
  Talpin & Jouvelot (*The Type and Effect Discipline*, 1994). A typing judgment
  carries a third component, the *effect*, inferred with **effect variables**.
- **Row-polymorphic effects** — Leijen (*Koka: Programming with Row-Polymorphic
  Effect Types*, 2014); Rémy / Wand (extensible rows). Medaka's
  `<l₁,…,lₙ | μ>` is exactly a Koka-style effect row with an optional polymorphic
  tail `μ`.
- **Effects as capabilities** — Brachthäuser, Schuster, Ostermann (*Effects as
  Capabilities*, 2020); the object-capability model (Miller). An effect is the
  *requirement of an authority*; the program cannot perform it without the
  ambient permission, and the **host is the handler** that grants or denies at the
  module boundary.
- **Abstract interpretation** — Cousot & Cousot (1977). A parameterized effect's
  parameter is an *abstraction* of a concrete authority value; the abstraction
  function α must be a **sound over-approximation** (a Galois connection), which is
  exactly what makes the no-exfiltration guarantee hold.

Deliberately **out of scope, permanently** (decided, not omitted): algebraic-effect
**handlers** / delimited continuations / `resume`; typed-error (`Throws E`) effects.
Medaka takes effect *tracking* and rejects effect *handling*: `Result` is the
canonical error representation and `panic` is the sole unrecoverable escape. See
§7 for why the handler's role is played by the host, not by in-language control flow.

Terminology bridge (Medaka surface → this document; no implementation terms):

| Medaka surface | This document |
|---|---|
| effect row `<IO>` / `<Net "h/*"> ` / `<IO ∣ e>` | effect row `φ` |
| effect label `Net`, `IO`, `Rand` | effect/operation label `L` |
| parameter `"a.com/*"`, `_` | refinement-domain element `p ∈ 𝔻_L` |
| row tail `… ∣ e` | effect-row variable `μ` |
| `effect Net Prefix` | label declaration binding `L` to domain `𝔻_L` |
| pure (no annotation) | the empty closed row `⟨ ⟩` |
| the known-prefix analysis (`α`) | the abstraction function `α : Expr → 𝔻` |
| `check-policy` / capability manifest | manifest extraction `M(·)` (§7) |
| the Wasm host / platform | the **handler** — the capability grantor (§7) |

A note on **orthogonality to dictionaries.** Effects coexist with Medaka's
qualified-type (interface/`=>`) system specified in
[`DICT-SEMANTICS.md`](DICT-SEMANTICS.md). The two are *independent*: dictionaries
are evidence routed by label/method identity; effect parameters are **inert data
that rides on the row**, joined at unification and never routed. This document
suppresses the predicate context `P` of the dictionary spec; a full judgment is
`P ∣ Γ ⊢ e ⇝ e' : τ ! φ`, and the effect rules below thread `φ` orthogonally to
the `P ⇝ e'` translation.

---

## 1. Source language (the effectful fragment)

We model what bears on effects. Types now carry effects on every arrow, and
schemes quantify **type and effect variables**:

```
p   ::= ⊤_𝔻 | … domain-specific elements …      -- parameter from a domain 𝔻 (§2)
a   ::= L · p                                    -- atom: label L refined by param p
φ   ::= ⟨ a₁ … aₙ ∣ μ? ⟩                         -- effect row: atom set + optional tail var μ
τ   ::= α | T τ̄ | τ₁ →^φ τ₂ | (τ̄)               -- monotypes; arrow carries a latent effect φ
                                                -- T τ̄ may include an effect-row argument (§6)
ρ   ::= τ                                        -- (qualifiers from DICT-SEMANTICS suppressed)
σ   ::= ∀ᾱ. ∀μ̄. ρ                               -- scheme: quantifies TYPE and EFFECT vars
```

- An **arrow** `τ₁ →^φ τ₂` reads "a function that, *when applied*, may perform
  `φ`." `φ` is the **latent** effect — it is discharged at application, not at
  closure construction (closing over an effectful body is pure; *calling* it is
  not). The empty closed row `⟨ ⟩` is a *pure* function.
- An **effect row** `φ = ⟨ ā ∣ μ ⟩` is a finite set of atoms `ā` with **at most
  one atom per label** (canonical form; same-label atoms are merged by the domain
  join `⊔`, §2), plus an optional **tail variable** `μ`.
  - `μ = ·` (absent) ⇒ **closed** row: exactly `ā`.
  - `μ = ρ` (present) ⇒ **open** row `⟨ ā ∣ ρ ⟩`: `ρ` can absorb further atoms.
- A **label environment** `LE` records, for each declared label `L`, its
  **domain** `𝔻_L` (§2). Every label is a host capability (§7). Built-in
  labels and `effect`-declarations populate `LE`.

Closed rows are what a *user annotation* denotes; **inference synthesizes open
rows** so the subsumption discipline (§5) survives equality unification.

---

## 2. Effect rows and the refinement-domain lattice

This is the first half of the parameterized-effect story: **what a parameter is**.

### 2.1 Domains

A **refinement domain** `𝔻` is a bounded join-semilattice with a partial meet:

```
𝔻 = (P, ⊑, ⊤, ⊔, ⊓)
    ⊑ : P × P → Bool          -- refinement order (decidable)
    ⊤ : P                      -- the unconstrained / maximal-authority element
    ⊔ : P × P → P              -- join: least over-approximation of two authorities
    ⊓ : P × P → P ∪ {⊥}        -- meet: greatest common authority, ⊥ if disjoint
```

subject to the laws: `⊑` is a partial order; `⊤` is the top (`p ⊑ ⊤` for all
`p`); `⊔` is the least upper bound and `⊓` the greatest lower bound w.r.t. `⊑`;
`⊔` is total (saturating to `⊤`), `⊓` may be `⊥`. **Higher in `⊑` means *more*
authority.** `⊤` = "any authority." A render `drender : P → String` produces the
manifest text (§7). This is exactly the abstract-domain interface of abstract
interpretation; a label's parameters live in *one* such domain, fixed by the
label's declaration.

The canonical domains (the spec defines the **family**; the implementation may
realize a prefix of it — see the audit):

| Domain | Elements | `⊑` | `⊔` | `⊓` |
|---|---|---|---|---|
| **`Unit`** | `()` only | trivial | `()` | `()` |
| **`Prefix`** | a delimiter-terminated string pattern, or `⊤` | structural prefix-containment (§2.3) | longest common prefix, saturating to `⊤` | the more specific, or `⊥` if neither contains the other |
| **`Set`** | a finite set of strings, or `⊤` | `⊆` | `∪` (saturating to `⊤` past a cardinality cap) | `∩` |
| **`Product`** | a tuple of sub-domains, e.g. `Net = Host(Prefix) × Method(Set)` | pointwise | pointwise | pointwise (⊥ if any component ⊥) |

`Unit` is the *atomic* label of v1 (an unparameterized effect is `L · ()`); it is
the degenerate one-point domain. Everything below is stated **domain-generically**:
the row machinery (§3–§5) is written against the `𝔻`-interface and is identical
for every domain. Adding `Set`/`Product` is a new domain instance plus a parser
clause for its literal syntax — **no change to unification, the escape check, or
the manifest extractor.** That domain-parametricity is the whole point.

### 2.2 Rows as domain-indexed maps

Canonically, a row's atom set is a finite **partial map** from labels to
parameters, `ā : L ⇀ P` with `ā(L) ∈ 𝔻_L`. Two syntactic atoms on the same label
are **never two members** — they collapse to one by `⊔` in `𝔻_L`. (Distinctness
holds *across* labels only; within a label the canonical form is the join,
otherwise the order in §2.4 is ill-defined.) A v1 atomic label `Foo` is exactly
`Foo · ()`.

### 2.3 The `Prefix` domain and the delimiter discipline

`Prefix` is the security-critical domain (hosts and paths). Its parameter is a
pattern; `⊤` = `None` (any). The refinement order:

```
p₁ ⊑ p₂   iff   p₂ = ⊤,  or  p₂ is a pattern and p₁'s concrete part STARTS WITH p₂'s concrete part
```

so `Net "a.com/api/v1" ⊑ Net "a.com/api/*" ⊑ Net "a.com/*" ⊑ Net ⊤`. **Raw-prefix
matching is unsound for authority** — `"a.com"` is a string-prefix of
`"a.com.evil.com"`, so a bare prefix would silently grant a sibling host.
The domain therefore requires every pattern to terminate at a **structural
delimiter**: a path/host boundary (`/`) or an explicit trailing `*`. `Net "a.com/*"`
matches `a.com/...` but **not** `a.com.evil.com/...`. A pattern lacking a delimiter
is rejected at declaration/annotation time. Full scheme/host/port/path structure is
the `Product` domain; `Prefix` is its sound, coarse one-axis approximation. Only
trailing-`*` wildcards are admitted — general globs/regex break decidability of
`⊑` and are rejected.

### 2.4 Sub-effecting (row order)

The order on rows, `φ₁ ≤ φ₂` ("`φ₁` performs no more than `φ₂`"), lifts the domain
orders pointwise and accounts for the tail:

```
⟨ ā₁ ∣ μ₁ ⟩ ≤ ⟨ ā₂ ∣ μ₂ ⟩   iff
    (∀ L·p₁ ∈ ā₁.  ∃ L·p₂ ∈ ā₂.  p₁ ⊑_{𝔻_L} p₂)     -- every atom is covered, more specific ⊑ more general
  ∧ (μ₁ present ⇒ μ₂ present)                         -- a closed row ≤ an open row; not conversely
```

`≤` is the soundness order: a value of effect `φ₁` is usable where `φ₂` is
permitted iff `φ₁ ≤ φ₂`. The **direction matters for security**: `<Net "a.com/*">
≤ <Net ⊤>` (specific is usable where general is allowed) but `<Net ⊤> ≰ <Net
"a.com/*">` (a ⊤/any-host capability is *not* usable where only `a.com` is
permitted). This is precisely the gate that rejects exfiltration (§4, §5).

The **join** of two rows `φ₁ ⊔ φ₂` (used by inference, §3) is the label-wise
union with same-label params joined by `⊔_{𝔻_L}`; it is the least row `≥` both.

---

## 3. The effect judgment and effect inference

This is the second half: **how rows are inferred and checked.** The judgment

```
Γ ⊢ e : τ ! φ
```

reads "in environment `Γ`, `e` has type `τ` and its *evaluation* may perform
`φ`." `φ` is the **immediate** effect of running `e` to a value; latent effects of
functions sit on arrows (§1) and are released by `app`.

```
            x : ∀ᾱμ̄. τ ∈ Γ        S = [τ̄/ᾱ, φ̄/μ̄]  (instantiation; §6 reopening)
(var)   ─────────────────────────────────────────────
            Γ ⊢ x : S(τ) ! ⟨ ⟩                       -- a variable use performs nothing

            Γ ⊢ e₁ : τ₂ →^φ₀ τ ! φ₁        Γ ⊢ e₂ : τ₂ ! φ₂
(app)   ──────────────────────────────────────────────────────
            Γ ⊢ e₁ e₂ : τ ! φ₁ ⊔ φ₂ ⊔ φ₀              -- evaluate fn, evaluate arg, THEN perform latent φ₀

            Γ, x:τ₁ ⊢ e : τ₂ ! φ₀
(lam)   ──────────────────────────────────────
            Γ ⊢ (λx. e) : τ₁ →^φ₀ τ₂ ! ⟨ ⟩           -- building a closure is pure; body effect is LATENT

            Γ ⊢ e₁ : τ₁ ! φ₁     Γ, x:gen(Γ, τ₁, φ₁) ⊢ e₂ : τ₂ ! φ₂
(let)   ────────────────────────────────────────────────────────────
            Γ ⊢ (let x = e₁ in e₂) : τ₂ ! φ₁ ⊔ φ₂

            Γ ⊢ e : τ ! φ        φ ≤ φ'
(sub)   ─────────────────────────────────                -- subsumption: weaken to a larger row
            Γ ⊢ e : τ ! φ'
```

with two rules that *introduce* concrete effects:

```
            (prim p : τ̄ →^⟨ L·● ∣ ρ ⟩ τ) ∈ LE      Γ ⊢ ēᵢ : τ̄ᵢ ! φ̄ᵢ
            π = α_{𝔻_L}(e_k)                         -- the determining argument's abstraction (§4)
(prim)  ───────────────────────────────────────────────────────────────
            Γ ⊢ p ē : τ ! (⊔ᵢ φ̄ᵢ) ⊔ ⟨ L·π ⟩

            (op : … <e> … ) a class/interface method whose signature carries an effect var
(method)    — the effect var is instantiated like any μ̄ by (var); the method's
              latent row is whatever the dispatched impl performs, bounded by the signature.
```

Reading:

- **`var`/`lam`** are the classic effect-discipline shape: *mentioning* a function
  is pure; the latent row lives on its arrow and is released only by **`app`**,
  which **unions** the function-expression's, argument's, and latent effects. This
  is what makes effects flow through ordinary application without explicit
  threading.
- **`prim`** is the **only rule that mints a parameterized atom.** A parameterized
  primitive's signature has a *hole* `L·●` at a parameter position; the atom's
  parameter is computed by abstracting the **determining argument** `e_k` (the URL,
  the path) via `α` (§4). A non-parameterized primitive is the special case
  `𝔻_L = Unit`, `π = ()`. (A primitive with a *fixed* annotation `L·c` instead of a
  hole emits exactly `L·c` regardless of arguments — the hole is what invokes α.)
- **`let`/`gen`** generalizes; §6 gives the generalization rule for effect
  variables and its value-restriction side condition.
- **`sub`** is the only place the row *grows* without a cause — it is how an
  annotated bound is satisfied by a more specific inferred row, and how the two
  branches of an `if` are reconciled (each subsumed to their join).

**Principal effects.** Inference is intended to compute, for every `e`, the
*least* row under `≤` (equivalently: the join of exactly the atoms `e` can
actually perform, with the most specific parameters `α` can justify). `var`/`lam`
contribute nothing; `app`/`let` join; `prim` adds the single determined atom; `sub`
is applied only where a bound forces it. The least-row property is what makes the
inferred row a *tight* manifest rather than a conservative blanket.

---

## 4. Parameter creation: the abstraction α

The parameter on a `prim`-introduced atom is `α(e_k)`, where `α : Expr → 𝔻` is a
**sound abstraction** of the authority the argument denotes. Formally, with `γ`
the concretization (the set of runtime values a domain element admits), `α`/`γ`
form a Galois connection and the soundness obligation is

```
            ⟦e_k⟧  ∈  γ(α(e_k))                     -- α OVER-approximates: the real authority is admitted
```

i.e. the parameter the type system records is **never smaller** than the authority
the code actually exercises. Over-approximation toward `⊤` is always safe; the
only unsound move is to under-approximate (claim a *narrower* authority than the
code can reach). The ideal abstraction over string-producing forms (`Unknown ⇒ ⊤`
is the safe default):

| Core form | `α` |
|---|---|
| string literal `"s"` | the singleton authority `s` (e.g. `Prefix` pattern from `s`) |
| `e₁ ++ e₂` (concatenation) | if `α(e₁)` is a known prefix `p`, then `p` (a fixed left prefix bounds the whole, regardless of `e₂`); else `⊤` |
| string interpolation `"s\{e}…"` | the `++`-chain rule: the leading literal `s` is the known prefix; the first interpolated expression stops it |
| `let x = e₁ in …x…` | propagate `α(e₁)` to uses of `x` |
| `if c then e₁ else e₂` | `α(e₁) ⊔ α(e₂)` (join of branch authorities) |
| `match … { … ⇒ eᵢ }` | `⊔ᵢ α(eᵢ)` (join over arms) |
| application result `f ē`, a free/parameter variable, field access, anything else | `⊤` |

**The ⊤-fallback *is* the no-exfiltration guarantee.** A URL/path that is computed
(a function result, a runtime input, an un-analyzable expression) abstracts to
`⊤`, and `<L·⊤> ≰ <L·"pinned/*">` by §2.4 — so a module pinned to a specific host
**cannot** satisfy its bound with a runtime-chosen destination; it is *rejected at
type-check*. "No exfiltration to an attacker-chosen target" is literal-lifting
doing its job, not a separate check.

**Precision is a parameter of α, soundness is not.** The table above is the
*idealized* abstraction, including let/`if`/`match` propagation and the join over
branches. A weaker α (e.g. one that only recognizes a literal in argument
position and abstracts everything else to `⊤`) is **still sound** — it merely
*over-rejects* (a program the ideal would accept is refused because its authority
needlessly widened to `⊤`). Two precision levels are worth naming:

- **Intraprocedural** (the practical instance): authority is tracked within one
  function body; a value threaded through a *helper* collapses to `⊤` at the call
  boundary (`f ē ⇒ ⊤`). Sound, decidable, cheap.
- **Interprocedural / value-singleton** (the ideal ceiling): authority recovered
  across calls by propagating singleton/refinement information on values. Strictly
  more precise; needs value-level singleton typing — a real escalation. The spec
  *permits* it; no soundness rests on it.

Because both are sound, the choice of α-precision is an engineering dial, **not** a
correctness question. The audit measures the implemented α against the idealized
table; every shortfall is a *completeness* (over-rejection) gap, never a soundness
hole.

---

## 5. Sub-effecting, escape, and the no-laundering law

Soundness is enforced at exactly two seams, both instances of the order `≤` (§2.4).

**The binding-boundary escape check.** When a binding `f` carries a declared row
bound `φ_decl` (from its signature) and inference gives its body `φ_inf`, the
obligation is

```
            φ_inf ≤ φ_decl                          -- inferred effects fit the declaration
```

else **`EffectEscape`**: `f` is declared with `φ_decl` but also performs the
atoms `φ_inf \ φ_decl` (where `\` is the per-label residual: a label absent from
`φ_decl`, *or* present with a param `p_inf ⋢ p_decl`). The diagnostic names the
offending atom — "performs `<Net "evil.com">` where only `<Net "a.com/*">` is
allowed."

**The laundering / covariant-position check.** Storing an effectful value where a
lower-effect type is expected must be rejected, *even point-free* — `launder =
emit` (binding an `<IO>` function to a pure-typed name) cannot erase the row.
Mechanically this is **unification of an inferred *open* row against a declared
*closed* row**: the open side may carry no atom the closed side lacks. The
covariant-position **re-open** discipline — an instantiated closed-with-atoms row
reopens to `⟨ ā ∣ ρ ⟩` only at *value-producing* positions — is what lets equality
unification still enforce the *subset* (≤) direction rather than collapsing it to
equality. (This is the standard subtyping-via-row-polymorphism encoding.)

**No-laundering law.** *Every elimination of an effectful value flows its row into
the ambient effect; no construct discards or downgrades a row except by `sub` to a
larger one.* A consequence: the effect of a whole program is `≥` the join of every
primitive it can reach — there is no syntactic hiding place.

**Decidability.** The two checks reduce to deciding `≤`, which reduces to deciding
each `⊑_{𝔻_L}`. The spec's domains keep `⊑` decidable: `Unit` trivial; `Prefix`
trailing-`*`/delimiter-terminated (no general globs); `Set` finite `⊆`; `Product`
pointwise. Banning general globs/regex is a *decidability* requirement, not a taste.

---

## 6. Polymorphism: effect variables, generalization, and effect-poly data

**Effect-variable generalization (the HM rule for effects).**
`gen(Γ, τ, φ)` quantifies the type *and* effect variables free in `(τ, φ)` but not
free in `Γ`:

```
gen(Γ, τ, φ) = ∀(ᾱ = ftv(τ,φ)\ftv(Γ)). ∀(μ̄ = fev(τ,φ)\fev(Γ)). τ
```

so a higher-order function gets an **effect-polymorphic** scheme. The canonical
example:

```
map : (a →^e b) → List a →^e List b              -- one effect var e on the callback AND the result
```

The callback's latent row `e` is *the same variable* as `map`'s own latent row:
applying `map` to a pure function instantiates `e := ⟨ ⟩` (the whole call is pure);
applying it to an `<IO>` function instantiates `e := <IO>` (the call performs
`<IO>`). This is effect parametricity — the engine of `do`-notation, `fold`,
`andThen`, and every stdlib combinator threading caller effects through.

**The value restriction.** Naïvely generalizing an effect variable that escapes
into a mutable/aliased position is unsound (the classic ML let-generalization
hazard, transposed to effects). The spec requires generalizing effect variables
only at **syntactic values** (or, equivalently, only re-opening rows at covariant
positions per §5) so a generalized `μ` cannot be captured at two incompatible
instantiations. This is the effect analogue of the type-system value restriction
and is what keeps `gen` + open-row unification sound together.

**Well-formedness of interface-method effect variables (the no-laundering side
condition).** A quantified effect variable that occurs in an interface method's
**return-position** row must **also** occur in an **argument** position of that
method's signature — either as a callback's latent arrow effect (`(a →^e b)`) or as
a row-kinded type-constructor argument (`Async e a`, §"effect-polymorphic data"
below). An effect variable that appears **only** in the return row, determined by no
argument, is **ill-formed** (an ambiguous / under-determined quantified variable, the
effect analogue of a class method whose return type mentions a type variable pinned
by nothing). It is rejected at the interface declaration.

The reason is soundness, not taste. If `speak : a →^e String` quantifies `e` with
nothing to pin it, a caller instantiates `e := ⟨ ⟩` at the use site and obtains a
value the effect system certifies **pure** — yet the *dispatched* impl of `speak`
may perform `<Stdout>`, selected by the dictionary at the call site, invisibly to
the caller's effect. The effect would be **laundered** away (§5's no-laundering law
violated with no error). Argument-carried polymorphism (`map`, `andThen`, `fold`,
`traverse`) at least *gives the caller a handle on* `e`: it appears in an argument
(a callback's effect row, or a row-kinded constructor parameter), so the instantiated
`e` is visible in the call's type rather than materialising out of nowhere. This
well-formedness condition is what makes the *generalization* of a method effect
variable meaningful in the presence of dictionary dispatch — and it is decided
**without** consulting the dictionary (it is a purely syntactic property of the
*declared* signature), so it preserves the dictionary/effect orthogonality restated
below: the alternative of lower-bounding a return-only effect var by the *dispatched*
impl's latent effect was rejected because it would make the effect depend on
dispatch, violating that orthogonality.

**Scope of Option A — what it does and does NOT guarantee.** This side condition is a
*necessary* well-formedness rule, not a *sufficient* soundness proof. It is purely
about the shape of the **declared signature**; it does **not** bound the **impl
body's** latent effect. In particular, a method whose signature *does* carry `e` in
an argument can still launder: an impl is free to **ignore** the callback (never
invoke it) and perform its own intrinsic effect. For example
`speak : a → (Unit →^e Unit) →^e String` is well-formed under this rule, yet an impl
that runs `putStr` without ever calling the `Unit →^e Unit` argument performs
`<Stdout>` while a caller instantiates `e := ⟨ ⟩` — the same laundering, now hidden
behind an argument-shaped `e`. Ruling that out requires bounding an impl body's
latent effect by the effect that actually *flows from its arguments* (effect
inference over the body, the same shape as the value/`map`/`traverse` case, which is
why it cannot be a blanket ban), and that is **not yet enforced** for effect-variable
methods. It is tracked separately as **#803** and is out of scope for Option A, whose
job is exactly the signature-level well-formedness above.

**Effect-polymorphic data (effects as type-constructor arguments).** A row may
occupy a **type-constructor argument** position, so a data type can be parameterized
*by an effect*:

```
data Async e a = Done a | Suspend (Unit →^e Async e a)
runAsync : Async e a →^e a
```

Here `e` is **row-kinded** (kind `Row`, distinct from the `Type` kind of `a`),
inferred from its use in an effect position. The effect stored in a `Suspend`
thunk *is* `e`; `runAsync` performs exactly the row the value carries. This is how
Medaka expresses an *effectful computation as a first-class value* **without** an
`<Async>` effect label: async-ness rides in the *type* (`Async e a`), exactly as
error-ness rides in `Result e a` — composition is ordinary `do`/monad structure,
not a tracked row label and not a handler. (Decided invariant.)

**Orthogonality to dictionaries (restated).** When an interface method's signature
carries an effect variable (`andThen : m a → (a →^e m b) →^e m b`), the effect var
generalizes and instantiates exactly as above and is **independent** of the
dictionary that resolves `m`'s instance. Parameters ride as inert data on the row;
the dict machinery keys on labels/methods and never inspects a parameter. A change
to effect parameters touches unification and the escape check **only** — never
dispatch.

---

## 7. The capability semantics: effects as a verified manifest

This is the operational *point* of the discipline. Effects have **no runtime
behavior of their own** — they are erased before evaluation (§8). What they
produce is a **capability manifest**, and the *meaning* of an effect is fixed by
who reads that manifest.

**Every label is a host capability.** There is no internal/purity-tracking label
class — a label is a host-granted authority; the platform supplies the primitive
that performs it; **parameterizable** (carries a domain); **emitted to the
manifest**. Examples: `Net, FileRead, FileWrite, Env, Exec, Stdout, Stderr,
Stdin, Clock, Rand`, and every user `effect Foo`. (An earlier design carved out
an "internal" class — `Mut` for mutable state, `Panic` for divergence — with no
host meaning and no manifest entry. That class was removed 2026-07-14: mutation
is now untracked and `panic` is an ordinary control-flow primitive, not an
effect label. See [`MUT-SCOPING-DESIGN.md`](../design/MUT-SCOPING-DESIGN.md) for
the history.)

**`IO` as a widening alias.** `IO` is not a primitive label but the **join of the
security labels at `⊤`** (`Stdout ⊔ Stderr ⊔ … ⊔ Net⊤`). An inferred narrow row is
`≤ <IO>`, so any `<IO>` annotation still typechecks (it widens), while inference
yields tight narrow rows for the manifest.

**Manifest extraction.** The capability manifest of a module is

```
M(module) = verified-row of the module's entry point(s)
```

— the inferred, escape-checked row of `main` (or each exported entry), unfiltered,
with each label's verified parameter rendered (`drender`). For
`Net "idp.example.com/*"` the manifest records `idp.example.com/*` as the sole
permitted outbound authority.

**The host is the handler.** Medaka has no in-language effect handler. Instead the
**runtime platform** is the handler: it reads `M(module)` *before loading* the
module and **grants or denies** the actual capability at the module boundary — a
plugin whose manifest says `<Net "idp.example.com/*">` is given a network endpoint
restricted to that host and *nothing else*. `main` itself carries **no upper-bound
gate** inside the language (it may declare any row, or none): `main` is the **grant
root**, and the host — not the type system — decides which of its requested
authorities to honor. The policy check `inferred ≤ policy` (does this module stay
within an allowed capability set?) is *manifest verification*, performed by the
toolchain/host against `M`, not a typing rule.

**Capability soundness (no-exfiltration).** Combining §4 and §5: if a module
type-checks with manifest `M`, then for every label `L`, every authority
it can exercise at `L` is `⊑ M(L)`. In particular a parameterized bound confines
*which* hosts/paths/resources, not merely *whether* the label is used — and the
α ⊤-fallback guarantees runtime-chosen targets cannot escape the bound. This is the
theorem the whole apparatus exists to deliver.

---

## 8. Erasure and the single-meaning law

Effect rows and their parameters are **compile-time only**. After type-checking
(escape + laundering verified, manifest extracted), the row is **erased**; it
contributes nothing to the runtime representation, the evaluator, or the emitted
code. Therefore:

- **Single-meaning law.** *The value a program computes is independent of its
  effect annotations.* Adding, tightening, or removing a (still-well-typed)
  annotation cannot change the result — only whether the program is *accepted* and
  what manifest it carries. Any two backends (interpreter, native emitter) agree
  on every well-typed program, because effects are erased identically before either
  runs. (This is the effect analogue of the dictionary spec's single-evaluator law;
  here the content is *erasure*, not dispatch.)
- **Zero runtime cost.** Parameters never become runtime data; only the *verified*
  parameter reaches the static manifest. The security guarantee is paid for entirely
  at compile time.

A corollary worth stating because it is easy to violate: a primitive's effect must
be a faithful upper bound of what it *actually does* at runtime. Erasure means the
type system is the *only* place the authority is checked — so the externs' declared
rows are part of the trusted base. A mis-annotated extern
(claiming a narrower row than it performs) is a soundness bug the spec cannot catch;
the extern catalog is trusted, like any FFI boundary.

---

## 9. Soundness statements (targets for a later proof/audit)

- **Effect preservation (subject reduction).** If `Γ ⊢ e : τ ! φ` and `e ⟶ e'`,
  then `Γ ⊢ e' : τ ! φ'` with `φ' ≤ φ`. Reduction never *introduces* an effect the
  type did not already permit; the row is an upper bound preserved under evaluation.
- **Effect progress / containment.** A running program performs, at each step, only
  atoms within its whole-program row. No reachable primitive performs an
  unaccounted-for label.
- **α-soundness.** For every parameterized primitive application, the runtime
  authority of the determining argument is admitted by the recorded parameter:
  `⟦e_k⟧ ∈ γ(α(e_k))`. (Over-approximation; §4.)
- **Capability confinement.** If a module type-checks with manifest `M`, every
  authority it exercises at a label `L` is `⊑ M(L)` (§7). With a host that
  honors `M`, the module cannot act outside its declared capabilities.
- **Principality.** Inference computes the `≤`-least row for every term (§3); the
  manifest is therefore the *tightest* sound description, not a conservative blanket.
- **Coherence with erasure.** Under §8, the denotation is independent of the row;
  well-typedness and the manifest are the only observable consequences of the
  effect system.

---

## 10. How to read the conformance gaps against this spec

Not the audit (separate document), but the lens. Each anticipated shortfall maps to
a clause:

- **Parameter domain coverage** → §2.1: the spec defines the `Unit/Prefix/Set/
  Product` family; an implementation realizing only `Unit + Prefix` is *domain-
  incomplete*, inexpressive but not unsound. Suspect any `<L {…}>`/structured-param
  surface that fails to parse.
- **α precision** → §4: an abstraction weaker than the idealized table
  (missing let/`if`/`match` propagation, no interprocedural recovery) is sound but
  *over-rejects*. Suspect a pinned-bound program refused where the spec's α would
  accept (a `let`-bound or branch-joined literal authority collapsing to `⊤`).
- **Manifest realization** → §7: the verified row is the deliverable; if no
  toolchain path extracts/emits/verifies `M` on the canonical binary, the headline
  capability feature is unreachable even though the *typing* is sound. Suspect a
  policy/manifest command stranded on a non-canonical tool, or one checking labels
  but not parameters.
- **Effect-poly / data-effect threading** → §6: the `<e>` on combinators and the
  row-kinded data parameter must generalize and instantiate as HM-for-effects.
  Suspect a combinator that fixes a concrete label where the spec demands a variable.
- **Erasure / backend agreement** → §8: any divergence in result (not just
  acceptance) between evaluators traceable to effects violates the single-meaning law.
- **`main` policy** → §7: a *language-internal* upper-bound gate on `main` would be a
  spec deviation in the *opposite* direction — `main` is the grant root; bounding is
  the host's job, not the type system's.

---

## References

- D. K. Gifford, J. M. Lucassen. *Integrating Functional and Imperative
  Programming.* LFP 1986. / J. M. Lucassen, D. K. Gifford. *Polymorphic Effect
  Systems.* POPL 1988. (Effects as a third judgment component; effect variables.)
- J.-P. Talpin, P. Jouvelot. *The Type and Effect Discipline.* Information and
  Computation, 1994. (Effect inference, generalization, the value restriction.)
- D. Leijen. *Koka: Programming with Row-Polymorphic Effect Types.* MSFP 2014.
  (Row-polymorphic effects; the `<labels ∣ μ>` row and its unification.)
- J. I. Brachthäuser, P. Schuster, K. Ostermann. *Effects as Capabilities.* OOPSLA
  2020. (Effects as the requirement of an ambient capability; the boundary as grantor.)
- M. S. Miller. *Robust Composition* (object-capability model). (Authority as
  unforgeable, confined at boundaries — the "host is the handler" stance.)
- P. Cousot, R. Cousot. *Abstract Interpretation.* POPL 1977. (The α/γ Galois
  connection; sound over-approximation — the discipline §4's parameter analysis obeys.)
