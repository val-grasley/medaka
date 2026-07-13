---
name: pr-review
description: Review an agent-authored PR diff for craft — style, efficiency, missing tests, lying comments, leftover workarounds. Read-only. Run AFTER CI is green; gates prove behavior, this judges craft.
---

# PR review playbook

You are reviewing a diff authored by another agent. **You are READ-ONLY.** Report
findings; do not fix them. The authoring agent has the context and will apply fixes.

**Run this AFTER CI is green.** Gates prove *behavior*. You are judging *craft*. A green
diff can still be a bad diff.

## Ground rules

- **Read the diff, then read the surrounding code.** A change that looks fine in isolation
  is often wrong in context (wrong layer, duplicates an existing helper, breaks a local
  convention). `git diff main...HEAD` then open the files it touches.
- **Reproduce before you assert.** This project's own docs are *systematically stale* (see
  ORCHESTRATING.md, "The gap docs lie"). If you think something is broken, run it. A
  confident wrong finding wastes an Opus agent's day.
- **Rank by what would actually bite.** Three real findings beat twenty nits. If you have
  no substantive findings, SAY SO — do not manufacture some to look thorough.

## What to look for

**1. Correctness the gates cannot see**
- A comment that no longer describes the code (a lying comment is worse than none).
- A test that asserts the *wrong thing* but passes — especially a golden that was
  regenerated to match a bug rather than fixed. **This is the highest-value thing you can
  find here.** Ask of every changed golden: *did the expected output change because the
  code got better, or because someone blessed a regression?*
- Error paths, empty inputs, and the boundary the change just moved.
- A `norm()`/`sed` applied to BOTH sides of a comparison — that is a hole in the test, not
  a normalization (see docs/ops/TESTING-DESIGN.md §4.5 Law 1: normalize the ACTUAL, never the
  expected). This exact pattern hid a float-literal blind spot for months.

**2. Silent-skip / silent-green hazards** — this project's defining bug class
- Does any new gate/script exit 0 having tested nothing? A glob that matches no files, a
  loop over an empty list, an `exit 2` treated as a skip?
- Does a new skip-list or exception-list detect an **accidental fix**? A list that only
  suppresses failures ROTS — it cannot notice when the bug is fixed. Every such list must
  fail loudly when an entry starts passing.
- Was a check *weakened* to make something pass?

**3. Reuse and duplication**
- Does this re-implement something in `compiler/support/`, `stdlib/`, or another gate?
- The tree is at **0 `medaka lint` findings** and the pre-commit hook is a max-ratchet.
  Did they `-- lint-disable` something? Is the exemption justified *in a comment*?

**4. Efficiency, where it matters**
- Is a hot inner loop now dict-passed / non-short-circuiting? (Measured: delegating
  `util.mdk`'s hot helpers to prelude Foldable methods cost **+56% self-compile**.)
- O(N²) membership/index scans — this codebase has repeatedly been bitten by them.
- Don't micro-optimize cold paths. Flag it only if it is on a path that runs per-token,
  per-node, or per-fixture.

**5. Missing tests**
- Is there a regression test for the *specific* bug fixed? Would the suite have caught
  this before the fix?
- **Does it exercise the right path?** A dispatch bug that reproduces through the loader
  but is green single-file needs a MULTI-MODULE test — a single-file doctest proves
  nothing (this shape has recurred at Phases 96/103/121/125/134).
- Compiler-source change → is the fixpoint (`selfcompile_fixpoint.sh`) the decisive gate,
  and did they run it?

**6. Scope and hygiene**
- Did the diff creep beyond its brief? Stray files, `git add -A` collateral, build
  artifacts, debug prints, commented-out code?
- Is the commit message honest about what it did *and did not* do?

## Output

A ranked list. For each finding:

```
[severity: high | medium | nit]  <file>:<line>
  WHAT:  one sentence.
  WHY:   the concrete failure it causes (inputs -> wrong result), not a principle.
  FIX:   what you would do instead.
```

Then one line: **`VERDICT: merge | merge-with-fixes | needs-work`**.

If you found nothing substantive: say `VERDICT: merge` and briefly say what you checked,
so the orchestrator knows the review had teeth.

## Finally — the friction report

Like every agent, end with anything that fought *you*: unclear code, misleading docs, a
tool that did not work as advertised. The orchestrator triages it.
