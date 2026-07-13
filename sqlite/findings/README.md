# SQLite dogfood — language findings

This directory is the **pain-point log** for the SQLite library workstream. The library is a
dogfood vehicle: every hour spent writing real Medaka against a real problem is an hour of
free evidence about what the language, stdlib, compiler, and tooling get wrong.

**Every agent working in `sqlite/` writes exactly one file here**, named for its task
(e.g. `sql-parser-expr.md`). Do not append to a shared file — one file per agent keeps
concurrent branches conflict-free. The orchestrator consolidates.

## What counts as a finding

Log it if it cost you time, made you hesitate, or made you write something you'd be
embarrassed to show a newcomer. Specifically:

- **Compiler bugs** — wrong behavior, a crash, `run` ≠ `build` ≠ `check` disagreement.
- **Misleading, unlocated, or incomplete error messages** — the single highest-value
  category. If you had to guess what an error meant, that's a finding.
- **Missing stdlib** — a function you expected to exist and didn't (say what you wrote instead).
- **Unintuitive or surprising language behavior** — anything where your first, reasonable
  attempt didn't work and the reason wasn't obvious.
- **Ergonomic friction** — boilerplate the language should have absorbed; a construct that
  forced an awkward shape.
- **Tooling** — `fmt`, `lint`, `check --json`, the LSP, `medaka test`.

**Non-findings:** things you got wrong that the docs clearly explain. Check `SYNTAX.md` first.

## Format

One `##` section per finding. Keep them short and concrete — a finding without a
**reproducer** is not actionable.

```markdown
## F<n> — <one-line title>

- **Category:** compiler-bug | error-message | missing-stdlib | surprising-semantics | ergonomics | tooling
- **Severity:** blocker | workaround-required | annoyance
- **Repro:**
  ```medaka
  -- the smallest program that shows it
  ```
- **Expected:** what a reasonable person would predict.
- **Actual:** what happened, verbatim (paste the real error text).
- **Workaround:** what you did instead (or "none — blocked").
- **Notes:** where you think it lives, if you have a guess. A guess is fine; don't go
  spelunking in `compiler/` to confirm it — that is another orchestrator's job.
```

## Scope rules for agents

- **Do NOT edit `compiler/`.** A separate orchestrator owns that tree this session. Report,
  work around, move on.
- **You MAY add a genuinely missing pure-Medaka function to `stdlib/`** (no new externs) if
  the library needs it — with a doctest. Flag it in your findings file so the orchestrator
  knows the change needs fixpoint verification before it reaches `main`.
- **Do NOT run `make medaka`.** The library is pure Medaka; the prebuilt `./medaka` compiles
  it. Rebuilding the compiler is a multi-minute op that contends with other sessions.
