# Findings: playground-wasm

Area: the browser playground pipeline (compile.mjs seam → playground.wasm →
wat2wasm → worker.js runner), tested via the exact seam Node harness
(`pg_compile.mjs` feeding the same EXTRA_MODULES vfs main.js bundles, then a
Node port of worker.js's exact 4-import glue), compared against `medaka run`
and `medaka build` on ~20 programs. Probes live in
`scratchpad/probes/playground-wasm/`. Playwright e2e suite (`playground/e2e/run.sh`)
was run: ALL CHECKS PASSED (CM6 mount, highlighting, run, squiggles, hover,
completion, examples picker, share-link round-trip).

Playground pipeline used throughout:
```
node24 pg_compile.mjs user.mdk > out.wat   # compile.mjs seam, browser-identical vfs
wasm-tools parse out.wat -o out.wasm
node24 pg_run.mjs out.wasm                 # worker.js's exact import set + error semantics
```

## F1: Un-annotated tail recursion loses TCO in the wasm backend — stack overflow in the playground at ~5k depth
- Severity: high
- Class: crash (of user program) / run-build-divergence
- Launch blocker: yes — the first loop a newcomer writes dies in the browser
- Repro:
  ```
  loop acc n = if n == 0 then acc else loop (acc + n) (n - 1)
  main = println (loop 0 10000)
  ```
  $ (playground pipeline above)
  PGERROR: instantiate failed: Maximum call stack size exceeded
  Native `medaka build` prints 50005000; `medaka run` prints 50005000.
  Adding an explicit signature `loop : Int -> Int -> Int` makes the playground
  run fine even at n = 5,000,000.
- Expected: a self-tail-call should lower to `return_call` (constant stack) as
  the annotated version does; 10k iterations must not overflow.
- Hypothesis: without a signature the literals are Num-polymorphic; the emitted
  body wraps the tail call in a `disp_fromInt` dispatch block and emits plain
  `call $main__loop` + `return` (verified in the WAT: 0 `return_call $main__loop`),
  defeating the wasm TCO the diff_wasm gate asserts on annotated fixtures.

## F2: `medaka run` crashes with SIGBUS (Bus error: 10) on deep recursion — no error message
- Severity: critical
- Class: crash (of the medaka binary itself)
- Launch blocker: yes
- Repro:
  ```
  sumTo n = if n == 0 then 0 else n + sumTo (n - 1)
  main = println (sumTo 200000)
  ```
  $ $WT/medaka run p09_deeprec.mdk
  Bus error: 10   (exit 138, zero output)
  Also crashes on the TAIL-recursive `loop 0 5000000` (interpreter has no TCO).
  `medaka build` handles both (prints 20000100000 / 12500002500000).
- Expected: either complete (TCO for tail calls) or a clean "stack overflow /
  recursion too deep" runtime error; never a signal crash.
- Hypothesis: interpreter C-stack overflow, unguarded.

## F3: worker.js is missing host imports — prelude `stringToFloat` (and readFile/getEnv/args/exit) compile fine, then die with a cryptic LinkError in the browser
- Severity: high
- Class: crash / error-ux
- Launch blocker: yes for the stringToFloat case (pure prelude function)
- Repro:
  ```
  main =
    println (stringToFloat "3.25")
  ```
  $ (playground pipeline)
  PGERROR: instantiate failed: WebAssembly.instantiate(): Import #3 "env" "mdk_str_to_float": function import requires a callable
  Native build/run both print `Some 3.25`.
  Same failure shape for `readFile` (`Import #3 "env" "mdk_path_reset" ...`).
- Expected: `stringToFloat` should work in the browser (it needs only the
  str→float host shim, which `test/wasm/run.js` and compile.mjs already
  implement); genuinely-unavailable IO (readFile) should produce a clear
  "not available in the playground" message, not a raw LinkError.
- Hypothesis: `playground/worker.js` supplies only 4 env imports
  (write_byte, write_err_byte, float_fmt, float_fmt_byte); referencing
  stringToFloat makes the emitter import the whole path/read/args/exit group.

## F4: `import map` + `import set` together → 14 FALSE non-exhaustiveness warnings against stdlib set.mdk internals, shown to the user without file attribution
- Severity: high
- Class: silent-wrong (false diagnostics) / error-ux
- Launch blocker: yes (map+set is a natural combination; the console fills with scary stdlib warnings)
- Repro:
  ```
  import map
  import set
  main = println "hi"
  ```
  $ node24 pg_compile.mjs x_mapset.mdk   → ok:true + 14 W-NONEXHAUSTIVE-CLAUSES
  warnings for `./set.mdk`, e.g. "non-exhaustive clauses of 'size'. Missing
  case: 'Bin _ _ _ _ _'" — false (set.mdk's size handles Bin), several with
  dummy `{0,0}` ranges. Native `medaka check` on the identical file: clean.
  main.js `renderProblems` prints every file's diagnostics as
  `[warning] 61:3 non-exhaustive clauses of 'rotateL' ...` with NO filename, so
  they look like they're in the user's 3-line program.
- Expected: no false warnings; at minimum, warnings from bundled stdlib files
  should be suppressed or labeled with their file.
- Hypothesis: cross-module constructor-name collision (both map.mdk and set.mdk
  define `Bin`/`Tip`) in the playground's joint multi-module check path.

## F5: `import map.{...}` + `import set` breaks Map at RUNTIME in the interpreter — works in build and playground
- Severity: high
- Class: run-build-divergence / soundness (typechecks, then misapplies a value)
- Launch blocker: yes for the CLI story (playground is fine)
- Repro (5-line file):
  ```
  import map.{fromList, get}
  import set
  main =
    let m = fromList [(1, "one"), (2, "two"), (3, "three")]
    println (get 2 m)
  ```
  $ $WT/medaka run p11_map.mdk
  p11_map.mdk:117:30: runtime error [E-NOT-A-FUNCTION]: applied non-function: Bin 1 1 one Tip
  (location 117:30 is bogus — the file has 5 lines; it points inside a stdlib
  module but is attributed to the user's file)
  `medaka build` and the playground both print `Some two`.
- Expected: identical `Some two` everywhere.
- Hypothesis: interpreter cross-module `Bin`/`Tip` ctor collision (same root
  family as F4); plus wrong-file error attribution.

## F6: `deriving (Display)` on a record constructor works in build/playground but E-NONEXHAUSTIVE-MATCH in `medaka run`
- Severity: high
- Class: run-build-divergence
- Launch blocker: yes (records + deriving is early-tutorial material)
- Repro:
  ```
  data P = P { a : Int } deriving (Display)
  main = println (P { a = 1 })
  ```
  $ $WT/medaka run x_d1.mdk
  x_d1.mdk:2:24: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
  $ $WT/medaka build x_d1.mdk -o b && ./b   → `P 1`; playground → `P 1`.
  Same failure with deriving (Debug) + `debug`. Positional ctor
  (`data P = P Int deriving (Display)`) works everywhere.
- Expected: run == build.
- Hypothesis: interpreter's derived Display/Debug impl doesn't match
  record-syntax constructors.

## F7: `medaka run` loses stdout already produced before a runtime error
- Severity: medium
- Class: run-build-divergence / error-ux
- Launch blocker: no
- Repro:
  ```
  main =
    println "before"
    println (10 / 0)
  ```
  $ $WT/medaka run p03_divzero.mdk → stderr error only, stdout EMPTY (no "before")
  build and playground both print "before" then the E-DIV-ZERO error.
  Same on E-NONEXHAUSTIVE (p13) and E-PANIC probes.
- Expected: output produced before the panic must be flushed.
- Hypothesis: interpreter buffers stdout and skips the flush on the error exit path.

## F8: Parse errors inside `main`'s indented block are reported at 1:0 as "unexpected `main`" — playground squiggle lands on line 1
- Severity: medium
- Class: error-ux
- Launch blocker: no (but very visible: it's the first squiggle many users see)
- Repro (any of these):
  ```
  main =
    let mut total = 0
    for i in [1..=10]      -- Python-style loop attempt (line 3)
      total = total + i
    println total
  ```
  $ playground seam → single diagnostic: P-PARSE "unexpected `main`" range 0:0-0:1.
  Same for `println (2.0 ** 10.0)` on line 4 (points at 1:0), and for a layout
  mistake (`main =` with unindented body). Native check prints the same 1:0
  "unexpected `main`" caret.
- Expected: point at (or near) the offending token (`for`, `**`, the
  unindented line), with a hint. In the playground the squiggle on `main` line 1
  is actively misleading.
- Hypothesis: parser error recovery rewinds to the enclosing decl start.

## F9: `deriving Debug` without parentheses is a parse error with a useless message
- Severity: medium
- Class: error-ux / doc-mismatch-adjacent
- Launch blocker: no
- Repro:
  ```
  data P = P Int deriving Display
  main = println (P 1)
  ```
  $ $WT/medaka run x_d3.mdk
  x_d3.mdk:1:0: unexpected `data`
  (works with `deriving (Display)`)
- Expected: either accept the paren-less single-class form (Haskell habit,
  and `deriving Display` reads naturally) or say "expected '(' after deriving".
  "unexpected `data`" at the START of the very decl being parsed is baffling.

## F10: Playground compiler traps ("compiler trap: Maximum call stack size exceeded") on large-but-legal inputs that native handles
- Severity: medium
- Class: crash (of the in-browser compiler) / error-ux
- Launch blocker: no
- Repro (three shapes):
  - ~2000 top-level decls (`f0 x = x + 0` … + main): playground traps after
    ~20s; 1000 decls OK; native `medaka check` handles 3000 (in 24s).
  - 2000 nested parens `((((…1…))))`: trap.
  - 20,000-term `1 + 1 + …` single line: trap.
  Diagnostic returned: `{"message": "compiler trap: Maximum call stack size
  exceeded", range 0:0}` — no `code` field, dummy range, leaks "compiler trap".
- Expected: higher ceiling (or iterative front-end passes); a diagnostic with a
  code and a user-facing message ("program too large/deeply nested for the
  playground — try the native compiler").
- Hypothesis: recursive lexer/parser passes on the small worker/wasm stack.

## F11: No compile-side timeout in the browser (kill-timer covers RUN only) + typecheck is superlinear on operator chains
- Severity: medium
- Class: missing-feature / perf
- Launch blocker: no
- Repro: `main = println (1 + 1 + … )` with 1000 terms takes 13.7s through the
  playground seam (24s native `medaka check`; 2000 terms >60s native — killed).
  main.js sets `killTimer` only around the runner worker (`RUN_TIMEOUT_MS`,
  main.js:456); nothing bounds the compile worker, so a pathological paste
  pins the worker with no cancel and the status stuck on compiling.
- Expected: a compile-side watchdog (kill+recreate the compiler worker), and
  ideally non-quadratic checking of long chains.

## F12: `import math` / `import fs` in the playground → "unknown module: math" — misleading; no math library in the playground at all
- Severity: medium
- Class: error-ux / missing-feature
- Launch blocker: no (but `sqrt`-class functions missing from the flagship demo surface is a gap)
- Repro:
  ```
  import math
  main = println "x"
  ```
  $ playground seam → R-MODULE-LOAD "unknown module: math" (well-located).
  math/fs/net/time/io/test are deliberately excluded from EXTRA_MODULES
  (native-only externs), but the message claims the module doesn't exist.
- Expected: "module 'math' is not available in the browser playground
  (native-only); available modules: list, map, set, …". And consider a
  wasm-safe math subset — a playground user cannot compute a square root.

## F13: `readFile` diverges three ways: build silently reads the file, run panics "unbound identifier", playground LinkErrors
- Severity: medium
- Class: run-build-divergence / error-ux
- Launch blocker: no
- Repro:
  ```
  main =
    let s = readFile "/etc/passwd"
    println s
  ```
  - `medaka build` + run binary: prints the file (wrapped how Result displays).
  - `medaka run`: runtime error [E-PANIC]: unbound identifier: readFile
  - playground: PGERROR: instantiate failed: Import #3 "env" "mdk_path_reset" …
- Expected: one consistent story (capability error, or it works in both native
  modes); "unbound identifier" as an E-PANIC at runtime is the worst of the three.

## F14: `panic "msg"` as the final statement of main is a check error "Ambiguous instance for `Display`" at 1:0 — yet `medaka run` executes it
- Severity: low
- Class: error-ux / check-vs-run divergence
- Launch blocker: no
- Repro:
  ```
  main =
    println "pre"
    panic "boom"
  ```
  $ playground / medaka check → T-AMBIGUOUS-INSTANCE "Ambiguous instance for
  `Display`. Cannot determine which impl; add a type annotation" at 1:0 (dummy
  0:0 range in the playground squiggle).
  $ medaka run → prints the main-must-be-Unit warning, then runs and panics.
- Expected: `panic : String -> a` in statement position should unify with Unit
  (or the error should mention panic/the last statement, at its location).

## F15: Non-exhaustive-match warning range points at the last arm's body, not the match
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: p13 (`f n = match n` / arms 1,2) → W-NONEXHAUSTIVE range = line 3
  chars 7-12, i.e. the string literal `"two"` of the LAST arm. In the editor the
  squiggle underlines `"two"`, which has nothing wrong with it. Native and
  playground agree.
- Expected: range covering `match n` (or the whole match).

## F16: One mistake, two cascading diagnostics — `List.reverse` yields R-UNBOUND + T-UNKNOWN-FIELD "record '<unknown>'"
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `import list` + `println (List.reverse xs)` → playground JSON has BOTH
  "Unbound variable: List" and "Field 'reverse' does not belong to record
  '<unknown>'" on the same token (two stacked squiggles; the second leaks
  `<unknown>`). Native check shows both too.
- Expected: suppress the downstream field error once the receiver is unbound.
  Bonus: "Did you mean `import list.{reverse}`?" — dotted module access isn't a
  thing, and newcomers will type `List.reverse` / `String.toUpper` constantly
  (see F17).

## F17: Misleading did-you-mean suggestions steer newcomers wrong (`reverse`→'traverse', `String`→'RString')
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro:
  - `println (reverse xs)` with no import → "Unbound variable: reverse. Did you
    mean 'traverse'" — the right fix is `import list.{reverse}`.
  - `String.toUpper "hej"` → "Unbound variable: String. Did you mean 'RString'"
    — `RString` is an internal runtime name leaking into a beginner-facing hint.
- Expected: suggest the stdlib import when the name exists in a bundled module;
  never suggest internal `R*` names.

## F18: `medaka build` reports multi-module resolve errors at 1:0 (run reports correct locations)
- Severity: low
- Class: error-ux / run-build-divergence
- Launch blocker: no
- Repro: the pre-fix p11 (`import map` + bare `fromList`/`get`) →
  build: three errors all at `p11_map.mdk:1:0`; run: correct 4:10/5:11/6:10.
  (Single-module build errors ARE well-located, e.g. `head` at 3:11.)
- Expected: build == run locations.

## F19: `medaka run`/`build` hide type errors behind "error: type error in <file>. Run `medaka check` for details"
- Severity: low (CLI-area; noted here because the playground actually does better)
- Class: error-ux
- Repro: any type-erroring file, e.g. `length "héllo"` probe: run/build print
  one opaque line; the playground (and `medaka check`) shows the excellent
  located T-TYPE-MISMATCH with the toChars hint.
- Expected: run/build should print the diagnostics they already computed.

## Positive results (parity verified, worth keeping as fixtures)
- Byte-identical playground==build output on: hello, int arithmetic, float
  printing incl. `1e+12`/`1e-06`/`-0.0`/`inf`/`0.1+0.2`→`0.3` (fmt12g seam),
  string interpolation with multi-byte unicode (`wörld`, 🐟, 日本語), lists
  map/filter/fold/sum, records + update + deriving, ADTs + match, Option flows,
  `let mut` block reassignment, map.{fromList,get} usage, array.{fromList,get}
  OOB→None, runtime panics with coded messages (E-DIV-ZERO, E-NONEXHAUSTIVE-MATCH,
  E-PANIC) surfaced via the worker's stderr capture.
- 200,000-line output through the playground runner in ~0.5s, no truncation.
- All 3 embedded examples (hello/shapes/pipeline) byte-identical across
  run/build/playground.
- Playwright e2e suite green end-to-end (squiggles, hover, completion,
  examples picker, share permalink).
- Diagnostics JSON through the seam is complete for multi-error programs
  (2 errors both surfaced, with codes, help, and machine-applicable `fix`).
- Compiler-trap handling in compile.mjs at least degrades to a diagnostic
  rather than a hung worker.

## Suggested regression fixtures
1. `test/wasm/fixtures/`: un-annotated tail-recursive loop at depth 100k —
   asserts `return_call` on a Num-polymorphic self-call (F1).
2. Playground/worker import-completeness gate: emit WAT for a program using
   `stringToFloat`, assert every `(import "env" …)` is supplied by worker.js's
   glue (F3) — a static grep-level check would have caught this.
3. Multi-module check fixture importing BOTH map and set — assert zero
   warnings (F4) and (interpreter) `eval_modules` prints `Some two` (F5).
4. `deriving (Display)`/`(Debug)` on a record-syntax ctor through
   `medaka run` (diff_compiler_eval_modules or a doctest) (F6).
5. Interpreter deep-recursion guard: `sumTo 200000` under `medaka run` must
   produce a clean error, not SIGBUS (F2).
6. stdout-flush-on-panic: program printing then dividing by zero; `medaka run`
   stdout must contain the pre-panic line (F7).
7. Parse-error location: `for`-loop / `**` / unindented-body files asserting
   the diagnostic range is NOT line 0 (F8).
8. Playground seam smoke (CI-able, node-only): the 3 embedded examples +
   hello through pg pipeline == `medaka build` output (all currently pass —
   no automated gate runs the examples today).
9. Compile-seam robustness corpus: 2000 nested parens / 2000 decls / 20k-term
   chain — assert a coded diagnostic, no worker hang (F10/F11).
