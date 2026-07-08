# Findings: bindings-mutability

Probes: /private/tmp/claude-501/-Users-val-medaka/07db78cb-7807-4285-bb67-639494a218d2/scratchpad/probes/bindings/
Binary: /Users/val/medaka/.claude/worktrees/virtual-fluttering-meteor/medaka ($WT/medaka). All findings reproduced twice.

## F1: Reassigning a non-`mut` binding is silently accepted everywhere (mut is meaningless)
- Severity: high
- Class: silent-wrong
- Launch blocker: yes
- Repro (p01):
  ```
  main =
    let x = 1
    x = 2
    println x
  ```
  $ medaka run p01.mdk        → `2` (exit 0)
  $ medaka check p01.mdk      → clean
  $ medaka build && ./out     → `2`
  $ medaka lint p01.mdk       → no findings
- Variations, all silently accepted:
  - Type-changing reassign (p03): `let x = 1` then `x = "hello"` — accepted by check/run/build; `x` just takes the new type.
  - Function parameter reassign (p05): `f n = (n = n + 1; n)` → 6.
  - Pattern-bound var reassign (p42): `let (a, b) = (1, 2); a = 10` → 12.
- Expected: reassigning a non-`mut` binding should be an error ("x is not mutable; declare it `let mut x`"). As shipped, `let mut` conveys nothing for locals — check/run/build behave identically with and without `mut`.
- Hypothesis: bare-block reassignment statement never consults the binding's mutability.

## F2: Reassigning a TOP-LEVEL binding — run mutates it, build silently ignores the write (divergence)
- Severity: high
- Class: run-build-divergence
- Launch blocker: yes
- Repro (p06):
  ```
  x = 1

  main =
    x = 2
    println x
  ```
  $ medaka run p06.mdk → `2`
  $ medaka build p06.mdk -o out && ./out → `1`
  Both exit 0; `medaka check` is clean.
- Expected: either an error (top-level bindings immutable) or the same answer in both pipelines.

## F3: `medaka run` does NOT enforce type errors that `check`/`build` report — programs with "No impl" errors execute and die with a runtime panic
- Severity: critical
- Class: run-build-divergence / soundness
- Launch blocker: yes
- Repro (p12):
  ```
  main = println (1 + "a")
  ```
  $ medaka check p12.mdk → `1:16: No impl of Num for String` (good diagnostic)
  $ medaka build p12.mdk → same, refuses to build
  $ medaka run p12.mdk   → `runtime error [E-PANIC]: unknown op '+'` (exit 1, no location, no source context)
- Same for p07 (`let x = 1; x = "hello"; println (x + 1)`): check/build reject, run executes to the same panic.
- Also (p39): the divergence goes the other way too — a multi-statement top-level value binding
  ```
  x =
    println "computing x"
    42

  main =
    println x
    println x
  ```
  RUNS fine (`computing x` / `42` / `42`) but check/build reject it with a confusing `Type mismatch: String vs Int` at `println x` (the block clearly ends in an Int; the reported String type looks wrong).
- Expected: `run` and `check` accept/reject the same programs; run should print the type diagnostic, not a jargon runtime panic.
- Hypothesis: run's typecheck treats missing-impl constraints as deferrable to arg-tag dispatch; p39 suggests top-level block bindings are typed differently in the check path.

## F4: When `run` DOES abort on a type error, it hides the diagnostic ("Run `medaka check` for details")
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro (p29):
  ```
  main =
    let Some x = None
    println x
  ```
  $ medaka run p29.mdk → `error: type error in <file>. Run `medaka check` for details`
- Expected: run should print the same diagnostic check prints (here: ambiguous Display instance). Forcing a second command for every type error is bad first-run UX.

## F5: Assignment inside an if/match branch block — run silently loses the write; build crashes the emitter
- Severity: high
- Class: silent-wrong + crash
- Launch blocker: yes
- Repro (p10b):
  ```
  main =
    let mut x = 1
    if True
      then
        x = 2
      else
        x = 3
    println x
  ```
  $ medaka run p10b.mdk → `1`  (write silently lost; expected 2)
  $ medaka build p10b.mdk -o out → `error: emitter failed compiling ...` / `runtime error [E-PANIC]: empty block`
- Same for a match arm (p11: `match 5 ⏎ n => ⏎ x = n` then `println x` → run prints 1; build panics `empty block`).
- The inline form `then x = 2 else x = 3` is a parse error reported at 1:0 `unexpected main` (see F7).
- Expected: branch-local mutation of a `mut` binding is THE reason `mut` exists; it should either work or be a clear front-end error. An emitter E-PANIC is a compiler crash.

## F6: Failing refutable `let` pattern: interpreter gives a clean error, native binary SEGFAULTS
- Severity: critical
- Class: crash + run-build-divergence
- Launch blocker: yes
- Repro (p34):
  ```
  f : Option Int -> Int
  f m =
    let Some x = m
    x

  main = println (f None)
  ```
  $ medaka run p34.mdk → `3:15: runtime error [E-LET-REFUTE]: let pattern match failed` (exit 1, good)
  $ medaka build p34.mdk -o out && ./out → no output, exit 139 (SIGSEGV), reproduced twice
- Expected: native binary should abort with the same E-LET-REFUTE message. (Also: `check` accepts a refutable let with no `else` without any warning — arguably fine given the runtime check, but the native path lacks that check entirely.)

## F7: Systemic wrong-location parse errors: any parse error inside a decl body is reported at the decl (or next decl) header as "unexpected <name>" at column 0
- Severity: high
- Class: error-ux
- Launch blocker: yes (first-contact UX: every beginner syntax slip points at line 1)
- Repros:
  - p04: `let mut x = 1; x += 2` → `1:0: unexpected `main`` (also: no compound assignment operators exist — a newcomer will try `+=` in minute one; the "error" gives zero hint).
  - p35: `let bump = () => count = count + 1` (assignment in lambda body) → `1:0: unexpected `main``.
  - p41: `let f = () =>` followed by an indented block body → `1:0: unexpected `main``.
  - p47: decl `helper n = ⏎ n +` (error on line 6) → `5:0: unexpected `helper`` — blames the enclosing decl's header, not the bad token.
- Expected: point at the offending token/line with a message about what was expected.
- Hypothesis: the parser fails the whole declaration and re-reports from the decl-start token.

## F8: Top-level VALUE binding named after a prelude interface method is silently ignored (`map = 99`), inconsistently with function-form shadowing which works
- Severity: medium
- Class: silent-wrong / error-ux
- Launch blocker: no
- Repro (p46):
  ```
  map = 99

  main = println map
  ```
  $ medaka run p46.mdk → `runtime error [E-PANIC]: intToString: not an Int`
  $ medaka check p46.mdk → `No impl of Display for ((a -> b) -> c a -> c b)` — i.e. `map` still resolves to the PRELUDE method; the user's binding is silently dropped.
- But function-form shadows work fine: `map f xs = 42` (p16c) → 42; `length xs = 999` (p16b) → 999; shadowing an imported name works (p40).
- Expected: either the user binding wins (like the function form) or a clear "cannot shadow prelude method `map`" error. The run-path panic and the check-path Display-on-a-function-type message are both baffling; and run vs check disagree on the failure mode.

## F9: Counter-closure idiom over `let mut` gives silently stale values (closures snapshot)
- Severity: medium
- Class: silent-wrong (known semantics, but zero warning)
- Launch blocker: no
- Repro (p13):
  ```
  main =
    let mut count = 0
    let bump = () => count + 1
    count = 10
    println (bump ())
  ```
  $ medaka run / build → `1` (closure captured count=0 by value; user expects 11)
- Writing to the captured var inside the lambda (`() => count = count + 1`) is a parse error reported at 1:0 (F7), so the user gets no semantic hint that capture is by-value.
- Expected: at minimum a warning on capturing a `mut` binding in a closure, plus a real parse/diagnostic for the write attempt pointing at the lambda. `Ref` works as the escape hatch (p14b) — but see F10.

## F10: Refs are underdocumented and half-missing: SYNTAX.md says `set_ref` (doesn't exist), no read API is documented, `getRef` doesn't exist
- Severity: low
- Class: doc-mismatch / missing-feature
- Launch blocker: no
- Repro: SYNTAX.md "## Refs": `let mut count = Ref 0 in set_ref count 42` — `set_ref` is unbound; the extern is `setRef` (stdlib/runtime.mdk:16). Reading is `count.value` — documented nowhere in SYNTAX.md. `getRef count` → `Unbound variable: getRef. Did you mean 'setRef'`.
- Working form (p14b): `let count = Ref 0; setRef count (count.value + 1); println count.value` → works, run==build.
- Expected: SYNTAX.md example that actually runs; a documented read function or `.value` mention.

## F11: Assignment to an UNBOUND name is silently discarded; error surfaces at the later use site
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro (p43):
  ```
  main =
    y = 5
    println y
  ```
  $ medaka run/build → `3:10: Unbound variable: y` — points at the `println`, not at `y = 5` (line 2), which is where the user's mistake is.
- Expected: "assignment to unbound variable `y`" at line 2 (Python/JS users will expect `y = 5` to *create* a binding — the error should teach `let`).

## F12: Duplicate function clauses with an identical pattern are accepted without warning (first wins)
- Severity: low
- Class: silent-wrong
- Launch blocker: no
- Repro (p24): `f 0 = "a"` / `f 0 = "b"` / `f n = "c"`; `f 0` → `"a"`, no diagnostic for the unreachable second clause. (Contrast: duplicate top-level VALUE binding gets an excellent error — p23.)
- Expected: unreachable-clause warning.

## F13: Interpreter runtime panics leak internal jargon with no location
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Examples collected above: `runtime error [E-PANIC]: unknown op '+'` (p12), `intToString: not an Int` (p46), `empty block` (p10b build). None carry a source location or user-level explanation, unlike the (good) E-LET-REFUTE panic which has file:line:col.
- Expected: all runtime panics located and phrased in user terms.

## Positive surprises (worked, worth fixtures)
- Duplicate top-level binding error is excellent (p23): "Duplicate binding 'x' ... rename this one or remove it".
- No scope leaks: `let` inside a then-block (p25) and match-arm binders (p26) correctly do not escape — clean Unbound errors.
- `let (a,b) = ...`, `let Some x = ...`, record destructuring `let P { px, py } = ...` all work (p27/p28/p30).
- `let else` works incl. across build (p44b); use-before-define and top-level mutual recursion work (p19/p20); `let xs = 1 :: xs` and `let x = x + 1` give clean Unbound errors (p21/p22).
- Top-level nullary laziness: unused binding's effect never runs (p31); used-twice binding evaluates ONCE and is cached, identical in run and build (p38).
- `Unknown type: Maybe. Did you mean 'Option' ('Maybe' is Haskell...)` is a model diagnostic (p34 first draft).
- Local `let` shadowing the enclosing function's own name works (p18); shadowing an imported stdlib function works (p40); same-block re-`let` with a different type works (p15).

## Suggested regression fixtures
1. `nonmut_reassign_rejected.mdk` — `let x = 1; x = 2` must error once F1 is fixed (plus param/pattern-bound variants p05/p42).
2. `toplevel_reassign.mdk` — p06: run==build for top-level write (currently diverges).
3. `run_typechecks.mdk` — `main = println (1 + "a")` must fail identically under run/check/build (F3).
4. `branch_mut_write.mdk` — p10b/p11: if/match-branch writes to a `mut` var; run value correct AND build must not emitter-panic (F5).
5. `let_refute_native.mdk` — p34: native binary must exit with E-LET-REFUTE, not SIGSEGV (F6).
6. `parse_error_location.mdk` — p47: parse error inside a body must report the offending line, not the decl header (F7).
7. `prelude_method_value_shadow.mdk` — p46: `map = 99; println map` (F8) — pick a semantics and pin it.
8. `mut_closure_snapshot.mdk` — p13: pin snapshot semantics run==build (currently the one consistent thing).
9. `ref_counter.mdk` — p14b: Ref/setRef/.value counter, run==build (works today, no fixture apparent).
10. `toplevel_lazy_once.mdk` — p38/p39: effectful top-level binding evaluated exactly once, run==build (and un-reject p39's block-binding form).
11. `dup_clause_warning.mdk` — p24 once F12 gets a warning.
