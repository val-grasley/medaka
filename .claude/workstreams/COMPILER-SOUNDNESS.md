# Workstream: COMPILER SOUNDNESS

**Owns:** miscompiles, and any disagreement between `check` / `run` / `build`.
**Touches:** `compiler/types/typecheck.mdk`, `compiler/backend/`, `compiler/eval/`.

```sh
gh issue list --label "ws:soundness" --state open
```

> **This repo's #1 bug class is `check` green / `run` or `build` wrong.** A *silent* one — a compiled
> binary printing a wrong answer with no error — is the worst outcome the project has.

**The gate that owns this class:** `test/diff_compiler_run_check_agreement.sh`. It compares the
**value** (`run` stdout == built-binary stdout), and a rejected program must be rejected by a
**DIAGNOSTIC, never a runtime panic**. Add a fixture for every fix, **in both directions**.

---

## Why this class keeps recurring — read before you start

**1. One decision, derived twice, over a value that changed in between.** The constrained
definer-shadow bug (S-1), the literal-receiver bug, and the refutable-guard miscompile were all this
shape. *When you fix one, ask what else re-derives that decision, and whether the thing it derives it
from can still change.* Prefer making the decision **travel with the node** over storing it in a
mutable `Ref` — that is why the WasmGC backend never had the guard bug.

**2. A decision implemented TWICE, where nothing forces the second copy to agree.** The disease behind
three separate incidents:

- `evalModules` (`eval/eval.mdk`) and `cevalModules` (`ir/core_ir_eval.mdk`) are **parallel module
  drivers — fix module-frame semantics in LOCKSTEP.** That is how the P0-9 cross-module ctor-collision
  fix shipped patching only `eval.mdk`, leaving `core_ir_eval.mdk` broken for months.
- `checkProgramSeeded` ∥ `checkModuleFullImpl` — two textually duplicated typecheck bodies whose
  comments literally say *"mirrors …"*. **The 2026-06-14 imported-module bug was exactly a mirror
  miss.** → **#80**, *"the highest-value soundness step."*
- **A one-backend fix is a half fix** (**#59**): an LLVM fix that never reached wasm. The workaround
  was reverted on the strength of a green verifier, and only the wasm tandem gate caught it.

**Every fix in this repo should ask: *what is the mirror, and does it know?***

**3. A gate that reports green over something it never examined.** Every silent bug here is that
sentence. In one night: `test/shadow_fixtures/` was cited in a spec as its enforcement and **ran
nowhere**; `preflight` printed "skipped" for a gate it *ran*; `capture_goldens.sh` silently wrote **0
goldens** and exited 0 for an unknown arg; and CI monitors piped into a `jq` that **isn't installed**,
emitting nothing while looking alive.

**4. ⭐ AN ARTIFACT THAT ASSERTS A CONCLUSION IT CANNOT KNOW.** The worst, because it corrupts
*everyone downstream*, and each copy then reads like corroboration.

- `wasm_emit` prefixed every unbound name with **"gap —"** — a *category claim*. `index` is an
  interface method; it only resolves on a path that typechecks. **17 ledgered "wasm bugs" were never
  bugs.**
- `w_deep_append.mdk`'s header **asserted** it tested the `$mdk_append` intrinsic. It didn't — and that
  one false sentence sent an orchestrator to a completely wrong root cause.
- `TRMC-DESIGN.md` said the dict case had *"no real target — exhaustively verified ABSENT."* That audit
  was **impl-scoped**; the veto also gated the top-level path, where the population is *user code*.

**A diagnostic — and a fixture header, and a design doc, and an issue body — must report what it
OBSERVED, not what it CONCLUDED.** That is why every issue is labelled `verified` or `needs-repro`,
and why the distinction is not decoration.

**4b. ⭐⭐ AND THE DEBUNKING NEEDS THE SAME PROOF AS THE FILING.** This is the trap on the *other*
side of #4, and we walked into it within a day of writing #4 down.

Having learned that 17 ledgered "wasm bugs" were never bugs, someone corrected the ledger — and
`engine_divergence.txt`'s header came to assert, of three rows:

> *"NONE of them were wasm bugs. They were artifacts of the gate's own wasm arm."*

**All three were real wasm bugs**, fixed 2026-07-14 (`num_int_max`, `num_int_min`,
`where_sibling_ref`). The *denial* was every bit as unfounded as the original filing — same
confident tone, same absent evidence, and now with the borrowed authority of a correction, so it
reads as the *result* of the audit rather than another unevidenced claim inside it.

A correction feels like the safe direction. It is not, and the reason is structural, not a matter
of care:

> **"This is not a bug" quantifies over all inputs. "Here is one input where it breaks" needs a
> single witness.** Un-filing a row therefore costs strictly MORE evidence than filing it.

**To close a row, produce the passing run. To keep it, produce the failing one. Never resolve one
on prose.**

⚠️ **This section is clean today by luck, not design — it cites no `#N` issue numbers.** The
moment a future entry here names a GH issue, it acquires the identical failure mode `EMITTER.md`
hit with `#305` (#488): an encoded claim about that issue's state, with no derivation and no
expiry. If you add one: run `gh issue view <N> --json state` before AND after any change here,
and drain this ledger in the SAME commit that closes the issue — see `EMITTER.md`'s §9 drain-rule
callout for the exact convention to copy.

**5. ⭐ A PARITY GATE CANNOT DETECT A BUG WHERE BOTH BACKENDS ARE EQUALLY WRONG.** The TMC dict-veto
lived in a **shared** predicate, so both backends declined **identically** and the census was a green,
honest `12/12 same`. **Parity was gated; COVERAGE never was.** If two things are checked only against
*each other*, nothing checks the pair. The fix had to *start* with a coverage gate — and the pins must
be **falsified** (corrupt one; watch it go red) or they are decoration.

**6. Both obvious observables can be blind at once.** The multi-module ill-typed-`run` bug was declared
not-reproducible — publicly, and wrongly — because the **exit code is 1 either way** *and* **`run`
discarded stdout on panic**, so a `println` probe returned nothing whether the program executed or not.
**Assert on the DIAGNOSTIC.** (The stdout half is now fixed — `41a5986b`.)

---

## ⚠️ Practical traps (each cost real time)

- **`stdlib/core.mdk` is THE PRELUDE.** Blast radius: **5 golden families, ~120 files, 7 gates** — and
  **none of it is greppable**: snapshot goldens · **every `check` golden is a full prelude SCHEME
  DUMP** · `selfproc` + the LSP completion list ·
  `eval_prelude`/`core_ir_prelude`/`core.test.golden` (doctests keyed on `core.mdk:NNN` **line
  numbers**) · `stdlib/core.lextok.golden` (**token dumps**). **Run the whole suite.** Three agents in
  one session claimed "no goldens moved". All three were wrong.
- **The merge queue removes the O(N²) CI cost, NOT the O(N²) golden cost.** Goldens are *regenerated
  from source*, so two compiler branches always fight over the same golden. Neither git nor the queue
  can help. **Keep at most ONE compiler-source PR in flight.**
- **Goldens are RE-CUT from the merged source, never text-merged.** A 3-way merge of two goldens yields
  a file matching **neither** tree.
- **Before resolving any conflict, run `git diff --stat $BASE origin/main -- <file>`.** Twice in one
  night an orchestrator was one command from silently reverting another's merged work inside a PR
  titled something else entirely.
- **`git diff main` uses your STALE local ref.** Fetch, then diff three-dot against `origin/main`.
- **`singleParamIfaceMethod` counts interface TYPE PARAMS, not method params.** The name states the
  opposite of what it does and has already sent one agent down a wrong hypothesis. It is renamed
  `singleTyparamIfaceMethod` as part of **#54**.

---

## Where the specs live

- `docs/spec/SHADOW-SEMANTICS.md` — the standalone-fn ⇄ interface-method shadowing rules (S1–S8), and
  the **S7 path-agreement** rule that #54 violates.
- `compiler/SHADOW-INVERSION-DESIGN.md` — the design for **#50** (a standalone must WIN over a
  same-named method). *The compiler is obeying the spec; the SPEC is the bug.*
- `docs/spec/DICT-SEMANTICS.md` — dictionary-passing semantics (D1–D10, all closed).
- `docs/spec/EMITTER-SEMANTICS.md` — the native-backend refinement contract (observation
  preservation, value rep, numeric/trap laws, determinism); §9 is the live conformance table.
- `test/diff_compiler_shadow_semantics.sh` — pins every shadow cell, **including the KNOWN-BAD ones**.
  A fix must update the pin **in the same PR**.
</content>
