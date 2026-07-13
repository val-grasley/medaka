# `<Mut>` scoping — effect masking for allocate→fill→freeze

**Status:** OPEN — decision-ready design input, not implemented. What remains: the
whole `mut` block construct (see Recommendation below). Raised by the SQLite dogfood
workstream (2026-07-13); lands in `compiler/`, which a different orchestrator owns — this doc
exists to hand them a decided question, not a debate.

**Recommendation:** add a **`mut` block** that subtracts `Mut` from its body's inferred effect
row, as an explicitly **trusted** construct with a checked perimeter — and **reclassify `<Mut>`
in the spec** from "purity tracking" to what it demonstrably is: a *writer-discipline marker*.

---

## 1. The problem, and what it has actually cost

`<Mut>` is contagious. A pure function cannot use a local mutable buffer: the effect propagates
into its signature and then into every transitive caller. So **allocate → fill → freeze →
return immutable** — the fundamental idiom of all binary-format and serialization code — is
unavailable to pure code.

Two independent authors hit this in one library, in one session, and both paid:

- **`sqlite/lib/recordenc.mdk:70-78`** hand-rolls a pure `beSintBytes` rather than use the
  canonical `stdlib/bytebuilder.mdk` `emitBeSint`, with a comment saying exactly why: using it
  *"would propagate `<Mut>` through `encodeRecord` and all callers."* A stdlib encoder,
  duplicated, to dodge an effect.
- **`sqlite/lib/btree.mdk`** (overflow-page reassembly) wanted `arrayMake` + `blit`. That would
  have pushed `<Mut>` through `decodeLeafCell` → `decodeCells` → `scanTablePage` →
  `scanTableRows` → `select.mdk`, `aggregate.mdk`, `mutate.mdk` and every consumer — *a read
  path carrying a mutation effect*. It was rewritten with pure `slice` + `concat`, which is
  **O(chunks × bytes) instead of O(bytes)**: reassembling a 100 KB payload from a 25-page chain
  does ~25× the necessary work.

**The language's own source already names the missing feature.** `stdlib/runtime.mdk:190-192`:

> ```
> -- Pure wrappers.  Encapsulate "alloc + locally mutate + return fresh" so
> -- the <Mut> doesn't leak into pure callers (Medaka has no effect masking).
> extern arraySortBy    : (a -> a -> Ordering) -> Array a -> Array a
> extern arrayFromList  : List a -> Array a
> ```

So `arraySortBy` and `arrayFromList` **are already trusted masks** — native code that allocates,
mutates locally, and returns a fresh value while typed pure, with *zero* perimeter checking.
The pattern is conceded; only the general, checkable mechanism is missing. This is the single
most important fact in this document: we are not introducing trusted masking. We are
**generalizing an existing unchecked one, with more checking than it has today.**

## 2. What `<Mut>` actually is (the question that decides everything)

The spec is unambiguous — and **wrong about the implementation**.

`EFFECTS-SEMANTICS.md:448-457` (status: *"specification (theory-first, idealized)"*):

> **internal** — purity/discipline tracking only; **never granted, never in the manifest, never
> parameterized**. Examples: `Mut` (mutable state), `Panic` (divergence). …
> `<Mut>` is *not* `≤ <IO>` … because `Mut` is not a host capability.

And the implementation agrees on the *non-capability* half — `compiler/tools/check_policy.mdk:588`:

```medaka
isSecurity l = not (l == "Mut" || l == "Panic")
```

**The manifest machinery drops `Mut` on the floor. Nothing downstream consumes it.**

But the *purity* half is **not delivered**, and this is verifiable on the binary today:

```medaka
counter : Ref Int
counter = Ref 0

peek : Unit -> Int          -- NO <Mut>. This function is typed PURE.
peek _ = counter.value

bump : Unit -> <Mut> Unit
bump _ = setRef counter (counter.value + 1)
```
`peek ()` → `0`, then `bump ()`, then `peek ()` → `1`. **A pure-typed function observably returns
two different answers.** Because *allocation is pure* (`Ref : a -> Ref a`) and *reads are pure*
(`.value`), and only writes carry `<Mut>`.

So today `<Mut>` is:
- **not a capability** — nothing grants it, nothing checks it, the manifest excludes it, `<IO>`
  deliberately excludes it;
- **not a purity guarantee** — falsified by the probe above.

It is a **writer-discipline marker**: *"this function performs a write to some mutable cell."*
That is a genuinely useful third thing — it documents in-place APIs (`hash_map`, `mut_array`),
it is greppable, it flags aliasing hazards. It is also exactly the reading under which masking
is principled rather than a loophole: **`mut { … }` asserts "the writes in this scope target
scope-local state."**

The spec's §7 classification of `Mut` as "purity tracking" should be amended to say this. The
spec is explicitly a target, not a description — but this particular target is unreachable
without making *reads* effectful, which is strictly worse (see §5, option B).

## 3. A rejected proposal, recorded because it is the one people will reach for

**Proposal:** `runMut : (Unit -> <Mut> a) -> a`, sound because "the only laundering vector is a
`Ref` escaping the scope, so require that the result type may not mention `Ref`." No rank-2
types needed — a plain syntactic check.

**This is wrong.** It polices only the *exit*, only at *first order*. Three holes, all verified
on the binary:

**(a) A `Ref` laundered out inside a closure.** No `Ref` appears in the result type:
```medaka
mkCounter : Unit -> (Unit -> <Mut> Int)   -- mkCounter itself is typed PURE
mkCounter _ =
  let r = Ref 0
  (_ => bumpAndGet r)                     -- the ref hides in the closure environment
```
`check` accepts it; `c = mkCounter (); c (); c (); c ()` → `1 2 3`. Then `runMut (c ())`
discharges the latent `Mut` and types as a bare pure `Int` that returns a different answer every
call. **The construct revokes the very invariant that justified its restriction** ("a later write
still demands `<Mut>` at the call site, which is honest" — `runMut` is what makes it dishonest).

**(b) A nested mask inside an escaping closure** defeats even the patched rule. Ban arrows and
latent `Mut` in the result, and you can still write `(x => runMut (bumpAndGet r))` with `r`
captured: the *inner* mask discharges the row, so the closure types as a pure `Int -> Int`. Root
cause: without rank-2 regions, a mask **cannot distinguish "`Mut` on refs I allocated" from
"`Mut` on refs I captured."** That distinction is precisely what Haskell's `∀s.` buys, and HM has
no surrogate for it.

**(c) The entry direction, which a result check never examines.** `mut (fill 0 someParamArray)`
has result type `Unit` — passes any result-type rule — and mutates an array whose other aliases
observe the change through today's pure reads.

**And a sound version cannot serve the use case.** Killing (c) requires proving every mutated
handle is scope-allocated — but the entire point is to hand the buffer to
`bytebuilder.emitBeSint`, i.e. *across a function call*. A syntactic locality check cannot follow
the buffer into the callee; an interprocedural one is whole-program escape analysis. **A sound
`runMut` cannot do the job that motivates `runMut`.**

The correct conclusion is not "abandon the feature." It is **"stop selling it as sound."** Ship
it as a *trusted contract* — exactly what `arraySortBy` already is — with a perimeter check the
existing externs don't have. If it is advertised as sound, the first person to construct (a)
files a soundness bug against it, rightly.

## 4. The design

**Surface: a `mut` block, not a combinator.**

```medaka
encodeRecord : Record -> Array Int
encodeRecord r =
  mut
    let b = newBuilder ()
    emitBeSint 4 (headerOf r) b
    …
    buildArray b
```

- **A combinator's type is unwritable.** `runMut : (Unit -> <Mut> a) -> a` is a lie in the type
  language: by the spec's own latent-effect rule, applying the thunk inside would put `Mut` on
  `runMut`'s *own* row. There is no HM-with-rows type meaning "drops a label" — it must be a
  typechecker special form regardless. Given that, the `(_ => …)` thunk wrapper is pure ceremony,
  and this language is explicitly anti-ceremony.
- **`mut` is a free keyword.** The lexer still reserves it (`compiler/frontend/lexer.mdk` →
  `TMut`) but `let mut` was removed in the P0-5 Ref pivot. The token is sitting unused, and a
  block keyword *reads* as a scope — which is the semantics.

**Inference (small, no new type machinery).** The typechecker already swaps effect rows per
function (`curEffect : Ref EffRow`). Give the block body a fresh row, solve it, then union
`(bodyRow \ {Mut})` into the outer row.

> ⚠️ **Subtract only the literal `Mut` atoms; leave an open tail open.** If the body calls an
> effect-polymorphic callback (`each g buf`, `g : a -> <e> Unit`), `e` must flow through
> **unmasked** — a caller-supplied `g` that writes *caller* state must have its `Mut` reappear at
> the instantiating site. Atom-subtraction-keep-tail gets this right with no new quantifiers and
> no rank-2.

**Perimeter check.** After inference, walk the block's result type; error `T-MUT-ESCAPE` if it
*transitively* contains

- a **mutable handle** — `Ref`, `MutArray`, `HashMap`, `HashSet`, `Builder` (by constructor name;
  there is exact precedent — the value restriction already excludes `Ref` by name in
  `typecheck.mdk`). Keep the list as a small registry so user mutable types can opt in later.
- or **any arrow type** — this is what kills hole (a).

The frozen `Array` result must of course be allowed to escape; *that* is the residual trust —
the scope author asserts no other alias of it survives.

**Optional, later:** a best-effort lint `W-MUT-NONLOCAL` inside `mut` blocks, warning when a
known mutator's handle argument is syntactically a parameter or an outer binding — catches the
*accidental* first-order form of hole (c) (`mut (sortInPlace someParam)`). Do not block shipping
on it; it cannot catch the interprocedural case, which stays trusted.

**Eval and both emitters treat `mut` as transparent** (effects are erased anyway). Cost is the
standard add-language-feature sweep (lexer/parser/AST/typecheck/fmt/printer/LSP) plus one seed
re-mint and fixpoint re-validation.

## 5. Alternatives, and why they lose

**(B) Make `<Mut>` a real purity tracker** — i.e. make `.value` reads effectful. This is the only
way to earn the spec's current claim. It **amplifies the contagion we are trying to cure** (now
*reading* infects too), it still cannot discharge without rank-2 types, and it buys a guarantee
**nothing downstream consumes** (the manifest drops `Mut`). Strictly worse.

**(C) Drop `<Mut>` from signatures for local mutation.** Incoherent in this stdlib: every real
mutable structure — `MutArray`, `HashMap`, `Builder` — is `Ref`-backed. Dropping `Mut` on raw
`Array` writes would un-mark the *most* dangerous writes while keeping it on the safe wrappers.
Doing it properly needs escape analysis, which is the "too clever" branch.

## 6. Blast radius

**Nothing breaks; migration is zero-forced.** Masking is purely additive — every existing
signature stays valid, and code that never writes `mut` compiles bit-identically.

The security half of the effect system — the part with actual teeth (escape-checked security rows
→ capability manifest) — is **untouched by construction**, because `check_policy` filters `Mut`
out. Masking `Mut` *cannot* weaken the capability story. What it weakens is a purity story that,
per §2, does not currently exist.

Wins unlocked: delete `recordenc.mdk`'s duplicated encoder; restore the O(bytes) gather in
`btree.mdk`; make `mut_array`/`hash_map`/`bytebuilder` legal local accumulators inside pure
functions — which is how strict functional code (OCaml, F#) is actually written.

And one number worth sitting with: **the compiler's own source carries ~1,358 `<Mut>`-bearing
signatures** (the typechecker cannot mint a type variable without `<Mut>`). Within the compiler
the label is on nearly everything — so it distinguishes nearly nothing. That is not an argument
for deleting it; it is an argument that it is currently marking the wrong scope.

---

## Provenance

Raised by two independent agents in the SQLite dogfood workstream; the "no `Ref` in the result"
proposal was mine and was **disproved** by an independent design review, whose counterexamples
(a)/(b)/(c) I then reproduced on the binary. Recorded here in full because it is the proposal the
next person will reach for, and it looks right until you try to break it.
