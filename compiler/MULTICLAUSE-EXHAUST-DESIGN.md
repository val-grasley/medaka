# Multi-Clause Function Exhaustiveness — Design

**Status:** IMPLEMENTED — `f317fef6`, after 2026-07-07. **This header originally said
"DESIGN ONLY... Nothing built" — that is now FALSE.** `checkGuardExhaustivenessWith
oracleDecls checkDecls` (`compiler/frontend/exhaust.mdk:824`) builds the constructor
oracle from a superset (runtime + core + every loaded module) exactly as this doc's §3
recommends, closing the false-positive class this doc diagnosed. Verified live in source.

Below (kept for record) is the doc's original text, which predates the fix — read it as
history, not as the current state:

Status: **DESIGN ONLY (read-only measurement pass, 2026-07-07).** Nothing built.
No compiler source committed. A throwaway gate-removal edit was applied to
`compiler/frontend/exhaust.mdk` **for measurement only** and reverted
(`git checkout`); the tree is clean.

All file:line citations were against a since-discarded agent worktree (path removed,
2026-07-13 doc pass — never a valid path for anyone else).

Base check: `git merge-base --is-ancestor 54344aba HEAD` → **BASE_OK**.

---

## 0. TL;DR — the filed premise is wrong on two counts

The bug reproduces: a non-exhaustive multi-clause **function** gets no warning
while the equivalent `match` does. But the filed remediation ("remove a 1-line
gate; then clean up ~524 intentional partials") is **not** the right fix:

1. **The blast radius is bigger than filed.** Removing the gate surfaces
   **826** warnings tree-wide (measured), not ~524: **stdlib 11 + compiler 781
   + sqlite 34**.

2. **The overwhelming majority are FALSE POSITIVES, not intentional partials.**
   The exhaust.mdk guard/clause engine builds its constructor oracle from the
   **entry module's own `DData`/`DRecord` decls only** (`buildOracle`,
   `exhaust.mdk:116`). Any scrutinee whose ADT is **imported** (`Expr`, `Decl`,
   `Pat`, `Ty`, IR types, `Result`, …) is invisible to that oracle, so the
   engine treats its constructor set as **open** and flags **every**
   constructor-matching clause group with no catch-all as "non-exhaustive" —
   **even when it covers every constructor.** Measured, with the imported ADTs
   added to the oracle (simulating the real fix): `typecheck.mdk` **132 → 1**,
   `lint.mdk` **84 → 0**, `eval.mdk` **35 → 3**, `marker.mdk` **25 → 2**,
   `wasm_emit.mdk` **98 → 5**. i.e. ~90–100% of the 826 are spurious.

The `match` path does NOT have this bug because it runs inside `typecheck.mdk`
against `matchOracle`, which is built from the **full program** (runtime + core
+ all modules). **The real defect is that the multi-clause path uses a
weaker (entry-only) oracle than the match path.**

**Consequence for the plan:** the responsible fix is *engine correctness*
(give the multi-clause path the full-program oracle + a witness message + a
per-clause loc), NOT a mass "cleanup of intentional partials." After the oracle
fix the genuine residual is small (order a few dozen tree-wide) and can be
triaged normally.

---

## 1. Reproduction (verified on current main)

Build: `make medaka` → native OCaml-free `medaka` (note: cold build printed a
pre-existing "C3a WARN: committed seed differs (lagging seed)" — unrelated to
this work).

`color_multi.mdk`:

```
data Color = Red | Green | Blue
f : Color -> Int
f Red = 1
f Green = 2                 -- missing Blue
g : Color -> Int
g c = match c
  Red => 1
  Green => 2               -- missing Blue
```

`medaka check color_multi.mdk`:
- **`g` (match):** `...:10:11: non-exhaustive match of 'Color'. Missing case:
  'Blue'; add a 'Blue => …' arm, or a '_' wildcard arm...` ✓
- **`f` (multi-clause fn):** **silent.** ✗ (the bug)

### Why: the gate, and how the multi-clause path reaches it

Multi-clause top-level functions are **NOT** desugared to `EMatch`. Each clause
stays a separate `DFunDef Bool String (List Pat) Expr` (`ast.mdk:295`,
`desugar.mdk:139` — `mapDecl` preserves the shape). They never flow through
`typecheck`'s `checkMatchExhaustive` (`typecheck.mdk:5214`), so they only reach
the standalone engine in `exhaust.mdk`:

`checkGuardExhaustiveness` (`exhaust.mdk:650`) → `topFunDefClauses`
(groups same-named `DFunDef`s) → `groupByName` → **`checkGroup`**
(`exhaust.mdk:521`):

```
checkGroup oracle clauses
  | anyList clauseIsGuardedPartial clauses = checkGroupCovered oracle clauses
  | otherwise = []                          -- <-- THE GATE (line 524)
```

The gate confines the coverage check to groups that contain a **guarded**
partial clause. A plain `f Red = … / f Green = …` group has no guards →
`clauseIsGuardedPartial` is false for every clause → `otherwise = []` → skipped.
The check machinery (`checkGroupCovered`, `exhaust.mdk:526`) is already correct
and general — it builds an all-wildcard query and asks `useful`. **It is only
gated off.** So yes, the surface fix is ~1 line. It is just the wrong stopping
point.

### Confirmed with the throwaway gate removal

Replacing lines 521–524 with `checkGroup oracle clauses = checkGroupCovered
oracle clauses` and rebuilding, `f` now warns — but as
`<unknown location>: guards may not be exhaustive` (the flat `guardWarning`,
`exhaust.mdk:518`): **no location, no witness** — strictly worse than the match
message.

---

## 2. Blast radius — measured

Method: built the native raw-AST oracle `test/bin/exhaust_main`
(`sh test/build_oracles.sh`) from the **gate-removed** source. This is the same
basis as the `diff_compiler_exhaust.sh` golden (`Exhaust.check_guard_
exhaustiveness` on the raw pre-desugar AST) and is milliseconds/file. Counted
`"guards may not be exhaustive"` lines per file.

> Note on method: per-file `medaka check` is unusable here — single-file mode
> reports every cross-module import as `UnknownModule` and short-circuits before
> exhaust; multi-module `medaka check --allow-internal` runs a full compiler
> typecheck per file (~3 min/file, ~6 h for 116 files). `exhaust_main` isolates
> the pass and matches the golden capture.

### 2a. Totals (gate removed, entry-only oracle — as filed)

| tree     | new warnings |
|----------|--------------|
| stdlib   | **11**       |
| compiler | **781**      |
| sqlite   | **34**       |
| **total**| **826**      |

The filed "~524 (34 stdlib + 490 compiler)" is an **undercount** and mislabels
stdlib (measured 11, not 34). "Gap docs lie" — confirmed.

Heaviest compiler files: `typecheck.mdk` 132, `wasm_emit.mdk` 98, `lint.mdk`
84, `llvm_emit.mdk` 49, `printer.mdk` 47, `resolve.mdk` 46,
`core_ir_lower.mdk` 40, `eval.mdk` 35, `sexp.mdk` 30, `desugar.mdk` 28,
`exhaust.mdk` 27, `marker.mdk` 25.

### 2b. Categorized sample — the warnings are dominated by FALSE POSITIVES

Root mechanism (`exhaust.mdk:298-317`): for an all-wildcard query,
`usefulWild` infers the column type from the matrix head ctor, then
`bindCtors → oGetCtors`. If the ADT is **not** in the entry-only oracle,
`oGetCtors` returns `None` → `usefulWildCtors None` → `useful (defaultMatrix)`;
`defaultMatrix` drops all constructor rows, leaving `[]` → `useful [] = True` →
**always flagged.**

Controlled proof:
- `h (Ok x) = x / h (Err e) = e : Result Int Int -> Int` (exhaustive) — **flagged**
  (Result imported/unknown). Written as `match`, **silent** (full oracle).
- The same shape over an ADT **defined in the same file** — **silent**.

Adding the imported ADTs to the oracle (concatenating the type-defining modules,
`parseErr=0`, prefix-alone warnings=0) collapses the counts:

| file                | entry-only | with real ADTs in oracle |
|---------------------|-----------:|-------------------------:|
| `typecheck.mdk`     | 132        | **1**                    |
| `lint.mdk`          | 84         | **0**                    |
| `eval.mdk`          | 35         | **3**                    |
| `wasm_emit.mdk`     | 98         | **5** (core+ast+core_ir) |
| `marker.mdk`        | 25         | **2** (ast only)         |

Worked example (`marker.mdk`): `ifaceMethodName (IfaceMethod n _ _)`,
`implMethodNameOf`, `implMethodBody`, `funClauseBody (FunClause _ body)`,
`letBindBodies (LetBind …)` are **single-constructor destructures** — fully
exhaustive — flagged only because `IfaceMethod`/`FunClause`/`LetBind` are
imported. These are neither bugs nor intentional partials; they are **spurious**.

**Categorization of the 826 (representative):**
- **~90%+ false positives** — exhaustive functions over imported ADTs
  (single-ctor destructures, and full-coverage matches over `Expr`/`Decl`/…).
- **A small residual of genuine partials** — e.g. `constrainedAdd
  (TyConstrained _ _)`-style helpers relying on a caller invariant; pretty-
  printer sub-cases in `printer.mdk` that truly handle a subset. Order a few
  dozen tree-wide once the oracle is fixed (exact count TBD post-fix — see §3).
- **Latent bugs** — expected to be rare; none confirmed in the sample. The
  witness message (§3) is what turns a genuine residual into an actionable
  triage item.

**Implication:** "cleanup of ~524 intentional partials" is the wrong task. Most
of the 826 must be made to *not fire* by fixing the oracle; only the small
genuine residual is cleaned/annotated.

---

## 3. The responsible fix

Three independent pieces. (A) is mandatory and is the real content; (B)/(C)
bring the multi-clause warning up to `match` quality.

### (A) Full-program oracle for the multi-clause path — MANDATORY

`buildOracle` (`exhaust.mdk:116`) only reads `DData`/`DRecord` — feeding it a
**superset** of decls is always safe (it adds ctor knowledge, never changes the
check of the entry module's function groups). Today the callers feed it only the
entry module:
- `driver/diagnostics.mdk:296` `checkGuardExhaustiveness raw` (raw = target
  only), warning loc hard-coded `None` at `:308`.
- `tools/check.mdk:84` `exhaustToLines raw`; multi-module `entryExhaust`
  (`check.mdk:162-165`) runs `exhaustToLines prog` on the **entry module only**,
  even though all loaded `mods` are in hand.

Fix: thread the **union of all loaded module decls (+ runtime + core)** as the
ORACLE source, while still only *checking* the entry/target module's groups.
Concretely, split `checkGuardExhaustiveness`/`exhaustToLines` into
"decls-to-check" and "decls-for-oracle", or pass a pre-built `Oracle`. Update
the four call sites (`diagnostics.mdk:296,611`, `check.mdk:84,164`,
`check_batch.mdk:49`). This alone removes ~90%+ of the 826.

`usefulWildCtors None` (`exhaust.mdk:308`) should stay conservative
(no warning when the type is *still* unknown after the union) so a genuinely
un-resolvable scrutinee never false-fires.

### (B) Witness message (mirror the match message)

`exhaust.mdk` **already exports** `usefulWitness` (`:376`) and `renderWitness`
(`:438`) — the exact functions `typecheck.mdk`'s `nonExhaustiveMsg`
(`:5267`) uses. Replace `checkGroupCovered`'s flat `[guardWarning]` with a
witness-bearing message of the same shape:

`Warning: non-exhaustive clauses of '<fn>'. Missing case: '<witness>'; add a
'<witness>' clause, or a '_' catch-all clause.`

(and record the help string in a side channel like `matchWarningHelp`
(`typecheck.mdk:5273`) so `--json`'s `help` field carries it). The witness is a
tuple across the clause arity; render per-column.

### (C) Per-clause source location

`DFunDef` carries **no** `Loc` (`ast.mdk:295`), but the clause **body** is an
`ELoc`-wrapped expr (the parser wraps atoms/leaves, `parser.mdk:167-173`;
`desugar` preserves `ELoc`). So `exprLoc firstClauseBody` (helper exists at
`desugar.mdk:279` / `typecheck.mdk:4595`) yields a usable per-group loc — like
`match` warnings, which use `currentLoc`/`exprLoc body`
(`typecheck.mdk:5219,5245`). Change `checkGuardExhaustiveness` to return
`List (String, Option Loc)` (or add a parallel loc channel), and replace the
hard-coded `None` at `diagnostics.mdk:308` with the threaded loc. This also
enables the existing ESLint-style `-- lint-disable-*` suppression to target the
right line (see §3-cleanup option b).

### Cleanup strategy for the genuine residual — RECOMMENDATION

Options considered:
- **(a) explicit `_ => panic/error` catch-alls** — verbose, changes runtime
  behavior (turns a compiler-internal fallthrough trap into a bespoke panic),
  churns hundreds of sites. Reject as the default.
- **(b) inline `-- lint-disable`-style suppression / pragma** — the machinery
  already exists (`lint.mdk:559-652`, `lint-disable-next-line|line|file`) but is
  wired only to the lint pass. Extend it to exhaustiveness warnings (needs (C)'s
  locs). Good for the *few* true intentional partials.
- **(c) only warn when the scrutinee ADT's ctor set is fully known & small** —
  with the **entry-only** oracle this suppresses nearly everything (compiler
  ADTs are always imported) and guts the feature. With the **(A) full oracle**
  it becomes a clean *policy knob* (e.g. suppress `Int`/`String`/`Char` and
  types with a wildcard-only column), useful to trim residual noise.

**Recommended:** **(A) + (B) + (C) always; then (c) as a policy knob on top of
the full oracle; (b) for the small hand-annotated residual.** Do NOT pursue (a)
en masse. After (A), the residual is small enough that cleanup is *manual
triage*, not a mechanized tree-sweep — most "cleanup" simply disappears because
the warnings were never real. Estimated genuine-residual triage: **a few
engineer-hours**, not a tree-wide campaign; delegable to Sonnet per file once
the witness+loc make each finding self-describing.

---

## 4. Staging (each bite independently gated)

- **Bite 1 — engine (Opus).** (A) full-program oracle + (B) witness message +
  (C) per-clause loc, behind a **fresh fixture gate** (§6). Includes the seed
  re-mint (§5). This is the load-bearing, subtle bite (oracle threading through
  4 call sites; loc/return-type change ripples to diagnostics/json). Ship the
  `color_multi`-style fixtures GREEN and prove the tree-wide false-positive
  collapse (compiler 781 → tens) in the same bite.
- **Bite 2 — residual triage (Sonnet, per source root).** With witness+loc,
  walk the *remaining* genuine warnings per root (stdlib, sqlite, compiler/*)
  and either fix (real gap), add a catch-all where semantically right, or
  annotate `-- lint-disable-next-line` with a one-line justification. Small;
  parallelizable by directory; independently gated by a "tree stays clean"
  fixture.
- **(Optional) Bite 3 — policy knob (c) (Sonnet).** Only if Bite-1 residual is
  still noisy.

Model rec: **Bite 1 Opus** (oracle/return-type/loc threading + re-mint is
error-prone), **Bite 2+ Sonnet** (mechanical, self-describing findings).

---

## 5. Re-mint verdict — **YES, a seed re-mint is required**

`exhaust.mdk` **is in the self-compile graph**: imported by `types/typecheck.mdk`
(`:51`) and `driver/medaka_cli.mdk` — both compiled into the native `medaka`,
whose emitted IR the gzipped seed byte-mirrors. `test/bootstrap_from_seed.sh`
asserts **C3a: seed == native re-emission byte-for-byte** (`:8,19,49`); the
2026-06-29 note that `exhaust.mdk` `export`s were re-minted once corroborates
in-graph status.

Nuance to record: exhaustiveness output is a **diagnostic**; it does **not**
change user-program codegen, and the *exported* oracle functions used by
typecheck (`buildOracle`, `useful`, `usefulWitness`, …) are untouched by the
gate/loc/message change. **But** the seed gate is byte-identity on the compiler's
*own* emitted IR, which includes `exhaust.mdk`'s compiled module — so **any**
source edit there drifts the seed. Bite 1 must run `sh test/refresh_seed.sh`
(`Makefile: make seed`) and land the re-minted seed. Flag clearly in the PR.

---

## 6. Gates

- **New warning fires correctly:** add a multi-clause fixture to
  `test/exhaust_fixtures/` (all current fixtures are guard-based; none exercise
  constructor coverage of a multi-clause *function*), e.g.
  `multiclause_gap_color.mdk` = the §1 `f Red/f Green` over `data Color`, plus
  an **imported-ADT exhaustive** negative control to lock in the (A) fix
  (must stay silent). Validated by `sh test/diff_compiler_exhaust.sh`
  (native `exhaust_main` vs `.expected`). Mirror the message shape already in
  `test/check_match_fixtures/color_partial.expected`.
- **Tree stays clean after triage:** a gate that runs the full-oracle exhaust
  pass over each source root and asserts the residual set equals a checked-in
  allow-list (the annotated intentional partials). Fits the existing
  `diff_compiler_check_modules_batch.sh` family. This is what keeps Bite 2 from
  regressing.
- **Re-mint gate:** `make bootstrap` (strict C3a) must pass after the seed
  refresh.

---

## 7. Design forks — NEED A HUMAN DECISION

1. **(THE BIG ONE) Fix the oracle, or narrow the warning?** Recommended:
   **fix the oracle (§3A)** so the multi-clause path matches the `match` path's
   accuracy, then use narrowing (§3c) only as a noise knob. The tempting
   "shrink 524 by only warning on small known ADTs" is, with today's entry-only
   oracle, indistinguishable from "disable the feature for the whole compiler."
   Decide: full-oracle fix (more code, correct) vs ship the narrow heuristic
   (cheap, but leaves multi-clause exhaustiveness blind to every imported ADT —
   i.e. essentially all real compiler code).
2. **Cleanup mechanism for the genuine residual:** `-- lint-disable`
   annotations (recommended) vs explicit `_ => panic` catch-alls vs a new
   `@partial`/`@total` pragma. Affects whether Bite 2 changes runtime behavior.
3. **Return-type change vs side-channel for locs:** change
   `checkGuardExhaustiveness : List Decl -> List (String, Option Loc)` (clean,
   but ripples to every caller + json) vs a parallel `Ref` loc channel like
   `matchWarningLocs` (localized, but stateful). Affects Bite-1 surface area.
4. **Message wording/parity:** reuse the exact `match` witness string
   ("non-exhaustive match…") for functions, or a function-specific phrasing
   ("non-exhaustive clauses of 'f'…"). Affects `MESSAGE-AUDIT.md` / diagnostic
   codes (`W-GUARD-INEXHAUSTIVE` vs a new `W-NONEXHAUSTIVE-CLAUSES`).

---

## Appendix — measured warning-bearing files (gate removed, entry-only oracle)

stdlib (11): list 4, array 1, base64 1, json 1, option 1, result 1, string 1,
validation 1.

sqlite (34): test/rowtype_doctest 6, lib/select 5, and 2×(aggregate_demo,
inmem_aggregate_probe, left_join_demo, lib/aggregate, lib/btree, lib/dbwriter,
lib/mutate, lib/recordenc) + 1×(9 more).

compiler (781): typecheck 132, wasm_emit 98, lint 84, llvm_emit 49, printer 47,
resolve 46, core_ir_lower 40, eval 35, sexp 30, desugar 28, exhaust 27,
marker 25, private_mangle 20, core_ir_eval 17, annotate 16, … (long tail).
