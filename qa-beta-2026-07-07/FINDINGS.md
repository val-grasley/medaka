# Beta-hardening QA findings — 2026-07-07

Consolidated from 8 parallel adversarial-QA sweeps (beginner-syntax, bindings-mutability,
type-system, numerics-strings-data, patterns-control-flow, tooling-cli, test-gap-analysis,
playground-wasm). Full per-area reports with every repro and variation live in `reports/`;
each finding below cites its source as `report#Fn`. Every finding was reproduced at least
twice by its finding agent; the headline criticals were independently re-verified.

Binary under test: worktree `virtual-fluttering-meteor` @ `df6cfd51`, freshly built
`./medaka` + `playground/dist/playground.wasm`. Commands below assume that binary.

Severity: **P0** = launch blocker, fix before beta. **P1** = strongly recommended before
beta (first-day user pain, but survivable). **P2** = fix soon after / document. **P3** = polish.

---

## Cross-cutting themes (read first)

1. **`medaka run` is not the same language as `medaka check`/`build`.** The single biggest
   systemic problem. `run` executes a large class of ill-typed programs (missing-impl /
   constraint errors) to silent wrong answers or unlocated panics; conversely there are
   programs where `run` errors and `check` reports nothing (dead-end UX). The interpreter
   also lacks externs (IO, hashString) and several eval paths (record-form deriving,
   positional record patterns) that the native backend has, and vice versa
   (record-block deriving, `export import`, guarded-clause fallthrough). ~15 findings
   below are instances. `run` is the playground-adjacent default first command; parity is
   the beta's most important property.
2. **Parse errors inside a declaration body are reported at the declaration head**
   (`file:1:0: unexpected \`main\``) — independently rediscovered by four agents. It
   poisons a huge share of beginner mistakes (`+=`, `elif`, `let type = 5`, or-patterns,
   `-1` patterns, Rust braces, split `let…in`, Python `for`, anonymous records…). In the
   playground the squiggle lands on line 1. One fix, dozens of UX findings resolved.
3. **Runtime death is often silent or mislabeled.** SIGBUS/SIGSEGV with zero output on
   deep recursion and cyclic values; `E-INDEX-OOB` for a guard fallthrough;
   "no matching impl for dispatch" for a clause miss; native errors lack file:line.
4. **The 63-bit tagged Int is invisible.** Literals silently wrap (`9223372036854775807`
   prints `-1`); nothing user-facing documents Int width.

---

# P0 — Launch blockers

## P0-1: `medaka run` executes programs that `check`/`build` reject
- Class: soundness / run-build-divergence. Source: type-system#F1, bindings#F3,
  beginner#F2, patterns#F8, numerics#F2.
- Repros (each: `check` errors + exit 1, `build` refuses; `run` executes):
  - `main = println (1 == "a")` → run prints `False`, exit 0.
  - `main = println (1 + "a")` → run panics `runtime error [E-PANIC]: unknown op '+'` (no location).
  - `f x = if x > 0 then x` + `main = println (f 5)` → run prints `()`, exit 0 (check: 3 errors).
  - `f == g` on functions → run prints `False`; `Ref 1 == Ref 1` → `True`.
  - Heterogeneous list `[1,"a"]`, wrong annotation `let x : String = 1`, overlapping impls,
    missing superclass impl — all execute.
- Expected: `run` rejects exactly what `check` rejects. Other error classes DO gate run,
  so the gate exists but skips constraint/no-impl errors.

## P0-2: Silent signal crashes (SIGBUS/SIGSEGV, zero output)
- Class: crash. Source: patterns#F5, playground#F2, numerics#F10, bindings#F6.
- Repros:
  - `main = println (sum [1..=100000])` → `medaka run` exits 138 (SIGBUS), **no output at
    all**. Native build prints the answer. Interpreter dies ~30k non-tail / ~100k tail
    frames (no TCO); native dies the same silent way at ~10M non-tail frames.
  - `xs = 1 :: xs` + `take 3 xs` → typechecks (`xs : List Int`), then SIGSEGVs BOTH
    engines with no message.
  - `let Some x = None`-style failing refutable let (through a function, see
    bindings#F6 p34): run gives a clean located `E-LET-REFUTE`; **native binary
    SIGSEGVs (exit 139)**. Re-verified.
- Expected: never a bare signal death. "stack overflow: recursion too deep in <fn>" /
  E-LET-REFUTE parity / cyclic-value diagnostic.

## P0-3: `deriving` on record constructors is broken in BOTH pipelines, opposite directions
- Class: run-build-divergence / crash. Source: numerics#F1, playground#F6, type-system#F4.
  Re-verified both directions.
- Repros:
  - `record Person` block + `deriving (Display)` → `run` fine; **native binary panics
    E-NONEXHAUSTIVE-MATCH**. With `deriving (Debug)` or `(Eq)` the **emitter itself
    panics** (`E-PANIC: no impl of method 'debug' for type 'recdisp2__Person' (slice 6)`).
  - `data P = P { a : Int } deriving (Display)` → `build` fine (`P 1`); **`run` panics
    E-NONEXHAUSTIVE-MATCH** at the println.
  - `data F = F (Int -> Int) deriving (Eq)` → check passes; run: `F g == F g` → `False`
    (same value!); build: emitter panic (`arg-tag dispatch on impl type that owns no
    constructors (slice 7)`).
- Expected: records + deriving is early-tutorial material; all forms work in both
  pipelines; deriving Eq on non-Eq fields rejected at check.

## P0-4: Positional pattern on a record constructor: native matches, interpreter fails at runtime — and it's the exhaustiveness checker's own suggested fix
- Class: run-build-divergence / soundness. Source: patterns#F4.
- Repro: `data Person = Person { name: String, age: Int }`; `f p = match p` /
  `  Person _ _ => 42`. check clean; build prints 42; **run: E-NONEXHAUSTIVE-MATCH**.
  `check`'s non-exhaustive warning literally suggests adding `Person _ _ => …`.
- Expected: run == build.

## P0-5: Mutability is not enforced; branch-writes are lost or crash the emitter
- Class: silent-wrong / crash / divergence. Source: bindings#F1/F2/F5 (the session's seed
  finding, expanded).
- Repros:
  - `let x = 1` then `x = 2` → accepted by check/run/build/lint (prints 2). Also
    type-CHANGING reassign (`x = "hello"`), function-param reassign, pattern-bound
    reassign. `let mut` is currently meaningless for locals.
  - Top-level: `x = 1`; `main = (x = 2; println x)` → run prints `2`, **build prints `1`**.
  - `let mut x = 1` + `if True then` block `x = 2` → **run silently loses the write**
    (prints 1); **build crashes the emitter** (`E-PANIC: empty block`).
- Expected: non-mut reassignment is an error naming `let mut`; branch-local writes to
  `mut` work in both engines (that's the point of `mut`).

## P0-6: `medaka test` exits 0 when tests fail
- Class: silent-wrong (CI trap). Source: tooling#F1.
- Repro: any file with a failing doctest or failing `prop` — output says
  `1/2 passed (1 failed)` / `FAILED after 1 test`, **exit code 0**.
- Expected: nonzero exit on any failure.

## P0-7 (playground): un-annotated tail recursion loses TCO on wasm — first loop dies in the browser
- Class: crash. Source: playground#F1.
- Repro: `loop acc n = if n == 0 then acc else loop (acc + n) (n - 1)`;
  `main = println (loop 0 10000)` → playground: "Maximum call stack size exceeded".
  With signature `loop : Int -> Int -> Int` it runs at n=5,000,000. WAT shows plain
  `call` inside a `disp_fromInt` dispatch block instead of `return_call`.
- Expected: Num-polymorphic self-tail-calls still lower to `return_call`.

## P0-8 (playground): worker.js missing host imports — prelude `stringToFloat` LinkErrors in the browser
- Class: crash / error-ux. Source: playground#F3.
- Repro: `main = println (stringToFloat "3.25")` → compiles, then
  `instantiate failed: Import #3 "env" "mdk_str_to_float": function import requires a
  callable`. Native prints `Some 3.25`. Same shape for readFile/getEnv/args/exit group
  (those should instead get a clean "not available in the playground" message).
- Expected: pure shims (str_to_float) supplied; IO imports produce a friendly capability error.

## P0-9: `import map` + `import set` together — false stdlib warnings in the playground, runtime breakage in the interpreter
- Class: silent-wrong / divergence. Source: playground#F4/#F5. Likely cross-module
  `Bin`/`Tip` ctor collision.
- Repros:
  - Playground: `import map` + `import set` + hello → **14 false W-NONEXHAUSTIVE-CLAUSES
    warnings against set.mdk internals**, rendered with no filename (looks like the
    user's 3-line program); several with dummy 0:0 ranges. Native check: clean.
  - Interpreter: `import map.{fromList, get}` + `import set` + a Map lookup →
    `E-NOT-A-FUNCTION: applied non-function: Bin 1 1 one Tip` at a bogus location
    (117:30 in a 5-line file). Build and playground print `Some two`.
- Expected: no false warnings; run == build; diagnostics attributed to the right file.

## P0-10: stdlib `hash_map`/`hash_set` cannot run in the interpreter
- Class: run-build-divergence / crash. Source: numerics#F4, gap#F5.
- Repro: `import hash_map.{new, set, get}`; `set "a" 1 m` →
  `medaka run`: `E-PANIC: unbound identifier: hashString` (no location); native build
  works. Also `medaka test stdlib/hash_map.mdk` panics (`unbound identifier: hashInt`).
- Expected: stdlib modules work under `run`, or fail with a clean "native-only" error.

## P0-11: Systemic parse-error mislocation — every body-level parse error points at the decl head (line 1, col 0)
- Class: error-ux. Source: beginner#F1, bindings#F7, patterns#F1, playground#F8,
  type-system#F13 (independently found by four agents).
- Repro (one of ~20): `main =` / `  let type = 5` / `  println type` →
  `1:0: unexpected \`main\`` with the caret on `main`. Same for `x += 1`, `elif`,
  Python `:`, `const/var`, or-patterns `1 | 2 =>`, negative literal patterns `-1 =>`,
  `match x {`, split-line `let…in`, `for` loops, anonymous records, `f (x : String)`
  params, `impl Eq a => …`, capitalized definitions. In the playground the squiggle
  lands on line 1 under `main`.
- Expected: report at the offending token with what was expected. This single fix
  upgrades a dozen findings at once and is the highest-leverage UX change available.

## P0-12: REPL is first-touch and fatally brittle
- Class: crash / missing-feature. Source: tooling#F2/F3/F4.
- Repros:
  - Any lex/parse error (`?`, `let x = 5`, `"unclosed`) → `E-PANIC`, **session dead**,
    exit 1, all definitions lost. (Type errors and unbound vars recover fine.)
  - No multiline input: `f x =`⏎`  x + 1` kills the session; `record` decls impossible.
  - `import list` accepted silently, names stay unbound; `import list.{reverse}` same.
- Expected: parse errors reprompt; continuation prompt for incomplete input; imports
  work or error honestly. (If the REPL can't be hardened in time, consider hiding it
  from `--help` for the beta rather than shipping this.)

## P0-13: Module resolution is cwd-relative — `medaka run src/main.mdk` from project root can't find siblings
- Class: silent-wrong. Source: tooling#F8.
- Repro: project with `src/main.mdk` importing sibling `helper` → from project root:
  `unknown module: helper`; from inside `src/`: works. `medaka.toml` (entry=…) doesn't help.
- Expected: imports resolve relative to the entry file / project root.

## P0-14: `export import` re-export: run works, native build panics the emitter
- Class: run-build-divergence / crash. Source: gap#F2.
- Repro: base.mdk exports `double`; mid.mdk `export import base.{double}`; main imports
  mid → run prints 42; build: `E-PANIC: unbound variable 'double'`.

## P0-15: Attributes on a signature-less definition silently unbind it
- Class: silent-wrong / doc-mismatch. Source: gap#F1.
- Repro: `@inline`⏎`f x = x + 1`⏎`main = println (f 3)` → `Unbound variable: f`.
  SYNTAX.md's own attribute example is this exact failing shape (works only with a
  signature between attribute and definition).

## P0-16: `add(1, 2)` — the #1 newcomer call syntax — yields an undecipherable error
- Class: error-ux. Source: beginner#F3.
- Repro: `add x y = x + y`; `main = println (add(1, 2))` →
  `No impl of Display for ((Int, Int) -> (Int, Int))`. Variant `println add(1, 2)`
  blames println's arity.
- Expected: hint when an arity-≥2 function is applied to a matching-arity tuple:
  "did you mean `add 1 2`? `(1, 2)` is a tuple."

## P0-17: Missing method in an impl passes `check`, panics at runtime
- Class: soundness. Source: type-system#F2.
- Repro: interface with `greet`+`shout`; impl provides only `greet`; `check` exits 0
  with zero diagnostics; calling `shout` → `E-PANIC: unbound identifier: shout`.
- Expected: check error "impl Greet Foo is missing method 'shout'".

## P0-18: Dead-end divergences: `run` says "run `medaka check` for details" and check reports nothing
- Class: error-ux / divergence. Source: type-system#F3, numerics#F3.
- Repros:
  - Standalone fn + same-named interface method (documented-supported): check passes,
    run: `error: type error in <file>. Run 'medaka check' for details`.
  - `Map { f => 1 }` with a function key: run errors the same way; check exits 0.
- Expected: check and run agree; when run does refuse, it prints the actual diagnostics
  (see also P1-8).

---

# P1 — Fix before beta if at all possible

## P1-1: Int is 63-bit and literals silently wrap
- Source: type-system#F5, numerics#F7, gap#F6. `println 9223372036854775807` → `-1`;
  `4611686018427387903 + 1` → negative. run==build. No diagnostic, no documentation;
  `minInt`/`maxInt` don't exist. Expected: out-of-range literal = compile error; document
  Int width; (arithmetic wrap at least documented).

## P1-2: Scientific-notation floats: printer emits what the parser can't read
- Source: numerics#F5, type-system#F15. `println 0.00001` prints `1e-05`; feeding
  `1e-05` back → `E-NOT-A-FUNCTION: applied non-function: 1`; `1e12` →
  `Unbound variable: e12`; `5.0e-324` lexes as `5.0e-3` applied to `24`. Playground
  copy-paste of program output fails. Expected: accept `NeM` literals (or never print them).

## P1-3: Float printing truncates to ~12 significant digits — Debug is lossy
- Source: numerics#F6. `debug (0.1 + 0.2)` and `debug 0.3` both print `0.3` while `==`
  is False; `123456789012345.0` prints `1.23456789012e+14`. Expected: shortest-round-trip.

## P1-4: Quadratic perf cliffs a newcomer hits in minutes
- Source: numerics#F8/F9, patterns#F14, playground#F11.
  - `println [1..=100000]` native: 21 s (O(n²) Display); 1M: minutes. Playground killer.
  - `[1..=100000]` construction in the interpreter: ~48 s (O(n²)); `sum [1..=1000000]`
    under run: >2 min (native: 0.06 s).
  - 1000-term `1 + 1 + …` chain: 13.7 s to typecheck through the playground; no
    compile-side kill-timer in the browser (run-side only) — pathological paste pins the
    worker forever (playground#F11).

## P1-5: Guard/clause fall-through errors are wrong-class or jargon
- Source: patterns#F6/F7.
  - Guarded clauses all falling through: **native reports `E-INDEX-OOB: index out of
    bounds`** (user hunts a nonexistent indexing bug); interpreter reports it correctly.
  - Plain clause miss (`f 0`/`f 1`, call `f 5`): interpreter says
    `E-PANIC: no matching impl for dispatch` (no location, typeclass jargon); native
    says E-NONEXHAUSTIVE-MATCH.

## P1-6: Interpreter lacks IO externs — readLine/readFile/args/getEnv panic under `run`, work under `build`
- Source: tooling#F5, playground#F13. `E-PANIC: unbound identifier: readLine` (no
  location; reads like a scoping bug). check passes them. Expected: implement in eval or
  give a located "native-only primitive; use medaka build" error at check/run time.

## P1-7: Warnings are never surfaced by `run` or `build`
- Source: patterns#F9. Non-exhaustive-match / unreachable-arm warnings appear only under
  `check`; run/build users' first signal is the runtime abort (or P1-5's wrong-class
  crash). Expected: run/build print warnings to stderr.

## P1-8: `run`/`build` hide computed type errors behind "Run `medaka check` for details"
- Source: type-system#F16, bindings#F4, playground#F19. run already ran the typechecker;
  print the diagnostics. (The playground does better than the CLI here.)

## P1-9: Beginner-error hint-family gaps (the machinery exists — `def`/`for`/`return`/`\x ->`/`::`/`show`/`true`/`case of` all have model hints)
- Source: beginner#F5/F6/F13/F14, patterns#F3, playground#F16/F17, tooling#F14.
  Missing tailored hints for: `#` and `//` comments; `elif`; Python `lambda`; `and`/`or`;
  `xs[0]` indexing (→ `xs.[0]`); `x === y`; `len`/`null`/`console.log`; anonymous record
  literal `{ name = "v" }`; or-patterns; `String.toUpper`-style module-dot access
  (suggests internal `RString`!); `reverse` unbound suggests `traverse` instead of
  `import list.{reverse}`.

## P1-10: `<unknown location>` / 1:0 diagnostics family
- Source: type-system#F12/F19, beginner#F7, gap#F3/F8, tooling#F18, playground#F15.
  - "Duplicate type: Option" (prelude collision), recursive type alias, method-not-in-
    interface, unknown interface, overlap + missing-superclass errors: no location.
  - Multi-module `medaka build` reports every diagnostic at 1:0 without carets (check
    reports correct spans) — and no gate can catch this today.
  - Non-exhaustive warning range points at the last arm's body, not the `match`.

## P1-11: NaN poisons ordered collections
- Source: numerics#F14. `compare nan x` returns `Eq` for every x → a 2-entry Map literal
  with a NaN key collapses to 1 entry; `get`/`set` on NaN hit the wrong entry. Expected:
  total order for Ord Float (NaN sorted consistently) or documented UB.

## P1-12: `medaka run` loses stdout printed before a runtime error
- Source: playground#F7. `println "before"` then `10 / 0`: run shows only the error,
  "before" is gone (build and playground both flush). Debugging-by-println is broken
  exactly when needed.

## P1-13: Playground: native-only modules say "unknown module: math"
- Source: playground#F12. `import math` in the browser → `unknown module: math` (it
  exists, it's just not bundled). Also: no sqrt/pow available in the playground at all.
  Expected: "not available in the browser playground; available: list, map, set, …" +
  consider a wasm-safe math subset.

## P1-14: Playground compiler traps on large-but-legal input, uncoded
- Source: playground#F10. ~2000 top-level decls / 2000 nested parens / 20k-term chain →
  `{"message": "compiler trap: Maximum call stack size exceeded"}`, no `code`, dummy
  0:0 range, "compiler trap" leaks. Native handles the same inputs.

## P1-15: Doctest runner robustness
- Source: tooling#F6/F7/F15. A panicking doctest aborts the whole run at `:0:0` with no
  file/which-test; a syntactically-bad example → bare "parse error"; slightly-off
  formatting (example on the `{- |` line) is silently "(no doctests found)" (vacuous
  green); prop with an unbound name → mid-run E-PANIC instead of a located check error.

## P1-16: Prelude-name value bindings silently ignored
- Source: bindings#F8. `map = 99`; `println map` → run panics `intToString: not an Int`,
  check says `No impl of Display for ((a -> b) -> c a -> c b)` — the user's binding
  silently lost to the prelude method (function-form shadowing works fine).
  Expected: user binding wins or a clear "cannot shadow prelude method" error.

---

# P2 — Fix soon / document for beta

- **P2-1** Silent-accept validation gaps (type-system#F6/F7/F8, patterns#F10/F12,
  bindings#F11/F12): user `impl Eq Int` accepted then ignored; `deriving (Frobnicate)`
  (unknown iface) accepted; duplicate record-literal fields accepted (first wins);
  duplicate/unreachable function clauses unwarned (match arms DO warn); mixed-arity
  clauses get a raw unification error; assignment to unbound name errors at the use
  site, not the assignment; signature with no definition accepted.
- **P2-2** Kind checking absent on impls (type-system#F10): `impl Mappish Int` accepted;
  use site leaks malformed type `Int Int`.
- **P2-3** impl-for-type-alias: check rejects, run dispatches (type-system#F11).
- **P2-4** Wildcard import doesn't bring interfaces into impl scope; error located
  `<unknown location>` (type-system#F9).
- **P2-5** String interpolation edges (numerics#F11/F12/F13): triple-quoted interp hole
  with spaces eats the following newline+indent; nested string-in-hole → "unterminated
  string literal" pointing past EOF; acceptance of if-in-hole depends on surrounding
  statement count; empty hole → "unexpected a string".
- **P2-6** Layout traps (beginner#F8/F10): mixed tab/space indentation silently mis-nests
  (surfaces as println-arity type errors); UTF-8 BOM → error quoting an invisible char.
- **P2-7** CLI polish (tooling#F9/F10/F11/F12/F16/F19): no `--version`; misspelled
  subcommand → "not yet in native CLI" jargon, no did-you-mean; `medaka fmt <dir>` is a
  silent no-op (CI trap; lint accepts dirs); `bench` in --help but unimplemented /
  `manifest` implemented but hidden; run on missing file → "unknown module: nope"
  (check: bare "No such file or directory"; build gets it right); `medaka test` with no
  args prints usage but exits 0; `check` output lacks trailing newline; unknown lint
  rule names silently accepted.
- **P2-8** REPL/doc type display drops constraints (tooling#F13): `:type map` prints
  `(a -> b) -> c a -> c b` with no `Mappable c =>`; `medaka doc` same; REPL banner
  doesn't mention `:browse`/`:type`; `:help` doesn't exist.
- **P2-9** Native runtime errors lack file:line (numerics#F16, patterns#F11) and drop
  detail the interpreter has (offending index).
- **P2-10** `deriving Display` without parens → "unexpected `data`" at 1:0
  (playground#F9); Haskell habit, needs accept-or-hint.
- **P2-11** Map/Set literals need `import map.*` — SYNTAX.md doesn't say so, error gives
  no help (numerics#F17, gap#F7).
- **P2-12** `panic "msg"` as main's last statement is a check error ("Ambiguous instance
  for Display" at 1:0) yet run executes it (playground#F14).
- **P2-13** Docs drift: SYNTAX.md Refs example uses nonexistent `set_ref`, `.value` read
  undocumented (bindings#F10); SYNTAX.md attribute example is the P0-15 failing shape;
  SYNTAX.md still cites deleted OCaml paths as ground truth; `bench` documented but dead
  (gap#F4); Int width undocumented; negative `%`/`/` conventions undocumented.
- **P2-14** `let mut` closure capture is a silent snapshot (bindings#F9): counter idiom
  returns stale values with zero warning; the write attempt inside a lambda is a parse
  error reported at 1:0. Known-by-design semantics, but needs a warning or doc.
- **P2-15** `-0.0` run/build divergence (numerics, known-deferred; re-confirmed).

# P3 — Polish (grouped)

- Non-ASCII identifiers rejected mid-token without naming the ASCII rule (beginner#F17).
- `${x}` / f-string interpolation silently inert in strings — lint candidate (beginner#F16).
- Capitalized definition `Double x = …` → bare "unexpected `Double`" (beginner#F15).
- Cascading second diagnostics (field-access after unbound receiver; Ambiguous-Display
  after a real error) (type-system#F17, playground#F16).
- `import util` (bare) is a silent no-op — qualified access isn't a thing (tooling#F17).
- Cyclic-import error readable but unlocated (tooling#F18).
- `medaka new` accepts any name; medaka.toml never validated (tooling#F21).
- `medaka doc` leaks the `{- |` pipe into rendered output (tooling#F20).
- Effect-leak diagnostic prints `<>` jargon, wrong anchor (type-system#F22).
- Wrong-arity call on unannotated fn → "No impl of Num for (Int -> Int)" (type-system#F21).

---

# Notable positives verified (pin these — see FIXTURES.md)

- All 3 playground embedded examples byte-identical across run/build/playground; Playwright
  e2e green; 200k-line output in 0.5 s; multi-error diagnostics JSON complete with codes+fix.
- Unicode strings cleanly codepoint-based, run==build (emoji/CJK/combining).
- `main () =` silent-no-op is FIXED — now errors loudly with a model message.
- JS arrow lambdas are native syntax; `print("hi")`, `putStrLn`, `not`, `else if`,
  `where`, nested block comments, `f -1` ≡ `f (-1)` all work.
- Occurs check solid; Ref value restriction holds; guards + refutable guards fully work
  with correct binder scoping; float-literal patterns, char/negative ranges, as-patterns,
  record rest-patterns all work in both engines.
- Excellent existing diagnostics worth protecting: missing-case messages naming the
  concrete pattern, `case…of` hint, `Maybe`→`Option` hint, duplicate-binding error,
  import-error with available-modules list, invalid-escape caret, `/=`→`!=`.
