# Workstream: COMPILER SOUNDNESS

**Owns:** miscompiles, and any disagreement between `check` / `run` / `build`.
**Touches:** `compiler/types/typecheck.mdk`, `compiler/backend/`, `compiler/eval/`.

> **This repo's #1 bug class is `check` green / `run` or `build` wrong.** Every item here is
> one. A *silent* one — a compiled binary printing a wrong answer with no error — is the worst
> outcome the project has, worse than a crash.

**The gate that owns this class:** `test/diff_compiler_run_check_agreement.sh`. It now compares
the **value** (`run` stdout == built-binary stdout), not just the exit code. Add a fixture there
for every fix, **in both directions** (accept *and* reject).

---

## S-1 · SILENT: a constrained definer-shadow standalone is miscompiled

```medaka
size : Num a => a -> a          -- a CONSTRAINED standalone
impl Sz Box where ...
main = println (size 3)
```
`check` accepts · `run` panics · **`build` prints GARBAGE**.

And it does this **even with no impl at the receiver head** — i.e. with **no dispatch decision
involved at all**. This is not the S2 shadow rule; it is the **`RLocal`-vs-dict-passing seam**:
`RLocal` carries no dictionary, so the call reaches a dict-passed standalone *without its dict
word* and gets a partial application back, which is then printed as a value.

Two things that are NOT the trigger, both verified: it is not about a **missing signature** (an
unsignatured *unconstrained* standalone works fine), and it is not about the impl. **The
constraint is the trigger.**

**Cost:** the fix means threading a dictionary through the route — `ast` + route + `eval` +
LLVM + wasm. That is real work, not a patch. Scope it before you start.

## S-2 · A duplicate top-level function name SEGFAULTS the emitter

Two unrelated top-level functions with the same name produce **no duplicate-definition error**
from the bootstrap build. It emits an emitter that **segfaults** (`E-FATAL-SIGNAL: fatal memory
fault`) while compiling `medaka_cli.mdk`. The gap-tolerant self-compile path silently accepts an
ill-formed program and emits code that crashes.

`typecheck_compiler_source.sh` catches it; **the build does not gate on it** — the same hole
that let an ill-typed compiler ship.

**And the diagnostic, when you finally get one, is actively wrong:** *"Clauses of 'X' must be
contiguous"* — which advises you to **group the clauses together**, i.e. to merge two different
functions. It should say: *"'X' is already defined at line NNN."*

## S-3 · A multi-TYPARAM interface bypasses the definer-shadow machinery entirely

`interface Ix a i` + a shadow + `ix 1 2` → `check` and `build` agree, **`run` panics.** Loud,
not silent, so it ranks below S-1.

Every entry point is gated on `singleParamIfaceMethod` — which, **despite its name, counts
interface TYPE PARAMS, not method params.** That name states the opposite of what it does and
sent an agent down a wrong hypothesis. **Rename it `singleTyparamIfaceMethod`** as part of this.

`SHADOW-SEMANTICS.md` §S8 covers multi-*param methods*; nothing covers multi-*typaram
interfaces*.

---

## Why this class keeps recurring — read before you start

The last three bugs here were all **the same shape**: *one decision, derived twice, at two
different times, over a value that changed in between.*

- The literal-receiver bug (fixed): typecheck decided "standalone" from an **ungrounded** `Num a`
  receiver, but typing it against the standalone **unified `Int` into that receiver** — so the
  post-inference route resolver re-derived the decision from the *same* mono, now **grounded**,
  found the impl, and dispatched. Type from one arm, route from the other.
- The refutable-guard miscompile (fixed): **one `Ref` carrying two meanings** —
  `fallthroughLabelRef` was both "the next clause's label" and the `CTFail` guard, and
  `emitDecision` nulled it for the second purpose, erasing the first.

**So: when you fix one, ask what else re-derives that decision, and whether the thing it derives
it from can still change.** And prefer making the decision *travel with the node* over storing
it in a mutable Ref — that is exactly how the guard bug was killed (the sentinel now carries its
own target), and it is why the **wasm** backend never had that bug.
</content>
