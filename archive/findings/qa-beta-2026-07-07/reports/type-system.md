# Type-system findings (adversarial QA, 2026-07-07)

Binary: `$WT/medaka` (worktree `virtual-fluttering-meteor`). All repros under
`scratchpad/probes/ts/`. Every finding reproduced twice.

## F1: `medaka run` executes ill-typed programs (typecheck gate inconsistently enforced)
- Severity: critical
- Class: soundness / run-build-divergence
- Launch blocker: yes
- Repro (several — all rejected by `check` AND `build`, all execute under `run`):
  ```
  main = println (1 + "a")
  ```
  `$ medaka run basic_err.mdk` →
  ```
  runtime error [E-PANIC]: unknown op '+'
  ```
  (no file/line; `medaka check` correctly reports `No impl of Num for String`.)
  ```
  main = println (1 == "a")
  ```
  `$ medaka run eqdiff.mdk` → prints `False` and exits 0. Comparing an Int to a
  String silently "works" at the flagship entry point.
  ```
  data Box a = Box a
  b = Box (x => x)
  main =
    let (Box f) = b
    let _ = f 1
    println (f "s")
  ```
  `check` rejects (`Type mismatch: Int literal vs String`); `run` prints `s`.
  Also executes despite check errors: if-branch mismatch (`if 1 < 2 then 1 else "s"` →
  runtime panic `putStrLn: not a String`), heterogeneous list (`[1,"a"]` → panic
  `'++' requires Semigroup…`), overlapping impls (runs, silently picks first),
  missing superclass impl (runs), `f == f` on functions (prints `False`), wrong
  `let x : String = 1` annotation (runs to panic).
  Yet OTHER type errors DO stop `run` (`f 1 2` over-application, `println` of a
  closure, record-field errors) with `error: type error in <file>. Run 'medaka
  check' for details` — so the gate exists but is skipped for a large error class.
- Expected: `run` = typecheck + interpret (per README framing and `build`/`check`
  behavior). Any program `check` rejects must not execute; runtime panics that do
  occur should carry a location.
- Hypothesis: run's driver treats some typecheck error kinds (literal/Num/no-impl
  on concrete types) as non-fatal warnings, or a fallback untyped-eval path.

## F2: Missing method in an impl passes `check` silently, panics at runtime
- Severity: high
- Class: soundness
- Launch blocker: yes
- Repro:
  ```
  interface Greet a where
    greet : a -> String
    shout : a -> String

  data Foo = Foo

  impl Greet Foo where
    greet _ = "hi"

  main = println (shout Foo)
  ```
  `$ medaka check missmethod.mdk` → `main : Unit`, exit 0, `--json` diagnostics: `[]`.
  `$ medaka run missmethod.mdk` → `runtime error [E-PANIC]: unbound identifier: shout`
- Expected: check error at the impl: "impl Greet Foo is missing method 'shout'".
- Hypothesis: impl completeness is never validated; methods without default bodies
  just don't get bound.

## F3: Inverse divergence — `run` reports a type error that `check` cannot show (dead-end UX)
- Severity: high
- Class: error-ux / run-build-divergence
- Launch blocker: yes
- Repro (standalone function + interface method sharing a name — documented as supported):
  ```
  greet x = "fn " ++ x

  interface Greet a where
    greet : a -> String

  data Foo = Foo

  impl Greet Foo where
    greet _ = "impl"

  main =
    println (greet "s")
    println (greet Foo)
  ```
  `$ medaka check methcollide.mdk` → prints signatures, exit 0, `--json` → no diagnostics.
  `$ medaka run methcollide.mdk` → `error: type error in <file>. Run 'medaka check' for details`, exit 1.
- Expected: both agree; if it's an error, `check` must show it; if not, `run` must run it.
  As shipped the user is told to run `check` "for details" and check says everything is fine.

## F4: `deriving Eq` on a type containing a function: silently-wrong `==` under run, INTERNAL EMITTER PANIC under build
- Severity: high
- Class: crash + silent-wrong
- Launch blocker: yes
- Repro:
  ```
  data F = F (Int -> Int) deriving (Eq)
  g x = x + 1
  main = println (F g == F g)
  ```
  `$ medaka check dervfn2.mdk` → passes (exit 0).
  `$ medaka run dervfn2.mdk` → `False`  (same value compared to itself!)
  `$ medaka build dervfn2.mdk -o out` →
  ```
  error: emitter failed compiling <file>
  runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors (slice 7: primitive receiver carries no cell tag)
  ```
- Expected: deriving Eq should be rejected when a field type has no Eq (functions),
  as in Haskell/Rust. At minimum: no internal-jargon compiler panic from a program
  check accepts. Related: direct `f == f` is correctly rejected by check
  (`No impl of Eq for (Int -> Int)`) — derive bypasses that check. Note deriving Eq
  also ignores Eq-ability of any member (`data Wrap = Wrap NoEq deriving (Eq)` accepted,
  structural eq at runtime).

## F5: Ints are 63-bit and out-of-range literals silently wrap — `println 9223372036854775807` prints `-1`
- Severity: high
- Class: silent-wrong / doc-mismatch
- Launch blocker: no (but must be documented + diagnosed)
- Repro:
  ```
  main =
    println 9223372036854775807
    println 4611686018427387903
    println (4611686018427387903 + 1)
  ```
  `$ medaka run numbig.mdk` (build identical) →
  ```
  -1
  4611686018427387903
  -4611686018427387904
  ```
- Expected: a lex/typecheck error for literals outside the representable range
  (2^62-1 max, due to the tagged-i64 runtime), and the int width documented.
  Arithmetic overflow wrapping at 2^62 is at least worth a doc note.

## F6: User `impl Eq Int` duplicating a prelude impl is accepted and silently IGNORED
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro:
  ```
  impl Eq Int where
    eq a b = False

  main =
    println (eq 1 1)
    println (1 == 1)
  ```
  `$ medaka run impleqint2.mdk` (and build; check passes) → `True` / `True`.
- Expected: an overlap error (same-file user-impl overlap IS detected — see F19 —
  but overlap vs prelude/core impls is not), or the user impl winning. Accepting
  the impl and never calling it — even via a direct `eq 1 1` — is the worst option.

## F7: `deriving (Frobnicate)` — unknown interface silently accepted
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro:
  ```
  data Foo = Foo deriving (Frobnicate)
  main = println "ok"
  ```
  `$ medaka check dervunknown.mdk` → `main : Unit`, exit 0. run prints `ok`.
- Expected: "Unknown interface 'Frobnicate' in deriving clause" (typo-suggesting Eq/Ord/Debug…).

## F8: Duplicate field in a record literal silently accepted
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro:
  ```
  data Point = Pt { x : Int, y : Int }
  main =
    let p = Pt { x = 1, x = 2, y = 3 }
    println p.x
  ```
  `$ medaka check recdup.mdk` → passes; `run` prints `1` (first occurrence wins, silently).
- Expected: error "duplicate field 'x' in record construction".

## F9: `import m.*` wildcard does not bring an interface into scope for an `impl` — and the failure has no location
- Severity: medium
- Class: silent-wrong / error-ux
- Launch blocker: no
- Repro (project with `medaka.toml`): `defs.mdk` has `export interface Greet a where greet : a -> String`; `other.mdk`:
  ```
  import defs.*

  impl Greet Foo where
    greet _ = "from other"
  ```
  `$ medaka check other.mdk` → `<unknown location>: Unknown interface: Greet` (no file, no line).
  Changing to `import defs.{Greet, Foo(..)}` works.
- Expected: wildcard import should surface the interface like a named import does;
  the error needs a location and should mention the impl site.
- Bonus: with named imports and two modules both impl-ing `Greet Foo`, the conflict
  IS caught but as `TYPE ERROR: Conflicting `impl Greet`. Defined in defs and other`
  — raw `TYPE ERROR:` prefix, no location, doesn't name the type (`Foo`).

## F10: No kind checking on impls — `impl Mappish Int` accepted; use site leaks malformed type `Int Int`
- Severity: medium
- Class: soundness / error-ux
- Launch blocker: no
- Repro:
  ```
  interface Mappish f where
    mapish : (a -> b) -> f a -> f b

  impl Mappish Int where
    mapish f x = x

  main = println (mapish (n => n + 1) 5)
  ```
  `$ medaka check wrongkind2.mdk` →
  ```
  Type mismatch: Int literal vs Int Int
  No impl of Display for Int Int
  ```
  (Without the call, the impl alone passes check entirely.)
- Expected: kind error at the impl ("Mappish expects a type constructor, Int has kind *");
  the ill-kinded type `Int Int` should never be printed to a user.

## F11: Check/run disagree on impl-for-a-type-alias
- Severity: medium
- Class: run-build-divergence
- Launch blocker: no
- Repro:
  ```
  interface Greet a where
    greet : a -> String

  type MyInt = Int

  impl Greet MyInt where
    greet _ = "int"

  main = println (greet 3)
  ```
  `$ medaka check implalias.mdk` → `No impl of Greet for Int` (error).
  `$ medaka run implalias.mdk` → `int`.
- Expected: aliases expand transparently (2026-06-30 feature), so both should
  accept — or both reject. One rejecting while the other dispatches fine is a coin-flip.

## F12: Several diagnostics print `<unknown location>`
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro/observed:
  - `type T = List T` → `<unknown location>: Recursive type alias 'T'. Type aliases cannot be recursive or cyclic`
  - extra/misspelled method in an impl (`greeet _ = "typo"`) → `<unknown location>: Method 'greeet' is not part of interface 'Greet'`
  - F9's `Unknown interface: Greet`
- Expected: real file:line:col + caret like every other diagnostic. The
  extra-method message otherwise reads well (a "did you mean 'greet'" would be a bonus).

## F13: Common Haskell-isms die as bare parse errors at column 0 with no hint
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro/observed (all point at the DECL NAME at col 0, not the offending token):
  - `impl Eq a => Greet (List a) where …` → `4:10: unexpected '=>'` (no "use `requires Eq a` after the head")
  - `f : requires Eq a => a -> Bool` → `1:0: unexpected 'f'` (no "`requires` belongs on interfaces/impls; in signatures write `Eq a =>`")
  - `apply : (forall a. a -> a) -> …` → `1:0: unexpected 'apply'` (no "no higher-rank types / forall")
  - `p = { x = 1, y = 2 }` (anonymous record) → `1:0: unexpected 'p'`
- Expected: point at the token that failed, and for the constraint-syntax split
  (`=>` in sigs vs `requires` on impls — an intentional, documented design) give
  the cross-hint, since every Haskell refugee will hit both directions.

## F14: Parameter type annotations in function definitions don't parse
- Severity: medium
- Class: missing-feature / error-ux
- Launch blocker: no
- Repro:
  ```
  f (x : String) = x + 1
  main = println (f "a")
  ```
  `$ medaka check paramann.mdk` → `1:0: unexpected 'f'`
- Expected: either support `(x : T)` params (property tests already use exactly this
  syntax: `prop "commutative" (x : Int) = …` per SYNTAX.md — inconsistent), or a
  targeted message "annotate with a standalone signature `f : String -> Int`".

## F15: `1e12` → `Unbound variable: e12` (known gap; message actively misleads)
- Severity: medium
- Class: missing-feature / error-ux
- Launch blocker: no
- Repro:
  ```
  main = println 1e12
  ```
  `$ medaka check numsci.mdk` → `1:16: Unbound variable: e12` (likewise `1.5e3` → `Unbound variable: e3`).
- Expected: scientific-notation float literals, or at least a lexer error
  "scientific notation not supported; write 1000000000000.0". Current state confirmed
  unchanged from the 2026-06-19 filing.

## F16: `run`'s type-error report shows no diagnostics, just "run check"
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro: any type error that DOES gate run, e.g. `main = println (f + 1)` with `f x = x`:
  ```
  $ medaka run fnarith.mdk
  error: type error in /abs/path/fnarith.mdk. Run `medaka check` for details
  ```
- Expected: print the same diagnostics check prints (run clearly already ran the
  typechecker). Two-step workflow is pure friction — and in F3's case the referral
  is to a check that shows nothing.

## F17: Field-access errors leak `<unknown>` record name / don't say "not a record"
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `main = println (42).x` →
  ```
  1:16: Field 'x' does not belong to record '<unknown>'
  ```
  Same `'<unknown>'` for `(Pt { x = 1, y = 2 }).z` where the type (Pt) is statically obvious.
  Plus a trailing spurious `Ambiguous instance for 'Display'` second error on the same expr.
- Expected: "Int is not a record" / "record 'Pt' has no field 'z' (fields: x, y)"; suppress the cascade.

## F18: A signature with no definition is silently accepted
- Severity: low
- Class: silent-wrong
- Launch blocker: no
- Repro: file containing only `f : Int -> Int` and `main = println "ok"` → check passes.
- Expected: "signature for 'f' lacks a binding" (Haskell errors; catches typo'd names).

## F19: Overlap and missing-superclass errors point at line 1:0, not the offending impl
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: two `impl Greet Foo` blocks (lines 6 and 9) →
  ```
  1:0: Overlapping impls of Greet: Foo and Foo can match the same type. …
  ```
  and `impl MyOrd Foo` (line 9) missing `impl MyEq Foo` →
  ```
  1:0: 'impl MyOrd Foo' requires a superinterface 'impl MyEq Foo', which is missing
  ```
  Both carets sit on the `interface` declaration at line 1. (Message text itself is good.)
- Expected: caret on the second impl / the incomplete impl.

## F20: `main x = …` — check's message is misleading, run's is excellent
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `main x = println x`
  - `check`: `1:9: Ambiguous instance for 'Display'. Cannot determine which impl; add a type annotation` (nothing about main).
  - `run`: `'main' must be a value of type Unit. Write 'main = …', not 'main () = …' or 'main x = …' …` (great).
- Expected: check should emit the run message (that's where LSP/editor users see it).

## F21: Wrong-arity call reported as `No impl of Num for (Int -> Int)`
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `f x = x + 1` ; `main = println (f 1 2)` → check:
  ```
  2:18: No impl of Num for (Int -> Int)
  ```
  caret on the `1`. (When a SIGNATURE pins the arity, the message is the excellent
  `'f' takes 1 argument(s) but is applied to 2.` — unannotated functions deserve the same.)
- Expected: "too many arguments to 'f'" heuristic when the mismatch is function-vs-Num/apply.

## F22: Minor message/format nits
- Severity: low
- Class: error-ux
- Launch blocker: no
- Observed:
  - `medaka check` success output lacks a trailing newline (`main : Unitexit=0` glued to the shell prompt).
  - Effect-leak message: `Effectful value used where <> is allowed, but it performs <IO>` — `<>` jargon, and both diagnostics point at the function's last expression, not the effectful call.
  - `apply f = (f 1, f "s")` → first error `Type mismatch: String -> a vs (a, a)` pairs two unrelated types and reuses `a` for two different variables.
  - Location-less runtime panics under run for F1-class programs (`unknown op '+'`, `putStrLn: not a String`) vs the nicely-located `E-DIV-ZERO` — inconsistent.

## Positive surprises (worth regression fixtures)
- Occurs check is solid and located: `f x = f`, `omega = x => x x`, `f x = f [x]` all cleanly rejected.
- Value restriction on `Ref` holds in `check` (poly ref used at two types rejected; `Ref` by-name exclusion works), incl. through `Ref []`.
- Beginner-error copy is often excellent: if-branch mismatch and heterogeneous-list errors name both types AND suggest both fixes; `No impl of Greet for Foo; add 'deriving Greet' … or write an 'impl Greet Foo'`; `Could not deduce 'Num a' from the signature of 'f' … add 'Num a =>'`; ambiguous shared field `.name` error suggests `(r : A).name`; typo → `Did you mean 'print'`.
- `f -1` parses as `f (-1)` (friendlier than Haskell).
- Cross-module conflicting impls detected (message quality aside, F9).
- Let-polymorphism vs lambda-bound monomorphism both behave correctly.
- Orphan impls (impl in a module owning neither interface nor type) resolve fine through the loader.
- `check --json` carries stable `code`/`range` correctly (`T-NO-IMPL` etc.).

## Suggested regression fixtures
1. `run` must reject everything `check` rejects: fixture sweep asserting `run` exit != 0 for `1+"a"`, `1=="a"`, if-branch mismatch, `[1,"a"]`, no-impl method call, overlapping impls, missing superclass (F1).
2. Impl completeness: interface with 2 methods, impl providing 1 → check error (F2).
3. Standalone fn + same-named interface method: check==run verdict (F3).
4. `deriving (Eq)` on fn-field type: rejected — or at minimum `medaka build` doesn't panic (F4).
5. Int literal `2^62` and `2^63-1` → lex/typecheck diagnostic (F5).
6. User `impl Eq Int` → overlap-with-prelude diagnostic (F6).
7. `deriving (UnknownIface)` → error (F7).
8. Duplicate field in record literal → error (F8).
9. Wildcard-import + impl of imported interface (F9) — currently broken, fixture on fix.
10. Ill-kinded impl (`impl Mappable Int`) → kind error (F10).
11. `impl` for a type alias: check accepts iff run dispatches (F11).
12. Locations: recursive alias, extra impl method, overlap, superclass — all carry file:line (F12/F19).
13. Working-today coverage: occurs-check trio; Ref value-restriction pair; `f -1` negative-literal application; cross-module conflicting-impl detection; ambiguous shared-field diagnostic; orphan-impl dispatch through loader.
