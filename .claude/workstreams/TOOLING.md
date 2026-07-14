# Workstream: TOOLING & CLI

**Owns:** `fmt` · `lint` · `test` · `doc` · `repl` · `lsp` · the CLI's ergonomics.
**Touches:** `compiler/tools/`, `compiler/driver/`.

```sh
gh issue list --label "ws:tooling" --state open
```

**These tools are the entire surface a user touches.** A compiler bug costs one program; a `fmt` bug
costs the file.

---

## The two things that make this workstream sharp

**1. `fmt` runs in the pre-commit hook.** So a `fmt` bug is not an inconvenience — it is a **source
destroyer on the path we tell people to take** (#51: `fmt --write` rewrites a float into a form the
lexer cannot read). Anything that mutates source in the hook deserves paranoid treatment.

**2. Every doctest in this repo runs under the INTERPRETER.** So a bug that exists only in compiled
code is invisible to the entire in-language test suite. The SQL expression parser shipped with **32/32
green doctests while every arithmetic operator in its grammar was silently broken in the native
binary**. That is a gap in the *testing strategy*, not just a set of bugs — and it is why
`docs/ops/TESTING-DESIGN.md` §4.7's "promote from the interpreter, **then assert the native build
produces byte-identical doctest output**" is the composition that matters (#81).

Corollary: a tool that can **silently zero a file's doctests** (#55 — one prose blockquote does it) is
S1, not a nit. A file whose doctests all vanished looks exactly like a file with no doctests.

---

## Reacting to compiler errors programmatically? Use `--json`.

`medaka check --json <file>` (note: `--json`, **not** `--format=json`) emits one JSON object per
diagnostic carrying a stable **`code`** (`T-*` type · `R-*` resolve · `P-*` parse · `L-*` lex · `W-*`
warning), a `kind`, a real `range` (0-based LSP line/char), `severity` (1=error, 2=warning), the
`message`, and — for suggestion-bearing errors — a `help` string plus a machine-applicable
`fix { range, replacement }` you can apply verbatim.

**Key off `code`.** It is the stable handle and it does not move when wording changes.

---

## The pre-commit hook (ACTIVE)

`.githooks/pre-commit` runs over each staged `.mdk` (`test/` fixtures excluded — they violate style on
purpose). Re-install after a fresh clone:
`cp .githooks/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"`.

- **Format** — `medaka fmt --check` rejects any staged unformatted `.mdk`. The whole tree is clean.
  **Run `medaka fmt --write <changed.mdk>` and re-`git add` before committing any `.mdk` edit.**
- **Lint** — the tree is at **0 findings and the hook is a MAX RATCHET: all ~20 rules gated**, so any
  NEW finding of any rule fails the commit. The cross-file `rule-duplicate-body` can't be checked
  per-staged-file, so the hook also runs one whole-project scan.
  Silence a genuine exception inline: `-- lint-disable-next-line <rule>`.
  ⚠️ `medaka lint --fix` **bails on any decl containing an interior comment** (it would otherwise drop
  them) — safe, but it leaves comment-bearing sites unfixed.

Emergency bypass for either: `git commit --no-verify`.

---

## ⚠️ The linter can recommend an unbuildable program

`rule-hand-rolled-derivable` tells you to replace a hand-written `Eq` with `deriving (Eq)` — which
**cannot be built** over an `Array` field (#56). The tool actively advises you into the bug.

**A lint rule that suggests a fix must be able to state that the fix compiles.** When you add a
suggesting rule, ask what proves the suggestion is buildable.

---

## Concurrent `medaka build` is scratch-path safe — and this is load-bearing

`build_cmd.mdk` stages every scratch file inside ONE `mktemp -d` unique to that build **process**.

⚠️ Until 2026-07-13 the IR path was keyed on the **output basename** in global `/tmp`, so two
concurrent builds writing `-o <somedir>/out` — different worktrees, different repos — clobbered each
other's IR and produced a **stable-looking WRONG binary** (19/20 iterations). Anything that "keys the
temp file on something distinctive" is a trap; only a per-process temp dir is correct.

**Run a newly-parallelized gate several times** — a temp-collision flake shows ~1 in N.
</content>
