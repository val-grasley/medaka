# ERROR-QUALITY.md

The authoritative **grading key** and **copy standard** for Medaka's error
messages. Use this to (a) score existing diagnostics against a fixed rubric and
(b) write new ones. It is a design doc, not an implementation plan: it describes
what a *good* Medaka error looks like and how to measure the gap, so a later
workstream can grade ~60 fixtures reproducibly and rewrite the worst offenders.

Scope note: this covers the **message payload and its rendering**, not the
diagnostic *plumbing*. The envelope is already an ADT
(`data Diag = Diag Severity String (Option Loc)` in
`compiler/driver/diagnostics.mdk`); errors already **accumulate** rather than
raise (~110 push sites, ~21 in `compiler/types/typecheck.mdk`). What is
stringly-typed and under-designed is the `String` message itself.

---

## 1. Principles

### Dual audience — human developers AND LLM coding agents, co-equal

Every Medaka error has **two first-class readers**, and neither is a second
thought:

- A **human developer** skimming a terminal, who needs to locate the problem,
  understand it in the vocabulary of their own program, and know what to change.
- An **LLM coding agent** parsing the output (often the JSON form) to decide its
  next edit, who needs *deterministic, machine-addressable* fields — a stable
  code, an exact span, and ideally a suggested edit it can apply verbatim.

These goals are mostly aligned: precise location, root-cause honesty, and a
concrete fix serve both. Where they diverge, we serve both explicitly — prose
for the human in the message body, structure for the agent in the JSON payload
(see §5). We do **not** dumb the prose down for the machine, nor bury the
structure the machine needs inside prose the human must re-parse.

### What "good" means

A good error is:

1. **Located** — points at the exact `file:line:col` (+ caret) of the true
   offending token/expression, not a downstream victim.
2. **Correct** — the diagnosis is actually true of the program.
3. **Root-cause-honest** — names the *real* source of the problem, not the first
   place the compiler happened to notice it, and does not spray cascade errors
   from one root cause.
4. **In the user's vocabulary** — talks about the names, types, and constructs
   *in this program*, not compiler internals (`TApp`, `Scheme`, `RDictFwd`,
   internal tyvar ids).
5. **Actionable** — says what to change, ideally with a concrete suggested edit.
6. **Categorized** — carries a stable code/category so it can be looked up,
   suppressed, tested, and matched by an agent across versions.

### The no-catchable-panics invariant, and what "recoverability" means here

Medaka has **no catchable panics**: there is no `try`/`catch`/`recover` in the
language, and compiler panics are unrecoverable — tooling (LSP, `medaka test`)
survives a compiler crash only through **process isolation**, never through
in-language exception handling. (This is a decided invariant; do not propose
error-handling constructs to "improve recoverability.")

So "recoverability" in this rubric means exactly one thing: **the compiler emits
a graceful, accumulated diagnostic instead of crashing.** A pipeline stage that
hits a malformed input should push a `Diag` and keep going (errors accumulate),
not `panic`. An input that provokes a raw panic / stack trace instead of a
positioned diagnostic is an automatic **0 on Located and Correct** — the reader
gets nothing usable.

---

## 2. Anatomy of a good Medaka error

A complete Medaka diagnostic has five parts. Current support is marked
**[have]**, **[partial]**, or **[missing]**.

1. **Precise location** — `file:L:C:` header, the echoed source line, and a
   caret under the offending column. **[have]** — rendered by `ppDiagCliSrc`
   (`compiler/driver/diagnostics.mdk`); the caret and source-line echo already
   ship. *Gap:* some diagnostics still land on a **placeholder loc** (the pure
   `parse` path) or a downstream span rather than the root token — precision is
   uneven, not absent. Resolve errors with no node span render as
   `<unknown location>:` **[partial]**.

2. **What rule/expectation was violated** — a short statement of the invariant
   that failed ("expected the two branches of an `if` to have the same type",
   "every constructor of `Bool` must be matched"). **[partial]** — today's
   messages state a *fact* (`No impl of Num for String`, `Type mismatch: Int vs
   a -> a`) but rarely name the *expectation* in plain terms.

3. **Why, in terms of THIS program** — the concrete names and types from the
   user's source, phrased so the user recognizes them. `Type mismatch: Int vs
   a -> a` is honest but talks in raw inferred types with internal-looking
   tyvars (`a`); it does not say *which* expression was `Int`, which was a
   function, or that the real problem is `add 1` being under-applied.
   **[partial]** — some types leak, program names are often absent.

4. **An actionable fix** — a `help:`-style line with a concrete suggested edit
   ("`add` takes 2 arguments but got 1 — did you mean `add 1 y`?"; "add a case
   for `False`"; for a misspelling, "did you mean `greeting`?"). **[missing]** —
   there is **no** general suggestion machinery. The *only* fix-hint in the
   entire compiler is one hardcoded parser case: `/=` → "did you mean '!=' for
   not-equal?" (`compiler/frontend/parser.mdk`). No identifier
   nearest-name/edit-distance suggestions, no "add missing case" hints.

5. **A stable error code/category** — e.g. `E-UNBOUND`, `E-TYPE-MISMATCH`,
   `W-NONEXHAUSTIVE`. **[missing]** — there is **no** code or machine category
   on any diagnostic. `Severity` (`SevError`/`SevWarning`) is the only
   structured discriminant; the category is implicit in the message prefix
   string only.

**Summary of the current gap:** location + caret are solid; message *content* is
a bare fact with no expectation framing, patchy program-vocabulary, **no fix
line**, and **no error code**. Parts 4 and 5 are the highest-value missing
pieces and the ones the LLM audience needs most.

---

## 3. Scored grading rubric

Seven dimensions, each scored **0 / 1 / 2**. Max **14**. Simple enough to apply
by eye to ~60 fixtures; a fixture's total and per-dimension breakdown are both
recorded so regressions are visible.

| # | Dimension | 0 | 1 | 2 |
|---|-----------|---|---|---|
| L | **Located** | Wrong span, placeholder loc, or a raw panic instead of a diagnostic | Right line, imprecise column / lands on a downstream victim | Caret on the exact offending token |
| C | **Correct** | Diagnosis is false or misleading | True but framed as a symptom, not the cause | Accurate diagnosis of the real defect |
| R | **Points at root cause** | Blames a cascade victim / spews N errors from 1 cause | Names the right area but not the precise cause | Pinpoints the single root cause; no cascade |
| F | **Actionable fix** | No hint at all | Vague direction ("check the types") | Concrete suggested edit the reader/agent can apply |
| J | **Jargon-free** | Exposes compiler internals (`Scheme`, `TApp`, internal ids) | Mostly plain but leaks one internal term / raw tyvar | Entirely in the user's program vocabulary |
| X | **Cascade-free** | One root cause emits a storm of follow-on errors | A couple of spurious follow-ons | Exactly one diagnostic per root cause |
| A | **Agent-parseable** | No JSON, or JSON missing location | JSON with span but no code/kind/fix | JSON with stable `code`, `kind`, span, and machine `fix` |

Scoring guidance:
- **L** and **A** are structural and cheap to score from the CLI + `--json`
  output directly.
- **R** and **X** require running the fixture and reading the *whole* diagnostic
  list, not just the first line.
- A **raw panic** (no positioned diagnostic) caps the fixture at **L=0, C=0**.
- Warnings (`W-*`, e.g. non-exhaustive match) are scored on the same axes; **F**
  for a warning means "names the concrete missing case(s)".

Target for the workstream: no fixture below **8/14**, and every fixture scoring
**2 on A** (agent-parseable) once §5 lands.

---

## 4. Before → after exemplars

North stars: **Rust** (stable `E0308` codes + `help:` suggestion lines),
**Elm** ("I was expecting…" prose that names the concrete types), **Roc**
(friendly root-cause framing). We adopt their *substance* — codes, a `help:`
line, expectation framing — while keeping Medaka's terse `file:L:C:` + caret
idiom. We do **not** adopt Elm/Roc's full-screen boxed multi-paragraph format;
Medaka stays one compact block per diagnostic.

All "before" blocks below are **actual verbatim** output of the current binary
(`./medaka check`). Columns/spans are real.

### 4.1 Unbound variable (misspelling)

**Before (current):**
```
unbound.mdk:1:16: Unbound variable: greetng
  |
1 | main = println (greetng "world")
  |                 ^
```

**After (target):**
```
unbound.mdk:1:16: [E-UNBOUND] Unbound variable: greetng
  |
1 | main = println (greetng "world")
  |                 ^
help: no name `greetng` is in scope — did you mean `greeting`?
```
Adds the code and a nearest-name suggestion (edit-distance over in-scope names).
This is the single highest-leverage `help:` because it is trivially
agent-applicable.

### 4.2 Type mismatch / no-impl

**Before (current):**
```
typemismatch.mdk:1:26: No impl of Num for String
  |
1 | main = println (1 + "hello")
  |                           ^
```

**After (target):**
```
typemismatch.mdk:1:26: [E-NO-IMPL] `+` needs a `Num`, but `"hello"` is a `String`
  |
1 | main = println (1 + "hello")
  |                           ^
help: `String` has no `Num` impl — `+` on strings isn't defined; use `++` to concatenate.
```
Names the operator, the offending sub-expression, and its type in program terms,
and offers the concrete fix (`++`). The bare "No impl of Num for String" is
correct but leaves the reader to reconstruct which expression and what to do.

### 4.3 Arity mismatch (under-application)

**Before (current):**
```
arity.mdk:4:33: Type mismatch: Int vs a -> a
  |
4 | main = println (intToString (add 1))
  |                                  ^
```

**After (target):**
```
arity.mdk:4:33: [E-ARITY] `add` is applied to 1 argument but needs 2
  |
4 | main = println (intToString (add 1))
  |                                  ^
help: `add : Int -> Int -> Int`; `add 1` still expects one more `Int`.
      `intToString` wants an `Int`, but got the partially-applied function.
```
The current message (`Int vs a -> a`) is the *symptom* of under-application; it
exposes a raw tyvar `a` and never says the word "argument". This is the clearest
case where **R (root cause)** and **J (jargon)** both score low today.

### 4.4 Non-exhaustive match (warning)

**Before (current):** (`check` prints inferred schemes, then:)
```
nonexhaust.mdk:3:14: Warning: non-exhaustive match — some values may not be covered
```

**After (target):**
```
nonexhaust.mdk:3:14: [W-NONEXHAUSTIVE] `match` doesn't cover every case of `Bool`
  |
3 |   True => "yes"
  |   ^
help: missing case: `False`. Add `False => ...` or a wildcard `_ => ...`.
```
Names the *type* being matched and the *specific* uncovered constructor(s) — the
exhaustiveness checker already computes this witness internally; surfacing it is
the win.

### 4.5 Parse error

**Before (current):**
```
parseerr.mdk:2:15: Parse error
```
(No caret block — the source line couldn't be echoed at EOF.)

**After (target):**
```
parseerr.mdk:2:15: [E-PARSE] unexpected end of input after `+`
  |
1 | main = println (1 +
  |                   ^
help: `+` expects a right-hand operand; the expression / `(` is unterminated.
```
"Parse error" is the least informative diagnostic in the compiler. The target
names *what* was expected next and *why*, matching the one good existing
precedent (the `/=` → `!=` hint).

---

## 5. Machine-readable contract for agents

### Current JSON shape (verified)

`medaka check --json <file>` emits (from `cjDiagnostic`/`cjAllToJson`,
`compiler/driver/diagnostics.mdk`):

```json
{"files":[{"file":"…/unbound.mdk","diagnostics":[
  {"message":"Unbound variable: greetng",
   "range":{"start":{"line":0,"character":16},"end":{"line":0,"character":23}},
   "severity":1,
   "source":"medaka"}]}]}
```

Fields today: `message` (String), `range` (0-based LSP line/char, start+end),
`severity` (1=error, 2=warning), `source` (always `"medaka"`). The range is
real and precise for typed/resolve errors; **warnings** bake `file:L:C:` into
the `message` string and leave `range` at the `{0,0}` dummy (an inconsistency an
agent must special-case — see Open decisions).

### Target contract

An LLM agent should be able to read, per diagnostic, a deterministic
`file : line : column : code : kind : fix` without parsing prose. Target object:

```json
{"file":"…/unbound.mdk",
 "range":{"start":{"line":0,"character":16},"end":{"line":0,"character":23}},
 "severity":1,
 "code":"E-UNBOUND",
 "kind":"resolve",
 "message":"Unbound variable: greetng",
 "help":"did you mean `greeting`?",
 "fix":{"range":{"start":{"line":0,"character":16},"end":{"line":0,"character":23}},
        "replacement":"greeting"},
 "source":"medaka"}
```

Target fields and current gaps:

| Field | Purpose | Status |
|-------|---------|--------|
| `range` | exact span | **have** for errors; **broken for warnings** (dummy `{0,0}`, loc in message) |
| `severity` | error/warning | **have** |
| `source` | producer | **have** |
| `message` | human prose | **have** |
| `code` | stable machine category (`E-UNBOUND`, …) | **missing** — needed for §3 dim A |
| `kind` | producing stage (`parse`/`resolve`/`type`/`exhaust`) | **missing** (implicit today) |
| `help` | human fix line | **missing** |
| `fix` | machine-applicable edit (`range` + `replacement`) | **missing** — the highest-value agent field |

Minimum to reach "2 on Agent-parseable": add `code` and `kind` to every
diagnostic, and fix the warning `range` regression so *every* diagnostic carries
a real span. `help`/`fix` are the follow-on wins and can land per-category.

---

## Open decisions

These need a human call before implementation; do not decide unilaterally.

1. **Error-code scheme.** Rust-style opaque numeric (`E0308`) vs. readable
   kebab tags (`E-UNBOUND`, `E-NO-IMPL`, `W-NONEXHAUSTIVE`, used above). Readable
   tags are more agent- and human-legible and don't need a central registry
   allocator; numeric codes are terser and doc-linkable. Also: one flat
   namespace vs. per-stage prefixes (`P-*` parse, `R-*` resolve, `T-*` type).

2. **`help:` line format.** Single `help:` line (Rust-like, chosen in the
   exemplars) vs. multiple `help:`/`note:` lines. Whether `help:` is part of the
   CLI text *and* a JSON field, or JSON-only with the CLI staying one block.

3. **Machine `fix` scope.** Do we commit to emitting applicable-edit `fix`
   objects (range + replacement) for the mechanical categories (misspelling,
   `/=`→`!=`, add-missing-case), or ship `help` prose only in v1 and defer
   structured fixes? This also gates whether `medaka check --fix` becomes a
   thing (parallel to `medaka lint --fix`).

4. **Suggestion machinery cost.** Nearest-name suggestions need an
   edit-distance pass over in-scope names in `resolve`. Decide the threshold
   (max distance) and whether it runs always or only when the JSON/`--verbose`
   consumer asks (it is pure and cheap, so "always" is likely fine).

5. **Warning-range regression.** Fixing warnings to carry a real `range`
   (instead of loc-in-message + `{0,0}`) changes the `--json` output and will
   perturb `test/diff_compiler_diagnostics` and `check_json` goldens. Confirm
   we recapture those goldens as part of the workstream (the current shape is a
   deliberate oracle-compat artifact, not a bug per se).

6. **How much prose.** House style is one compact `file:L:C:` block + caret +
   optional `help:` — explicitly *not* Elm/Roc full-screen boxes. Confirm this
   ceiling so graders don't reward verbosity.
