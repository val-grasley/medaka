# Workstream: DIAGNOSTICS

**Owns:** error-message quality, and wrong source locations.
**Touches:** `compiler/driver/diagnostics.mdk`, `compiler/frontend/`.

```sh
gh issue list --label "ws:diagnostics" --state open
```

Read **`compiler/ERROR-QUALITY.md`** (the rubric) and **`compiler/DIAGNOSTIC-CODES-DESIGN.md`** (the
taxonomy) first. A new diagnostic needs a **stable code**.

---

## ⚠️ This workstream's own backlog was 2/3 stale. Reproduce first.

When the backlog was rebuilt on 2026-07-14 against `e34e2b46`, the top **two** DIAGNOSTICS items were
already fixed:

- **"A fabricated `1:0` source location"** — *did not reproduce on any error shape.* Type mismatch,
  missing impl, signature-vs-body: all three report a correct `file:L:C`.
- **"'Clauses must be contiguous' for a duplicate definition"** — the message that *"advises you to
  merge two different functions"* is gone. It now says: *"'foo' is already defined at line 1. A name
  may have only one type signature — rename or remove this duplicate definition, or merge the clauses
  into a single multi-clause function if that was the intent."* That is the fix the item asked for.
- So is the release plan's one listed error-quality exception: non-exhaustive-match **warnings** now
  carry `file:L:C`.

Three items, three fixes, zero updates to the doc that tracked them. **That is the whole argument for
moving the backlog into the issue tracker** — an issue closes; a bullet does not.

---

## The rule this workstream exists to defend

**A diagnostic reports what it OBSERVED, not what it CONCLUDED.**

- **A diagnostic with no location must SAY it has no location, not invent one.** A confidently wrong
  location is worse than none: it sends the reader to the wrong place *and they trust it*.
- **A diagnostic must not assert a category it cannot know.** `wasm_emit` prefixed every unbound name
  with `"gap —"`, asserting a *backend coverage gap* — but an unbound name can just mean the program
  never typechecked. **17 ledgered "wasm bugs" were never bugs**, and the false category propagated
  into ledgers, docs, and agent prompts, each copy reading like corroboration.
- **A diagnostic must not give advice that is wrong for the situation it is in.** The removal
  diagnostics for `record`/`mut`/`function` fire on the **bare token regardless of syntactic
  position** (#62), so a user naming a variable `record` is told how to declare a record type.

---

## Structure

**Errors accumulate.** Phases push into `compiler/driver/diagnostics.mdk` rather than raising on the
first error. **Do not add early-exit/raise paths.**

**Two typecheck entry points** (`checkProgramSeeded` single-file ∥ `checkModuleFullImpl` per-module)
are textually duplicated and kept in **manual** lockstep — so a diagnostic added to one is **silently
absent from the other**. That is exactly how the 2026-06-14 imported-module bug happened. Mirror both,
or fix the root (#80).

**`medaka check --json`** is the machine-readable surface — a stable `code`, a real `range`, a
`severity`, and for suggestion-bearing errors a `help` string plus a machine-applicable
`fix { range, replacement }`. **Key off `code`**; it does not move when wording changes.

---

## The parked idea worth knowing about

A **structured type-error ADT** — one variant per error kind, plus a single pretty-printer, replacing
today's string messages — would enable LSP error codes and quickfixes properly. It is parked because it
churns the hottest in-graph file (`compiler/types/typecheck.mdk`, ~34 raise sites) and needs a
`selfcompile_fixpoint` + seed re-mint. `PLAN.md:1303`.

**`MEDAKA_TC_TRACE=1` (#69) is the cheap thing that pays now, and does not depend on it.** Do the cheap
thing first.
</content>
