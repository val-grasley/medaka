# Workstream: COMPILER SOUNDNESS

**Owns:** miscompiles, and any disagreement between `check` / `run` / `build`.
**Touches:** `compiler/types/typecheck.mdk`, `compiler/backend/`, `compiler/eval/`.

> **This repo's #1 bug class is `check` green / `run` or `build` wrong.** A *silent* one — a
> compiled binary printing a wrong answer with no error — is the worst outcome the project has.

**The gate that owns this class:** `test/diff_compiler_run_check_agreement.sh`. It compares the
**value** (`run` stdout == built-binary stdout), and a rejected program must be rejected by a
**DIAGNOSTIC, never a runtime panic**. Add a fixture for every fix, **in both directions**.

---

## ✅ CLOSED 2026-07-14 (read these — the *reasons* are the reusable part)

| | bug | why it hid |
|---|---|---|
| **S-1** | constrained definer-shadow: `build` printed a **heap pointer** where the answer was `4` | the dict-marking prePass is a **first-match guard chain** with the shadow arm ahead of the dict arm, so the call was never marked `EDictAt` — while the *definition* still got its dict param |
| **S-2** | a duplicate top-level definition was accepted with **ZERO diagnostics** | `dupValueBindingErrors` only fired on **nullary** bindings, so it structurally could not see it. Discriminator: a legit multi-clause fn has **one** signature; two colliding fns have **two** |
| **#38** | record update wrote the **wrong record's slot** (silent on LLVM, `illegal cast` on wasm) | `CRecordUpdate` carried **no receiver type name** (its sibling `CVariantUpdate` does), so both emitters guessed from the bare field label, **first-match-wins** |
| **#40** | multi-module `run` **EXECUTED ill-typed programs** | `checkImplObligations` runs only when `implInferEnabled` is OFF; `elaborateModules` sets it ON **unconditionally**. A plain type mismatch DID gate — *which is why probing with one shows correct behavior* |
| **P0-21** | a user's shadow **leaked into the prelude** (14 phantom errors from an unused `map`) | the flat path computed shadow-hood over `core ++ user` and applied it to **core's own occurrences** |
| **#31/#32** | `newtype` entirely unusable; `EVariantUpdate` missing from eval | each needed **two** arms, not one — typecheck *and* eval |
| **TMC** | a leading **`$dict` param vetoed TMC on BOTH backends** — every unannotated polymorphic list builder silently lost TMC | see below. **Never a wasm bug**; native was broken identically, hidden behind a 256 MB stack |

---

## 🔴 STILL OPEN

### S-3 · A multi-TYPARAM interface bypasses the definer-shadow machinery
`interface Ix a i` + a shadow + `ix 1 2` → `check` and `build` agree and are **correct**; **`run` panics.**
Now **pinned as KNOWN-BAD** by `test/diff_compiler_shadow_semantics.sh` (fixture `d11`), so it can't rot.

Every entry point is gated on `singleParamIfaceMethod` — which, **despite its name, counts interface
TYPE PARAMS, not method params.** That name states the opposite of what it does and sent an agent
down a wrong hypothesis. **Rename it `singleTyparamIfaceMethod`** as part of this.

### S-4 · Invert S2 — a standalone must WIN over a same-named method  ⭐ IN PROGRESS
```medaka
eq : List Int -> List Int -> Bool
eq a b = True
main = println (debug (eq [1] [2]))    -- prints False. The user's function is SILENTLY IGNORED.
```
**The compiler is obeying the spec — the SPEC is the bug.** ~45 prelude method names (`map`,
`filter`, `length`, `compare`, `eq`, …) are landmines. Prereqs **S-1** and **P0-21** are merged.
Design: `compiler/SHADOW-INVERSION-DESIGN.md`. The shadow gate makes the ~5 flipping cells visible.

### Others
- **#45** — cross-interface `requires` + a ctor-pattern clause head breaks that method's own dispatch.
- **`export import core.{x}`** silently re-exports **nothing** — `stdlib/list.mdk`'s `filter` is broken
  today, and the export site is **silent**. Two fixes owed: make it work, *and* diagnose it.
- **project-mode divergence** — in a `medaka.toml` project, `check` **accepts** what `run` **rejects**,
  and `run` says *"run `medaka check` for details"*. Check says it's fine. A closed loop.
- **`run` discards buffered stdout on panic** — IN PROGRESS. Not ergonomics: it makes bugs
  *unprovable* (see #40 below).

---

## Why this class keeps recurring — read before you start

**1. One decision, derived twice, over a value that changed in between.** S-1, the literal-receiver
bug, and the refutable-guard miscompile were all this shape. *When you fix one, ask what else
re-derives that decision, and whether the thing it derives it from can still change.* Prefer making
the decision **travel with the node** over storing it in a mutable `Ref` — that is why the wasm
backend never had the guard bug.

**2. A gate that reports green over something it never examined.** Every silent bug here is that
sentence. Tonight alone: `test/shadow_fixtures/` was cited in a spec as its enforcement and **ran
nowhere**; `preflight` printed "skipped" for a gate it *ran*; `capture_goldens.sh` silently writes
**0 goldens** and exits 0 for an unknown arg; and my own CI monitors piped into a `jq` that **isn't
installed**, emitting nothing while looking alive.

**3. ⭐ AN ARTIFACT THAT ASSERTS A CONCLUSION IT CANNOT KNOW.** This is the newest and the worst,
because it corrupts *everyone downstream*, and each copy then reads like corroboration.
- `wasm_emit` prefixed every unbound name with **"gap —"** — a *category claim*. `index` is an
  interface method; it only resolves on a path that typechecks. **17 ledgered "wasm bugs" were never
  bugs.**
- `w_deep_append.mdk`'s header **asserted** it tested the `$mdk_append` intrinsic. It didn't — and
  that one false sentence sent the orchestrator to a completely wrong root cause.
- `TRMC-DESIGN.md` said the dict case had *"no real target — exhaustively verified ABSENT."* That
  audit was **impl-scoped**; the veto also gated the top-level path, where the population is *user code*.

**A diagnostic — and a fixture header, and a design doc — must report what it OBSERVED, not what it
CONCLUDED.**

**4. ⭐ A PARITY GATE CANNOT DETECT A BUG WHERE BOTH BACKENDS ARE EQUALLY WRONG.** The TMC veto lived
in a **shared** predicate, so both backends declined **identically** and the census was a green,
honest `12/12 same`. **Parity was gated; COVERAGE never was.** If two things are checked only against
*each other*, nothing checks the pair. The fix had to *start* with a coverage gate — and the pins must
be **falsified** (corrupt one; watch it go red) or they are decoration.

**5. Both obvious observables can be blind at once.** #40 was declared not-reproducible — publicly,
and wrongly — because the **exit code is 1 either way** *and* **`run` discards stdout on panic**, so a
`println` probe returns nothing whether the program executed or not. **Assert on the DIAGNOSTIC.**

---

## ⚠️ Practical traps (each cost real time tonight)

- **`stdlib/core.mdk` is THE PRELUDE.** Its blast radius is **5 golden families, ~120 files, 7 gates**,
  and **none of it is greppable**: snapshot goldens · **every `check` golden is a full prelude SCHEME
  DUMP** · `selfproc` + the LSP completion list · `eval_prelude`/`core_ir_prelude`/`core.test.golden`
  (doctests keyed on `core.mdk:NNN` **line numbers**) · `stdlib/core.lextok.golden` (**token dumps**).
  **Run the whole suite** — AGENTS.md says so, and I ignored it for five CI rounds.
- **The merge queue removes the O(N²) CI cost, NOT the O(N²) golden cost.** Goldens are *regenerated
  from source*, so two compiler branches always fight over `typecheck.md`. Neither git nor the queue
  can help. **Keep at most ONE compiler-source PR in flight.**
- **Goldens are RE-CUT from the merged source, never text-merged.** A 3-way merge of two goldens
  yields a file matching **neither** tree.
- **Before resolving any conflict, run `git diff --stat $BASE origin/main -- <file>`.** Twice tonight I
  was one command from silently reverting another orchestrator's merged work inside a PR titled
  something else entirely.
- **`git diff main` uses your STALE local ref.** Fetch, then diff three-dot against `origin/main`.
- Agents commit on their **own** branch name, not `worktree-agent-<id>`. Push by the reported SHA.
