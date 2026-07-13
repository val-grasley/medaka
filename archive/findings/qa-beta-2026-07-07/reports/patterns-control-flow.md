# Findings: patterns-control-flow

Binary: /Users/val/medaka/.claude/worktrees/virtual-fluttering-meteor/medaka ($WT/medaka).
Probes: scratchpad/probes/patcf/. All findings reproduced twice.

## F1: Any parse error inside a match/decl body reports "unexpected `<first-token-of-decl>`" at line 1 col 0
- Severity: high
- Class: error-ux
- Launch blocker: yes (playground users will hit this constantly)
- Repro (one of many — same failure shape for or-patterns, `-1` literal patterns, `match x {`, empty `match x`, spaced `ys @ (…)` as-pattern, match inside string interpolation, `let x = 1 in` with body on next line):
  ```
  f n = match n
    1 | 2 => "small"
    _ => "big"

  main = println (f 2)
  ```
  $ $WT/medaka check pat_or.mdk
  ```
  pat_or.mdk:1:0: unexpected `f`
    |
  1 | f n = match n
    | ^
  ```
  JSON: `{"code":"P-PARSE","message":"unexpected `f`","range":{...line 0 char 0...}}`
- Expected: error located at the offending token (line 2), naming what failed to parse (e.g. "`|` is not valid in a pattern; or-patterns are not supported"). Instead the parser rewinds to the start of the declaration and blames its first token, with zero help text.
- Hypothesis: parser backtracks out of the equation/match production and re-reports at the outermost failure point.

## F2: Negative integer literal patterns don't parse at all (even parenthesized) — but negative RANGE patterns do
- Severity: high
- Class: missing-feature (+ error-ux via F1)
- Launch blocker: yes
- Repro:
  ```
  f n = match n
    -1 => "neg one"
    0 => "zero"
    _ => "other"

  main = println (f (-1))
  ```
  $ $WT/medaka run pat_neg.mdk
  ```
  pat_neg.mdk:1:0: unexpected `f`
  ```
  `(-1) => …` fails identically. Yet `-5..0 => …` and even `-1..=-1 => …` parse and match correctly in both run and build.
- Expected: `-1` should be a valid literal pattern (every mainstream language allows it), or at minimum a targeted error. The inconsistency (negative range endpoints OK, negative literals not) makes it clearly a gap, not a design choice.

## F3: Or-patterns (`1 | 2 =>`) unsupported, with the F1-grade error
- Severity: medium
- Class: missing-feature
- Launch blocker: no
- Repro: see F1. Rust/OCaml/Python-match users will type this in the first 10 minutes; the "unexpected `f` at 1:0" response gives them nothing to go on.
- Expected: either support, or a targeted diagnostic like the excellent `case … of` one (see positives).

## F4: Positional pattern on a record constructor matches in native but FAILS at runtime in the interpreter — and it's the exhaustiveness checker's own suggested fix
- Severity: critical
- Class: run-build-divergence / soundness (typechecks + judged exhaustive, still fails)
- Launch blocker: yes
- Repro:
  ```
  data Person = Person { name: String, age: Int }

  f p = match p
    Person _ _ => 42

  main = println (f (Person { name = "Bo", age = 1 }))
  ```
  $ $WT/medaka check rec_positional2.mdk   → clean (f : Person -> Int), no warning
  $ $WT/medaka run rec_positional2.mdk
  ```
  rec_positional2.mdk:3:12: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
  ```
  $ $WT/medaka build rec_positional2.mdk -o rp2 && ./rp2  → `42`, exit 0
- Expected: interpreter matches like native does. Aggravating factor: `medaka check` on a non-exhaustive record match literally tells the user to `add a 'Person _ _ => …' arm` — following that advice produces code the interpreter can't run.
- Hypothesis: eval's ctor-pattern matcher doesn't handle positional sub-patterns against record-constructor values.

## F5: Deep recursion / `sum [1..=100000]` kills `medaka run` with a SILENT signal crash (exit 138, no output) — native is fine
- Severity: high
- Class: run-build-divergence / crash-ux
- Launch blocker: yes (this is THE first program a newcomer writes)
- Repro:
  ```
  main = println (sum [1..=100000])
  ```
  $ $WT/medaka run sumrange.mdk   → no output at all, exit 138 (SIGBUS)
  $ $WT/medaka build sumrange.mdk -o s && ./s → `5000050000`
  Thresholds measured: interpreter dies ~30k non-tail frames and ~100k TAIL frames (no TCO in the interpreter; native tail-recurses to 10M fine). Native dies the same silent way at 10M non-tail frames (exit 138, no message).
- Expected: a clean "stack overflow: recursion too deep at <fn>" runtime error in both engines; interpreter should TCO (or `sum` should be tail-recursive/strict in the interpreter). Silent process death with zero output is the worst possible newcomer UX.

## F6: Function-clause fall-through at runtime (interpreter) reports internal jargon: "no matching impl for dispatch"
- Severity: high
- Class: error-ux / run-build-divergence
- Launch blocker: no (but ugly)
- Repro:
  ```
  f 0 = "zero"
  f 1 = "one"

  main = println (f 5)
  ```
  $ $WT/medaka run clause_miss.mdk
  ```
  runtime error [E-PANIC]: no matching impl for dispatch
  ```
  (no file/line, no function name, typeclass-machinery wording; exit 1)
  Native for the same program: `runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match`.
  (`medaka check` DOES warn correctly beforehand: "non-exhaustive clauses of 'f'…" — good.)
- Expected: same E-NONEXHAUSTIVE-MATCH class in the interpreter, with location and ideally the function name and unmatched value.

## F7: Guarded function clauses that all fall through crash NATIVE with "index out of bounds"
- Severity: high
- Class: run-build-divergence / error-ux
- Launch blocker: yes (wrong error class sends users hunting a nonexistent indexing bug)
- Repro:
  ```
  classify n
    | n < 0 = "neg"
    | n > 0 = "pos"

  main = println (classify 0)
  ```
  $ $WT/medaka build guard_fall.mdk -o g && ./g
  ```
  runtime error [E-INDEX-OOB]: index out of bounds
  ```
  Interpreter (correct): `guard_fall.mdk:3:8: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match`.
  Note: guard fall-through on MATCH ARMS in native reports E-NONEXHAUSTIVE-MATCH correctly — only guarded function clauses miscategorize.
- Expected: E-NONEXHAUSTIVE-MATCH in native too.
- Hypothesis: the desugared guard if-chain's failure continuation compiles to an unchecked indexing op in the equation path.

## F8: `medaka run` executes a program that `check` and `build` REJECT with 3 type errors
- Severity: critical
- Class: soundness / run-build-divergence
- Launch blocker: yes
- Repro:
  ```
  f x = if x > 0 then x

  main = println (f 5)
  ```
  $ $WT/medaka check if_noelse_val.mdk → 3 errors (Type mismatch: Int literal vs Unit; No impl of Ord for Unit; 'if' branches have different types: Int vs Unit)
  $ $WT/medaka build if_noelse_val.mdk -o out → same 3 errors, exit 1
  $ $WT/medaka run if_noelse_val.mdk
  ```
  ()
  ```
  exit 0 — runs an ill-typed program and silently prints `()`.
  Contrast: other type errors (e.g. tuple arity mismatch) DO stop `run` with "error: type error in … Run `medaka check` for details". So run's type gate passes some error classes through.
- Expected: `run` refuses exactly what `check`/`build` refuse.
- Hypothesis: run's gate ignores some accumulated error kinds (constraint/branch-mismatch errors) and only aborts on others.

## F9: Warnings (non-exhaustive match, unreachable arm) are never surfaced by `run` or `build`
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  f b = match b
    True => 1

  main = println (f True)
  ```
  $ $WT/medaka run warn_ok.mdk → `1`, no warning printed
  $ $WT/medaka build warn_ok.mdk -o w → "built …", no warning
  `medaka check` shows W-NONEXHAUSTIVE. So the only users who see the warning are those who separately run `check`; everyone else's first signal is a runtime abort (or F5/F6/F7's worse variants).
- Expected: run/build print warnings to stderr (standard compiler behavior).

## F10: No unreachable/duplicate warning for FUNCTION clauses (match arms get one)
- Severity: medium
- Class: missing-feature
- Launch blocker: no
- Repro:
  ```
  f 0 = "a"
  f 0 = "b"
  f _ = "c"

  main = println (f 0)
  ```
  $ $WT/medaka check clause_dup.mdk → clean, no warning. Runs, prints "a"; clause 2 silently dead.
  Same duplicate as match arms (`True => …; True => …`) yields W-UNREACHABLE-ARM.
- Expected: the same unreachable analysis applied to clause stacks.

## F11: Native runtime match-failure errors carry no source location
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro: any native non-exhaustive abort, e.g. F4's build of ex_bool.mdk:
  ```
  runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
  ```
  Interpreter prints `file:line:col:` for the same failure.
- Expected: at least the function name, ideally file:line, in native runtime errors.

## F12: Mixed-arity clauses produce a raw unification error, not an arity message
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  f 0 = "zero"
  f x y = "two args"

  main = println (f 1)
  ```
  $ $WT/medaka check clause_arity.mdk
  ```
  clause_arity.mdk:2:8: Type mismatch: String vs a -> String
  ```
- Expected: "clauses of 'f' have different numbers of arguments (1 vs 2)". The current message is technically true and totally opaque to a newcomer.

## F13: Match block inside a list literal fails when followed by another element
- Severity: low
- Class: error-ux / doc-mismatch (blocks-in-brackets feature)
- Launch blocker: no
- Repro: `[match 1 ⏎ 1 => "one" ⏎ _ => "x", "two"]` → `unexpected `[`` (right line, unhelpful token). Single-element `[match … ]` works.
- Expected: either parse, or an error explaining a block expression must be the last element.

## F14: `length [1..=1000000]` in the interpreter did not complete within 2 minutes
- Severity: low
- Class: missing-feature (perf)
- Launch blocker: no
- Repro: `main = println (length [1..=1000000])`; `$WT/medaka run` — killed at 120s, no output. (Native not measured; may be list-construction cost rather than a hang. One data point only.)
- Expected: 1M-element range length should be near-instant.

## Positive surprises (worth regression fixtures)
- Non-exhaustive diagnostics are excellent: name the type AND the concrete missing case (`Missing case: 'Square _'`, nested `'Some None'`, tuple `'(True, False)'`), with a help string and stable codes (W-NONEXHAUSTIVE / W-UNREACHABLE-ARM / E-NONEXHAUSTIVE-MATCH).
- Guards correctly defeat exhaustiveness (`False if …` still warns Missing 'False'); guard-only matches warn.
- Unreachable match arms warned, including post-wildcard and duplicate-literal arms.
- `case x of` gets a bespoke hint: "Medaka has no 'case … of'. Use 'match e' with indented 'pattern => body' arms" — model error. `/=` → "Did you mean '!='?" likewise.
- Refutable guards (`| Some v <- find k, v != "" = v`) work on function clauses AND match arms, binder scopes into later qualifiers and the body (guard_binder_body.mdk).
- Duplicate binder in one pattern (`(x, x)`) rejected with a clear message; non-contiguous clauses rejected clearly; zero-pattern clause after patterned clauses rejected as duplicate binding.
- Work fine in both engines: float literal patterns (`1.5 =>`), char/int range patterns (incl. negative ranges), 4-deep nested ctor patterns, list patterns (`[]`/`[x]`/`x::y::_`), record patterns with pun/explicit/rest, as-patterns `ys@(x::_)` (no-space form), match on a function value via `_`, guard that panics (located E-PANIC), if-let, let-else, else-if chains, match as argument/single list element.

## Suggested regression fixtures
1. `rec_positional_interp.mdk` — `Person _ _` positional record-ctor pattern must match in `run` (F4; native already OK).
2. `guard_fall_native.mdk` — guarded function clause fall-through must be E-NONEXHAUSTIVE-MATCH in the native binary, not E-INDEX-OOB (F7).
3. `run_rejects_illtyped_if.mdk` — `f x = if x > 0 then x; main = println (f 5)` must FAIL under `medaka run` (F8).
4. `clause_miss_message.mdk` — interpreter clause fall-through message must not say "no matching impl for dispatch" (F6).
5. `neg_literal_pattern.mdk` — `-1 =>` (once supported) both engines; today at least a located error (F1/F2).
6. `deep_recursion_overflow.mdk` — overflow must produce a diagnostic, not silent exit 138, in both engines (F5); plus an interpreter TCO fixture (tail loop at 1M).
7. Working-today coverage: float-literal pattern, negative range pattern (`-5..0`), guard binder into arm body (`x if Some y <- h x, y > 25 => y`), record rest-pattern, match-on-function-value, duplicate-binder rejection, guards-defeat-exhaustiveness warning.
