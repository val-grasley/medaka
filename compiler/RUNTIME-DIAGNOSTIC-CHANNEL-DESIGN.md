# RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN

**Status:** IMPLEMENTED — `8f446ff6` (located, coded runtime error text) +
`37e7ab0d` (`medaka run --json`), 2026-07-04+. The `runtimePanic` helper is pervasive
through `compiler/eval/eval.mdk` (`runtimePanic "E-DIV-ZERO" "division by zero"` at
line 1387, plus `E-NONEXHAUSTIVE-MATCH`/`E-INDEX-OOB`/`E-STACK-OVERFLOW`/
`E-NOT-A-FUNCTION`/`E-SLICE-OOB`/`E-LET-REFUTE`), matching this doc's proposal exactly.
The original header below ("proposed, decision-ready... no source changed") predates the
fix — cross-backend consistency is the natural sequel, tracked in
`compiler/RUNTIME-TRAP-UNIFY-DESIGN.md` (still OPEN).

**Status:** proposed, decision-ready. Read-only design pass — no source changed.
**Owning goal:** error-message quality (`compiler/ERROR-QUALITY.md`,
`test/error_quality_fixtures/`). The whole compile-time "F-arc" is done (corpus
11.15/14). This doc scopes the single biggest remaining reservoir: **`medaka run`
(tree-walking interpreter) runtime diagnostics**, which today are naked strings
with no location, no code, no JSON.

**Base:** verified against `HEAD` (ancestor of `ef802d69`). Every claim below was
re-checked on the current tree; where the task framing was imprecise I say so.

---

## 1. Problem + current state

Six fixtures in `test/error_quality_fixtures/eval/` sit at **L=0** (Located) and
**A=0** (Agent-parseable) — the rubric caps a raw panic at `L=0, C=0`
(`ERROR-QUALITY.md:139`). Every one emits a bare line on stderr and `exit 1`:

| Fixture | `.mdk` trigger | Emitted today (`.out`) | eval.mdk panic site |
|---------|----------------|------------------------|---------------------|
| `division_by_zero` | `10 / n`, `n=0` | `division by zero` | `evalArith` `:1356` |
| `modulo_by_zero` | `17 % d`, `d=0` | `modulo by zero` | `evalArith` `:1359` |
| `list_index_oob` | `[1,2,3].[10]` | `index 10 out of bounds` | `listNthAt` `:157` (list) / `evalIndexInt` `:1072`,`:1082` (array/string) |
| `explicit_panic` | `panic "user not found"` | `user not found` | `pPanic` extern `:1627` |
| `let_else_fail` | `let (y::_) = xs else panic "empty list"` | `empty list` | `pPanic` extern `:1627` (the `else` runs the **user's** `panic`, *not* a let-refute path — see note) |
| `runtime_nonexhaustive` | `match 7 { 0=>… 1=>… }` | `non-exhaustive match` | `evalMatch` `:1277` |

**Quality gap vs the rest of the corpus.** A `check`-path diagnostic meets the
bar: `medaka check` prints `file:L:C: <message>` with a caret, and
`medaka check --json` emits `{code, kind, range, severity, message, help?, fix?}`
(`DIAGNOSTIC-CODES-DESIGN.md`). Runtime errors have **none** of this: no
`file:L:C:`, no caret, no stable code, no JSON, no `help`. Per the rubric the six
are stuck at the floor on **L** and **A**; the workstream target is "no fixture
below 8/14, every fixture 2 on A" (`ERROR-QUALITY.md:143`).

**Note — `let_else_fail` is a user-panic, not a let-refute.** The framing lists
it as "let-else fail", but on the current tree the `else panic "empty list"`
clause evaluates the **user's** `panic` extern (`pPanic`, `:1627`), identical in
mechanism to `explicit_panic`. The *implicit* refutable-let failure ("let pattern
match failure", `:1202`/`:1215`/`:1233`) is a **separate, un-fixtured** mechanism
that fires on a refutable `let` with **no** `else`. Both are in scope (§2), but
they are distinct codes.

**Why the location is gone.** Verified at `eval.mdk:1027-1030`:

```
-- ELoc is transparent at eval (mirror of lib/eval.ml's ELoc arm — it sets
-- current_loc there; the self-hosted eval surfaces errors via panic, so we just
-- recurse into the wrapped expr).
eval env (ELoc _ e) = eval env e
```

The OCaml reference set `current_loc` at this node; the self-hosted eval never
ported it. **There is no location-threading infra in eval today** — this is a
build-from-scratch mechanism. `Loc = Loc String Int Int Int Int` (file,
1-based start line, 0-based start col, 1-based end line, 0-based end col;
`ast.mdk:26`).

**How a panic reaches the process.** All runtime errors call the Medaka `panic`
extern (`stdlib/runtime.mdk:57` `extern panic : String -> a`). When `eval.mdk` is
compiled into the `medaka` binary, that extern lowers to the C
`mdk_panic` (`runtime/medaka_rt.c:324`):

```c
noreturn void mdk_panic(long long w) { mdk_fwrite_str(w, stderr, 1); exit(1); }
```

It writes the string to **stderr** and `exit(1)` — a hard C abort. **There is no
Medaka-level interception point after `panic`: it never returns** (`-> a`,
`noreturn`), so any "stash then read at the driver top level" scheme is
impossible — the driver never regains control. This is the single most important
constraint on the mechanism (drives Fork B). Note that `evalModulesOutput`
returns captured stdout (`outputRef.value`) only *after* `runMainForEffect`
completes; a mid-eval panic aborts before that, so partial stdout is already
discarded today — matching the fixtures (no stdout, only the stderr line). That
behaviour is unchanged by this design.

**Run driver path (verified).** `medaka_cli.mdk:133` `"run"::rest => runRunCmd`
→ `:625` `putStr (runProgramOutput …)` → `:647-650` `runProgramOutput` →
`evalModulesOutput` / `evalModulesOutputAsync` (`eval.mdk:2365`/`:2379`) →
`runMainForEffect` forces `main`, whose deep eval hits a `panic`.

**Verified de-risker — no seed re-mint.** The emitter is
`compiler/backend/llvm_emit.mdk`; `eval.mdk` is **not** in the emitter's own
compile graph. Changing eval-*logic* (adding a Ref, reclassifying panic sites)
does not change the IR the emitter *emits* for any program, so
`selfcompile_fixpoint` (C3a/C3b) stays byte-identical against the committed
`compiler/seed/emitter.ll.gz`. **Re-mint answer: NONE.** (Caveat: this holds
because we touch only eval.mdk and CLI wiring. If any change reached
`llvm_emit.mdk` or altered emitted IR — it must not — a re-mint would be forced.)

---

## 2. Panic classification

**Criterion.** *User-facing* = reachable on a **well-typed** program (the error is
value-dependent: a zero divisor, an out-of-range index, an unmatched scrutinee).
*Internal invariant* = reachable **only if typecheck is buggy or bypassed** (a
type-shape mismatch the checker already rules out). Internal panics stay bare —
they signal a **compiler bug**, and dressing them as user diagnostics would
mislead. This criterion is crisp and defensible: "not an Int" / "not a String" /
"non-array" / "if condition is not a Bool" are all *unreachable* on well-typed
input.

### 2a. User-facing runtime errors — get located message + code

| eval.mdk site | Trigger | Category | Proposed code | Proposed located message |
|---------------|---------|----------|---------------|--------------------------|
| `:1356` `evalArith` | `n / 0` | division by zero | `E-DIV-ZERO` | `file:L:C: division by zero` |
| `:1359` `evalArith` | `n % 0` | modulo by zero | `E-MOD-ZERO` | `file:L:C: modulo by zero` |
| `:157` `listNthAt` | `list.[i]` OOB | list index OOB | `E-INDEX-OOB` | `file:L:C: index 10 out of bounds (length 3)` |
| `:1072`,`:1082` `evalIndexInt` | `array.[i]` / `string.[i]` OOB | array/string index OOB | `E-INDEX-OOB` | `file:L:C: index 10 out of bounds (length N)` |
| `:1101` `evalSliceInt` | `xs[lo..hi]` OOB | slice OOB | `E-SLICE-OOB` | `file:L:C: slice [lo..hi] out of bounds (length N)` |
| `:1627` `pPanic` extern | user `panic "msg"` (covers `explicit_panic` **and** `let_else_fail`) | explicit user panic | `E-PANIC` | `file:L:C: panic: user not found` |
| `:1277` `evalMatch` | no arm matches scrutinee | non-exhaustive `match` at runtime | `E-NONEXHAUSTIVE-MATCH` | `file:L:C: no match arm for this value` |
| `:1202`,`:1215`,`:1233` `blockLet*`/`evalLet` | refutable `let` pattern fails, no `else` | let-pattern refutation | `E-LET-REFUTE` | `file:L:C: let pattern did not match this value` |
| `:695` `applyOpt` | applying a non-function value | applied non-function | `E-NOT-A-FUNCTION` | `file:L:C: this value is not a function` (see caveat) |
| `:1127` `evalRecordUpdate` | `{ r \| f = … }` with unknown field `f` | missing record field at update | `E-MISSING-FIELD` | `file:L:C: record has no field 'f'` |

Caveats worth a human eye:
- `E-NOT-A-FUNCTION` (`:695`) and `E-MISSING-FIELD` (`:1127`) are **borderline** —
  well-typed programs shouldn't reach them (typecheck rejects applying a non-fn
  and unknown fields). Include them (defensive, cheap, and they *can* surface in
  the untyped eval fallback paths), but they are lower priority than the six
  fixtured mechanisms and can be a later stage.
- The length/bound suffixes in the messages (`(length 3)`, `[lo..hi]`) are an F
  (actionable) upgrade beyond today's text; they require the length/bounds to be
  in scope at the panic site — they already are at `:157`/`:1072`/`:1101`.

### 2b. Internal invariants — LEAVE as bare `panic` (compiler-bug asserts)

These are unreachable on well-typed input; a bare panic is the correct "this is a
compiler bug" signal. Do **not** dress them as user diagnostics.

| Sites | Why internal |
|-------|--------------|
| `:390` unbound identifier · `:493` `findCell: missing` · `:471`/`:477`/`:481` `EVarAt` frame/slot · `:934` no matching impl · `:910`/`:921` closure w/ no params | resolve/typecheck/marker guarantee these can't happen |
| `:1067`,`:1076` index "not an Int" / "non-array" · `:1087`,`:1096` slice type · `:1108` range bound · `:1299` if-cond not Bool · `:1304`–`:1372` unop/binop type mismatches · `:1343` cons rhs · `:1349` `++` semigroup | pure **type errors** typecheck already rules out |
| `:1032` `eval: unsupported node` · `:1198` unsupported block stmt · `:1146`/`:1148`/`:1153` variant-update invariants · `:1170`/`:1171`/`:1175` field-on-non-record · `:1180` unknown field access | AST-shape invariants |
| `:686` `apply` `None => "non-exhaustive match"` | **dead** — `applyOpt` never returns `None` (its last arm `:695` panics); leave bare |
| `:1610`+ all `prim*` "not a String/Int/…" extern guards | typecheck guarantees the argument types |
| `:2144`/`:2178`/`:2388` "no 'main' binding" · `:2392` "requires runAsync" | driver-level; caught earlier by resolve/`check`. Optional polish, not this reservoir |

---

## 3. Mechanism design

Two independent pieces:

1. **Location capture (Fork A).** Restore `current_loc` by having the `ELoc` arm
   write the loc into a mutable `Ref Loc` before recursing — the exact shape the
   OCaml reference used. One-line change at `eval.mdk:1030`.
2. **Located surface (Fork B).** A `runtimePanic code msg` helper reads the loc
   Ref (+ a filename Ref + a `--json` mode Ref), formats a located diagnostic
   (text or JSON), and passes the *formatted string* to the bare `panic` — which
   writes it and aborts. Because `panic` can't be caught, the formatting **must
   happen before** the abort; the helper is the chokepoint that does it.

Both the loc file-name and the JSON mode need side channels because (a) the parser
leaves `Loc`'s file field `""` (`parser.mdk:164`; downstream diagnostics already
substitute a `fallbackFile`, e.g. `resolve.mdk:1930`), and (b) `panic` never
returns so the mode can't be a return value. Introduce module-level Refs in
`eval.mdk`, mirroring the existing `outputRef`/`currentLoc` pattern:

```
currentEvalLoc : Ref Loc      -- updated at every ELoc node
currentEvalFile : Ref String  -- set once by the run driver to the target path
runJsonMode : Ref Bool        -- set by the CLI run arm when --json is present
```

Located text format mirrors `ppResErrorLocatedF` exactly for consistency:
`"\{file}:\{sl}:\{sc}: <message>"` (0-based col, as the rest of the corpus prints).
JSON mirrors the `check --json` `Diag` contract:
`{code, kind:"error", range:{start:{line,character},end:…}, severity:1, message, help?}`
where `range` maps `Loc` (1-based line, 0-based col) → LSP 0-based line by `sl-1`.

**Filename precision (sub-decision).** `currentEvalFile` is set to the run
target. For a single-file `medaka run foo.mdk` (all six fixtures, the dominant
case) this is exactly right. For a **multi-module** program a runtime error in an
imported module would print the root target's name (line/col are still correct).
Precise per-module filenames would require stamping `Loc.file` during load — more
invasive, deferred. Stage 1 accepts the single-file-correct approximation.

---

## 4. Design forks — need a human decision

### Fork A — location threading: **mutable `Ref Loc`** ✅ (recommend)
- **(A1) `Ref Loc` updated at `ELoc`** — `eval env (ELoc loc e) = let _ = setRef currentEvalLoc loc in eval env e`. Blast radius: **1 line** + 1 Ref decl. Matches the OCaml reference exactly. "Global-ish ref" is already the house style (`outputRef`, `currentLoc` in typecheck). The interpreter is single-threaded and already `<Mut>`, so no re-entrancy hazard.
- **(A2) functional loc-parameter threading** — add a `Loc` param to `eval` and *every* helper it tail-calls (`apply`, `evalMatch`, `evalArith`, `evalBlock`, `applyClosure`, …). Pure, but blast radius is **dozens of signatures across eval.mdk** and a real risk of perturbing behaviour.
- **Recommendation: A1.** The Ref matches the reference, is one line, and the purity win of A2 is not worth the blast radius in a deterministic single-threaded oracle.

### Fork B — error surface: **format the located diagnostic INTO the panic message** ✅ (recommend option iii, generalized)
- **(i) Ref stash + read at driver top level** — *impossible*: `panic` is `noreturn`/C-abort, the driver never regains control. Reject.
- **(ii) new structured runtime-error extern** — a `mdk_runtime_error(loc, code, msg)` in C. More C surface, and still has to format there; buys nothing over (iii). Reject for now.
- **(iii) format located string into the panic message** — a `runtimePanic code msg` helper reads the Refs, builds the located text **or** JSON, and calls the existing `panic` with that string. Simplest, least C surface, and — crucially — the same chokepoint yields **both** text and JSON by branching on `runJsonMode`. So (iii) is *not* text-only; it gives A=2 too. Blast radius: 1 helper + ~9 user-facing call-site edits + the `pPanic` extern (for `E-PANIC`). **Recommend.**
- **Recommendation: iii.** It's the only viable path given the C-abort constraint, and it delivers JSON.

### Fork C — `medaka run --json`: **stage text first, then JSON, same chokepoint** ✅
- The **A dimension strictly requires JSON**: A=0 is "No JSON…", A=2 is "JSON with stable `code`, `kind`, span, and machine `fix`" (`ERROR-QUALITY.md:132`). A stable `file:L:C: [CODE]:` text prefix moves **L** to 2 and improves F, but leaves **A at 0**. To hit the workstream target (every fixture 2 on A) we must emit JSON.
- **Recommendation:** Stage 1 ships located CLI text (`L→2`), Stage 2 adds `medaka run --json` through the same `runtimePanic` chokepoint (`A→2`). Note: runtime errors have no `fix{range,replacement}` (there's no mechanical source edit for a zero divisor), so A caps at the "code/kind/span, no fix" rung — that is **A=2** by the rubric wording for errors without a mechanical fix (the `fix` is described as "suggestion-bearing errors"; div-by-zero is not one). Human check: confirm the grader treats a fix-less runtime error at A=2 with code+kind+span (I read the rubric as yes).

### Fork D — native `build`+run path: **defer** ✅ (recommend defer)
- All six fixtures are `medaka run` (interpreter). The native-compiled path panics via `runtime/medaka_rt.c` `mdk_panic` with no location, but threading a `Loc` to those call sites means **carrying source positions into emitted LLVM IR** — which **changes emitted IR → forces a seed re-mint + fixpoint re-validation**, exactly the churn this reservoir avoids. It's also a much larger surface (per-primitive C ABI).
- **Recommendation: defer** — out of scope for this reservoir. Reason to lean defer: it's a different, higher-cost workstream (IR-format change + re-mint) with its own fixtures, and the six fixtures here are fully addressable in the interpreter alone.

### Fork E — runtime error-code family: **`E-*` prefix** ✅
`E-*` is **free** — verified no `E-*` code exists in `DIAGNOSTIC-CODES-DESIGN.md`
(prefixes in use: `L-` lex, `P-` parse, `R-` resolve, `T-` type, `W-` warning).
`E` for **E**val/runtime slots cleanly alongside them. Proposed family (add to
`DIAGNOSTIC-CODES-DESIGN.md` §2):

| Code | Meaning |
|------|---------|
| `E-DIV-ZERO` | integer division by zero |
| `E-MOD-ZERO` | integer modulo by zero |
| `E-INDEX-OOB` | list/array/string index out of bounds |
| `E-SLICE-OOB` | slice bounds out of range |
| `E-PANIC` | explicit user `panic` |
| `E-NONEXHAUSTIVE-MATCH` | `match` had no arm for the runtime value |
| `E-LET-REFUTE` | refutable `let` pattern failed (no `else`) |
| `E-NOT-A-FUNCTION` | applied a non-function value (borderline, later stage) |
| `E-MISSING-FIELD` | record update named a nonexistent field (borderline, later stage) |

`kind` for all = `"error"`, `severity` = 1 (mirrors the derived-kind rule at
`DIAGNOSTIC-CODES-DESIGN.md:149`).

---

## 5. Staged implementation plan (ascending risk)

Each stage is independently gatable. Only Stage 3 changes fixture goldens.

**Stage 0 — code taxonomy (docs only).** Add the `E-*` family (§4E) to
`DIAGNOSTIC-CODES-DESIGN.md` §2 and note the runtime channel in
`ERROR-QUALITY.md`. No behaviour change; no gate impact.

**Stage 1 — loc capture (Fork A1), no surface change yet.** Add
`currentEvalLoc : Ref Loc`, set it in the `ELoc` arm (`eval.mdk:1030`). Nothing
reads it yet → **zero output change**. Gates: `selfcompile_fixpoint` (C3a/C3b)
green, `diff_compiler_eval_run` + `diff_compiler_eval_modules` byte-identical.
Proves the Ref plumbing is inert on valid programs.

**Stage 2 — `runtimePanic` helper + Refs, wire the driver.** Add `runtimePanic`,
`currentEvalFile`, `runJsonMode`; set `currentEvalFile` from the run target in the
CLI run arm. Still **no** panic site rerouted → still zero output change. Same
gates as Stage 1.

**Stage 3 — reroute the user-facing panics to located CLI text (L→2).** Point the
§2a sites at `runtimePanic <code> <msg>` (text mode). **This changes the goldens**
for the six fixtures under `test/error_quality_fixtures/eval/*.out` (they gain a
`file:L:C:` prefix): `division_by_zero`, `modulo_by_zero`, `list_index_oob`,
`explicit_panic`, `let_else_fail`, `runtime_nonexhaustive` — recapture via
`CAPTURE=1`/`capture_goldens.sh`. **Regression proof that valid output is
untouched:** `selfcompile_fixpoint` (C3a/C3b) + `diff_compiler_eval_run` +
`diff_compiler_eval_modules` must stay byte-identical (these exercise
*valid* programs — no panic path). Also re-grade the six fixtures in
`test/error_quality_fixtures/GRADING.md` (expected L 0→2, F up, corpus up).

**Stage 4 — `medaka run --json` (A→2).** Add the `--json` flag to the run arm
(sets `runJsonMode`); `runtimePanic` branches to the `Diag`-shaped JSON. Extend
the eval error-quality fixtures with `--json` variants (new `.out`s). Gates: same
valid-program gates unchanged; new JSON goldens captured.

**Stage 5 (optional) — borderline sites.** `E-NOT-A-FUNCTION` (`:695`),
`E-MISSING-FIELD` (`:1127`), and the implicit `E-LET-REFUTE` sites if not already
covered. Same gate discipline.

**Oracle-stale caution.** Before trusting any eval gate that reads `test/bin/*`
oracles, `FORCE=1 bash test/build_oracles.sh` first (`diff_native_cli` and
bootstrap suites are stale-prone per AGENTS.md).

**Re-mint answer: NONE at every stage.** All edits live in `eval.mdk` +
`medaka_cli.mdk` + docs + goldens. None reach `llvm_emit.mdk` or change emitted
IR, so `compiler/seed/emitter.ll.gz` and the fixpoint are unaffected.

---

## 6. Risks / non-goals

- **Valid-program output must stay byte-identical.** The interpreter is the
  deterministic oracle behind `diff_compiler_eval_*`. Stages 1–2 are provably
  inert (nothing reads the new Refs); Stage 3+ only touches the *panic* path,
  never a successful eval. The three valid-program gates
  (`selfcompile_fixpoint`, `diff_compiler_eval_run`, `diff_compiler_eval_modules`)
  are the guardrail — they must be green at **every** stage.
- **Deterministic-oracle property preserved.** No wall-clock, no address-dependent
  output enters a diagnostic (loc + code + static message only). `ppValue` in the
  `E-PANIC`/`E-NOT-A-FUNCTION` messages is already deterministic.
- **Non-goal: catchable runtime errors.** Medaka deliberately has no
  recover/try/catch (process isolation; AGENTS.md). `runtimePanic` still aborts —
  it only *formats better* before aborting. No control-flow change.
- **Non-goal: native `build` path** (Fork D) — deferred; it would change emitted
  IR and force a re-mint.
- **Non-goal: internal-invariant panics** (§2b) — they must stay bare as
  compiler-bug asserts; dressing them as user diagnostics would misdirect.
- **Watch:** multi-module filename precision is approximate in Stage 1 (root
  target name; line/col correct). Acceptable for the fixtured single-file cases;
  flagged for a future load-time `Loc.file` stamp if it matters.

---

## 7. AS-BUILT (Stages 1–3 + 5, located TEXT surface — 2026-07-04)

Shipped the located, coded runtime-error text for `medaka run`. JSON (Stage 4)
remains for a later agent.

**Message format (final):** `file:L:C: runtime error [E-*]: <message>` — the
`file:L:C:` prefix mirrors `resolve.mdk`'s `ppResErrorLocatedF` (0-based column),
plus a bracketed `E-*` code and the original bare message. Example:
`test/error_quality_fixtures/eval/division_by_zero.mdk:3:23: runtime error [E-DIV-ZERO]: division by zero`
(3:23 points at the divisor `n` in `10 / n`).

**Mechanism, as built:**
- `currentEvalLoc : Ref Loc` + `currentEvalFile : Ref String` in `eval.mdk`.
- `runtimePanic code msg` chokepoint reads the refs, formats the located text,
  hands it to the bare `panic`. Sites rerouted: `E-DIV-ZERO`, `E-MOD-ZERO`,
  `E-INDEX-OOB` (list `listNthAt` + array/string `evalIndexInt`/`stringIndexCp`),
  `E-SLICE-OOB` (`sliceArray`), `E-PANIC` (`pPanic` — covers `explicit_panic` AND
  `let_else_fail`), `E-NONEXHAUSTIVE-MATCH` (`evalMatch`), `E-LET-REFUTE` (all
  three `blockLet*`/`evalLet` sites), `E-NOT-A-FUNCTION` (`applyOpt`). Internal
  invariants (§2b) + the dead `apply`-`None` arm left bare.

**Two corrections found while building (the design under-specified these):**
1. **Loc threading needed the ELoc arm to FILTER a placeholder.** The `ELoc`
   arm updates the ref, but the run driver's prelude (runtime.mdk/core.mdk) is
   parsed with the non-located `parse`, which collapses *every* span to the
   zero-width `Loc "" 1 0 1 0`. Because a runtime error is often reached *through*
   a prelude helper (a literal pattern's `Eq`, list-index dispatch), that
   placeholder would clobber the real user span (symptom: `index`/`match` reported
   `1:0`). Fix: `updateEvalLoc` ignores the zero-width-at-origin sentinel (a real
   located atom always has positive width), so the last *real* user span survives.
2. **The run driver had to parse the user module LOCATED.** Plain `medaka run`
   used placeholder-loc `parse` for the target too → every span `1:0`. Routed the
   run path through the existing `loadProgramFilesLocated` (the LSP's located
   loader) so the root module carries real ELoc spans. Eval output is
   byte-identical (ELoc is transparent), so `diff_compiler_eval_{run,modules}`
   stay green.

**E-MISSING-FIELD has no live emit site on the current tree.** §2a named
`evalRecordUpdate` (`:1127`), but `mergeField` *silently ignores* an unknown
update field (no panic). The only field panics are `fieldOr`'s "unknown field"
and `evalValueField` — both classified **internal** in §2b. So `E-MISSING-FIELD`
is reserved in the taxonomy but wired to nothing (forcing it onto the
internal-classified field-access site would violate §2b). No fixture covers it.

**Gates:** `diff_compiler_eval_run` (50 ok), `diff_compiler_eval_modules` (4 ok),
`selfcompile_fixpoint` (C3a YES / C3b YES — no re-mint), full `run_gates` (72
passed / 0 failed / 1 skip). `diff_compiler_eval_errors` goldens were updated
(its `eval_main` probe sets no filename, so it honestly prints `:0:0:` — the
located CLI path is validated by the 6 `error_quality_fixtures/eval` goldens
instead).

## 8. AS-BUILT — Stage 4, `medaka run --json` (A→2, 2026-07-04)

Shipped `medaka run --json`. `runtimePanic` (`compiler/eval/eval.mdk`) now
branches on a new `runJsonMode : Ref Bool` (default `False`, so every other
path — including all valid-program eval gates — is untouched):

- **Text mode** (default): unchanged `file:L:C: runtime error [E-*]: <message>`.
- **JSON mode** (`--json`): builds `Diag SevError code msg (Some (Loc ff sl sc
  el ec)) None None` (full loc, not collapsed to zero-width) and serializes it
  through `cjAllToJson [(ff, "", [diag])]` — the **exact same function**
  `medaka check --json` uses — then hands the resulting JSON string to the bare
  `panic` (which still writes it to **stderr**, same channel as text mode; exit
  code stays 1). `cjRangeOfLoc` ignores its `src` argument, so passing `""`
  needs no source-text threading.

**Import reused cleanly, no cycle.** `eval.mdk` now `import driver.diagnostics.
{Diag(..), Severity(..), cjAllToJson}`. Verified before adding: nothing upstream
of eval (frontend/, types/, driver/loader.mdk, driver/diagnostics.mdk itself)
imports `eval.eval` — only `tools/`, `entries/`, and `ir/core_ir_{lower,eval}.mdk`
do, all of which are downstream consumers, same or later than eval in the
pipeline. So no split/inline fallback was needed — `cjDiagnostic`/`cjRangeOfLoc`/
`cjAllToJson` are reused as-is.

**Envelope shape verified against `check --json` by eye** (not just by
construction): the object is `{"files":[{"file":...,"diagnostics":[{"code":...,
"kind":...,"message":...,"range":{"end":{...},"start":{...}},"severity":1,
"source":"medaka"}]}]}` — same top-level `"files"` wrapper, same per-diagnostic
key set/order, same 0-based LSP range shaping, `kind` derived from the `E-*`
code prefix via `codeKind` (falls through to `"error"`, the same as an
unrecognized prefix would — `E-*` isn't special-cased in `codeKind`, which is
fine: the rubric only requires a *derived*, not a *distinct*, kind). Example
(`division_by_zero`):
```json
{"files":[{"file":"test/error_quality_fixtures/eval/division_by_zero.mdk","diagnostics":[{"code":"E-DIV-ZERO","kind":"error","message":"division by zero","range":{"end":{"character":24,"line":2},"start":{"character":23,"line":2}},"severity":1,"source":"medaka"}]}]}
```

**CLI wiring** (`compiler/driver/medaka_cli.mdk`): `runRunCmd` now reads
`hasFlag "--json" argv` before `dropFlags` strips it (mirrors the `check` arm),
and `setRef runJsonMode jsonMode` right before the eval call (alongside the
existing `setRef currentEvalFile target`). Usage line updated to `medaka run
[--release] [--json] <file.mdk>`.

**New gate:** `test/diff_compiler_eval_json.sh` — drives the freshly-built
`./medaka run --json <fixture>` directly (the flag lives in the CLI layer, not
behind any `test/bin/*` probe oracle) over the same 6
`test/error_quality_fixtures/eval/*.mdk` fixtures, comparing stderr against a
new `<fixture>.json.out` golden per fixture (path-stripped, same convention as
`capture.sh`). `CAPTURE=1` (re)writes the goldens. All 6 captured and verified:
6 ok, 0 failing. Not yet wired into `run_gates.sh`'s matrix (kept standalone,
matching how `error_quality_fixtures/` itself is intentionally ungated) — a
future session can add it if the reservoir wants it in the ratchet.

**Regression gates (post-Stage-4, all fresh oracles via `FORCE=1 bash
test/build_oracles.sh`):** `diff_compiler_eval_run` 50 ok / 0 failing,
`diff_compiler_eval_modules` 4 ok / 0 failing, `diff_compiler_eval_errors` 9 ok
/ 0 failing (unchanged from Stage 3), `selfcompile_fixpoint` C3a YES / C3b YES
(no re-mint — eval.mdk/medaka_cli.mdk are outside the emitter graph), full
`run_gates.sh` 73 passed / 0 failed / 1 skipped (one `diff_compiler_
internal_extern` flake on the first parallel run reproduced the documented
temp-collision class in AGENTS.md — verified green standalone and on a clean
re-run of the full suite).
