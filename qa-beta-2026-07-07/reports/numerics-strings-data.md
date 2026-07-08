# Findings: numerics-strings-data

Area charter: runtime value semantics — numbers, strings, collections.
All probes live in `/private/tmp/claude-501/-Users-val-medaka/07db78cb-7807-4285-bb67-639494a218d2/scratchpad/probes/nsd/`.
`$WT` = /Users/val/medaka/.claude/worktrees/virtual-fluttering-meteor. Every finding reproduced at least twice.

## F1: `record`-block `deriving` is broken in the native backend (crashes binary or the emitter itself)
- Severity: critical
- Class: run-build-divergence / crash
- Launch blocker: yes
- Repro (a — derived Display: native binary panics, interpreter fine):
  ```
  record Person
    name : String
    age : Int
    deriving (Display)

  main = println (Person { name = "Al", age = 30 })
  ```
  `$ medaka run recdisp.mdk` → `Person { name = Al, age = 30 }` (exit 0)
  `$ medaka build recdisp.mdk -o recdisp.out && ./recdisp.out` → `runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match` (exit 1)
- Repro (b — derived Debug: the EMITTER panics during `build`):
  ```
  record Person
    name : String
    age : Int
    deriving (Debug)

  main = println (debug (Person { name = "Al", age = 30 }))
  ```
  `$ medaka build recdisp2.mdk -o out` →
  `error: emitter failed compiling recdisp2.mdk` / `runtime error [E-PANIC]: no impl of method 'debug' for type 'recdisp2__Person' (slice 6)`
  (`medaka run` prints `Person { name = "Al", age = 30 }` fine.)
- Repro (c — derived Eq: emitter panics the same way): `record P` + `deriving (Eq)` + `println (P { x = 1 } == P { x = 1 })` → run prints `True`; build: `E-PANIC: no impl of method 'eq' for type 'receq__P' (slice 6)`.
- Expected: derived instances on `record`-block declarations compile natively (they already work for `data ... = C { ... } deriving (...)`).
- Hypothesis: the emitter's deriving machinery doesn't see record-block-form decls, only `data`-form.
- Note: also inconsistent Display formats — record-block derived Display prints `Person { name = Al, age = 30 }` while `data Person = Person {...} deriving (Display)` prints positional `Person Al 30`.

## F2: `medaka run` skips typeclass-obligation errors that `check`/`build` report (Eq/Display on functions, Refs)
- Severity: critical
- Class: run-build-divergence / soundness
- Launch blocker: yes
- Repro (a):
  ```
  f x = x + 1
  g x = x + 2
  main = println (f == g)
  ```
  `$ medaka run eqfn.mdk` → `False` (exit 0!)
  `$ medaka check eqfn.mdk` → `No impl of Eq for (Int -> Int)` (exit 1); `build` rejects identically.
- Repro (b): `compare f f` under `run` → prints `Eq`. (Comparing functions "succeeds".)
- Repro (c):
  ```
  a = Ref 1
  b = Ref 1
  main =
    println (a == b)
    println (a == a)
  ```
  `run` → `True` / `True`; `check` → `No impl of Eq for Ref Int`.
- Repro (d):
  ```
  f x = x + 1
  main = println "fn: \{f}"
  ```
  `run` → executes, then panics `runtime error [E-PANIC]: intToString: not an Int` (no location); `check`/`build` → `No impl of Display for (Int -> Int)`.
- Expected: `run` and `check` agree; a program `check` rejects must not execute under `run`.
- Hypothesis: run's typecheck path defaults/ignores unresolved constraints in `main`'s body that check's path reports.

## F3: Inverse divergence — `run` reports "type error, run `medaka check`" but `medaka check` reports NO error
- Severity: high
- Class: error-ux / run-build-divergence
- Launch blocker: yes
- Repro:
  ```
  import map.{Map, get}

  f x = x + 1
  m = Map { f => 1 }
  main = println (get f m)
  ```
  `$ medaka run mapfn.mdk` → `error: type error in mapfn.mdk. Run `medaka check` for details` (exit 1)
  `$ medaka check mapfn.mdk` → prints signatures (`m : Map (Int -> Int) Int`), exit 0; `--json` shows zero diagnostics.
- Expected: `check` reports the missing `Ord (Int -> Int)` obligation (or run succeeds). Telling the user to run `check` and having `check` say all-clear is a dead end.
- Hypothesis: constraint from Map-literal desugar (`fromList : Ord k => ...`) is checked in run's whole-program pipeline but deferred/dropped by check's per-decl pipeline.

## F4: Interpreter cannot run `hash_map` mutation at all — panics `unbound identifier: hashString`; native works
- Severity: critical
- Class: run-build-divergence / crash
- Launch blocker: yes
- Repro:
  ```
  import hash_map.{new, set, get}

  main =
    let m = new ()
    set "a" 1 m
    println (get "a" m)
  ```
  `$ medaka run hm2.mdk` → `runtime error [E-PANIC]: unbound identifier: hashString` (exit 1, no source location)
  `$ medaka build hm2.mdk -o hm2.out && ./hm2.out` → `Some 1` (exit 0)
- Expected: stdlib hash_map works under the interpreter (or at minimum a located error).
- Hypothesis: `hashString` helper/extern not registered in the interpreter's environment (eval-only gap).

## F5: Scientific-notation float literals don't parse, yet the printer EMITS that notation (output not round-trippable) — with absurd error messages
- Severity: high
- Class: missing-feature / error-ux / doc-mismatch (known-OPEN per memory, but now printer-asymmetric)
- Launch blocker: yes (playground copy-paste of program output fails)
- Repro:
  ```
  main = println 0.00001
  ```
  → prints `1e-05`. Now feed that back:
  `main = println (1e-05)` → `runtime error [E-NOT-A-FUNCTION]: applied non-function: 1`
  `main = println 1.0e12` → `Unbound variable: e12`
  `main = println (5.0e-324)` → `This expression has type Float, which is not a function...` (it lexed `5.0e-3` then applied it to `24`)
  `main = println 1.5e3` → `Unbound variable: e3`
  Large-magnitude printing has the same asymmetry: `println 123456789012345.0` → `1.23456789012e+14` (also unparseable).
- Expected: either accept `NeM`/`Ne-M` literals, or never print in a notation the language cannot read. Error should at least say "scientific-notation float literals are not supported".
- Hypothesis: lexer splits `1.0e12` into float + identifier; some `Ne-M` forms even reach the runtime.

## F6: Float printing truncates to ~12 significant digits — `debug` is lossy and misleading
- Severity: high
- Class: silent-wrong
- Launch blocker: no (but embarrassing for a numerics demo)
- Repro:
  ```
  main =
    println (0.1 + 0.2 == 0.3)
    println (debug (0.1 + 0.2))
    println (debug 0.3)
    println 123456789012345.0
  ```
  → `False` / `0.3` / `0.3` / `1.23456789012e+14` (run and build identical)
- Expected: `debug` output round-trips (shortest-round-trip printing, like every modern language): `0.30000000000000004`, `123456789012345.0`. Two unequal floats must not Debug-print identically. `123456789012345.0` silently loses the last 3 digits.
- Hypothesis: floatToString uses `%.12g`-style formatting.

## F7: Int literals overflow silently at the 62-bit tagged boundary (no diagnostic, garbage values)
- Severity: high
- Class: silent-wrong
- Launch blocker: no (document + diagnose literals at minimum)
- Repro:
  ```
  main =
    println 4611686018427387903
    println (4611686018427387903 + 1)
    println 9223372036854775807
    println 99999999999999999999999999
  ```
  → `4611686018427387903` / `-4611686018427387904` / `-1` / `-2537764290115403777` (run == build)
- Expected: at least out-of-range LITERALS are a compile error (the user typed a number the language cannot represent; `9223372036854775807` printing `-1` is indistinguishable from a bug in their program). Arithmetic wraparound at 2^62 should be documented (Int is 62-bit, not 64-bit — nothing user-facing says so).
- Related: `negate minInt` silently returns `minInt`; `floatToInt` on out-of-range/inf returns `-1` and on NaN returns `0` (silent garbage, run == build).

## F8: `println` of a large list is quadratic — hangs even the NATIVE binary (playground killer)
- Severity: high
- Class: silent-wrong (perf cliff)
- Launch blocker: yes for playground defaults
- Repro:
  ```
  main = println [1..=1000000]
  ```
  `$ medaka build bigprint.mdk -o out && ./out > /dev/null` → no output after 2 minutes (killed).
  Scaling (native, output to /dev/null): n=10k → 0.16 s; n=50k → 4.9 s; n=100k → 21 s user (≈ O(n²)).
- Expected: printing a 1M-element list takes ~a second (linear string building).
- Hypothesis: Display for lists builds the string by repeated `++` concatenation.

## F9: `[lo..=hi]` range construction is quadratic in the interpreter (100k elements ≈ 48 s; 1M = many minutes)
- Severity: high
- Class: silent-wrong (perf cliff)
- Launch blocker: no (native is fine: `sum [1..=1000000]` = 0.06 s)
- Repro:
  ```
  main = println (sum [1..=100000])
  ```
  `$ medaka run bigsum2.mdk` → 47.8 s. `length [1..=100000]` alone: 48 s. n=10000: 0.7 s (≈ O(n²) scaling). `sum [1..=1000000]` under `run`: >2 min (killed).
- Expected: linear range construction; a newcomer's first loop-over-a-range experiment should not appear to hang `medaka run`.

## F10: Self-referential value binding (`xs = 1 :: xs`) typechecks then SEGFAULTS both interpreter and native, with no message
- Severity: high
- Class: crash
- Launch blocker: yes (crashes the `medaka` binary itself under `run`)
- Repro:
  ```
  import list.{take}

  xs = 1 :: xs
  main = println (take 3 xs)
  ```
  `$ medaka run inflist.mdk` → no output, exit 138 (signal). `$ medaka check` → happily reports `xs : List Int`. Native build → exit 139 (SIGSEGV), no output.
- Expected: either a "cyclic value definition" diagnostic, or lazy semantics that make `take 3 xs` work, or at minimum a stack-overflow runtime error message — not a silent signal death.

## F11: Triple-quoted string: an interpolation hole containing spaces eats the following newline + indentation
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro:
  ```
  b = """x \{1 + 1}
    indented"""
  main = println b
  ```
  → prints `x 2indented` (one line). Expected `x 2\n  indented`. With a space-free hole (`\{1}`) the newline is preserved correctly. run == build (both wrong).
- Hypothesis: lexer's triple-quoted interp-hole scanner treats whitespace-bearing holes via a path that swallows trailing layout.

## F12: Nested string literal inside an interpolation hole: "unterminated string literal" pointing past EOF
- Severity: medium
- Class: error-ux / missing-feature
- Launch blocker: no
- Repro:
  ```
  x = 5
  main = println "\{"inner \{x}"}"
  ```
  `$ medaka run nested.mdk` →
  `nested.mdk:3:0: unterminated string literal` (points at empty line 3, col 0)
  Variant: `"\{if x > 3 then "big" else "small"}"` inside a 2-statement main gives `unexpected '\'. Medaka lambdas are written 'x => e' (not '\x -> e')` — wildly misleading. (Oddly the same if-with-strings interp WORKS as a single-statement `main = println "..."` — so acceptance depends on context.)
  An unclosed hole (`"hello \{x"`) gives the same past-EOF "unterminated string literal".
- Expected: nested strings in holes either work or error at the hole with a message about interpolation; consistent acceptance regardless of surrounding statements.

## F13: Empty interpolation hole / multiline construct in hole: "unexpected a string"
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro:
  `main = println "empty: \{}"` → `unexpected a string` (ungrammatical, no hint the hole is empty). Same "unexpected a string" for a multiline `match` inside a hole.
- Expected: "empty interpolation hole — write an expression between \{ and }" (and grammatical article handling).

## F14: NaN Map keys silently corrupt the map (`compare nan x` = `Eq` for every x)
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro:
  ```
  import map.{Map, get, toList, set}

  nan = 0.0 / 0.0
  m = Map { nan => 1.0, 2.0 => 2.0 }
  main =
    println (get nan m)
    println (get 2.0 m)
    println (toList (set nan 9.0 m))
  ```
  → `Some 2.0` / `Some 2.0` / `[(nan, 9.0)]` (run == build). The two-entry literal collapsed to ONE entry; looking up NaN returns 2.0's value; setting NaN overwrote the 2.0 entry.
  Root observation: `compare nan 1.0` → `Eq`; `nan < 1.0`, `nan > 1.0`, `nan == nan` all `False`; `sortBy compare` leaves NaN wherever (`[1.0, 2.0, 3.0, nan]`).
- Expected: a total order for the Ord Float impl (NaN sorted consistently, e.g. last), or documentation warning that NaN keys are UB. `compare` returning `Eq` for incomparables makes every ordered collection silently wrong.

## F15: Missing-file error UX: three different messages, two of them bad
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `$ medaka run nonexistent.mdk` → `unknown module: nonexistent` (misleading — it's a missing file, not a module problem). `$ medaka check nonexistent.mdk` → bare `No such file or directory` (no filename). `$ medaka build nonexistent.mdk -o x` → `error: no such file: nonexistent.mdk` (good).
- Expected: all three subcommands use build's message.

## F16: Native runtime errors lose the source location the interpreter shows
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `main = println (1 / 0)`.
  run: `divzero.mdk:1:20: runtime error [E-DIV-ZERO]: division by zero`.
  build: `runtime error [E-DIV-ZERO]: division by zero` (no file/line). Similarly native OOB says `index out of bounds` while interp says `index 5 out of bounds` (drops the offending index).
- Expected: parity where cheap (at least the index value).

## F17: Map/Set literals fail with "Unknown type: Map" unless you import the type — SYNTAX.md doesn't say so
- Severity: low
- Class: doc-mismatch / error-ux
- Launch blocker: no
- Repro: `main = println (Set { 1, 2, 3 })` (no imports) → `Unknown type: Set`. SYNTAX.md's "Map / Set literals" section shows the literals with no import. Works after `import map.{Map}` / `import set.{Set}`.
- Expected: error carries a help line ("add `import set`"), and/or SYNTAX.md notes the import requirement.

## F18: Qualified module access (`map.toList`) after selective import: unlocated all-caps jargon errors
- Severity: low
- Class: error-ux
- Repro: `import map.{Map, get}` then call `map.toList m` →
  `TYPE ERROR: Field 'toList' does not belong to record '<unknown>'` + `TYPE ERROR: Ambiguous instance for `Mappable`. Cannot determine which impl; add a type annotation` — no file/line/caret on either, `<unknown>` leaking, and the real problem (module-qualified access isn't a thing / name not imported) is never stated.
- Expected: located diagnostic: "'map.toList' — module members are accessed via import; add `toList` to the import list".

## F19: `head`/`sort` unbound with no import hint (prelude/stdlib discoverability)
- Severity: low
- Class: error-ux / missing-feature
- Repro: `main = println (head [])` → `Unbound variable: head`. `sort [...]` → `Unbound variable: sort. Did you mean 'sqrt'` (typo suggestion actively misleads). Both exist in `stdlib/list.mdk`.
- Expected: suggestion should include "found in module `list` — add `import list.{head}`".
- Also: no `minInt`/`maxInt` constants exist (`Unbound variable: minInt`) despite wrap-at-2^62 semantics (F7) making them useful.

## Notes / non-findings verified
- Known -0.0 divergence reproduced exactly as documented: `println (-0.0)` → run `0.0`, build `-0.0` (already deferred; not re-filed).
- Int `/`/`%` on negatives: truncated division, remainder takes sign of dividend (`-7 / 3 = -2`, `-7 % 3 = -1`) — C-like, consistent run/build; just needs docs.
- `1 / 0` → `E-DIV-ZERO`, `1 % 0` → `E-MOD-ZERO` with location under run: good UX.
- Char range `['a'..='e']` in EXPRESSION position is a type error (`Type mismatch: Char vs Int`) — patterns-only per SYNTAX.md, but the message doesn't say ranges are Int-only in expressions (borderline UX).

## Positive surprises (worth regression fixtures)
- Unicode strings are cleanly codepoint-based and run==build: `stringLength "👋🌍"` = 2, `"日本語"` reverse/slice/index all correct, `"e\u{301}"` = 2 codepoints.
- Hex/binary/octal/underscore literals all work (`0xFF`, `0b1010`, `0o17`, `1_000_000`).
- Num-polymorphic literals: `1 + 1.5` = `2.5` (Int literal adapts to Float context).
- Reversed/empty ranges are sane: `[10..=1]`, `[1..1]`, `[5..5]` → `[]`; `[3..=3]` → `[3]` (run == build).
- `nan`/`inf`/`-inf` print consistently in run and build.
- String/array slices clamp gracefully (`slice 0 100 "abc"` = `"abc"`, `"abcdef".[4..99]` = `"ef"`).
- Invalid string escape `\q` gives a model located error with caret.
- Debug vs Display distinction correct for strings/chars: `println "x"` bare, `debug "x\n"` quoted+escaped.

## Suggested regression fixtures
1. `record`-block + `deriving (Eq|Debug|Display|Ord)` → build AND run goldens (F1) — currently only `data`-form deriving is exercised natively.
2. run-vs-check agreement sweep: `f == g`, `compare f f`, `Ref eq`, Display-of-function in interp holes (F2) — assert `run` exits nonzero exactly when `check` does.
3. Map-literal with non-Ord key: `check` must error (F3).
4. hash_map insert/get/delete driven through `medaka run` (F4) — interpreter currently has zero coverage of `hashString`.
5. Scientific-notation literals: `1e5`, `1.5e3`, `1e-05`, `5.0e-324` — golden errors today, value goldens once supported; plus round-trip fixture `println x` output must re-parse (F5).
6. Float Debug round-trip: `debug (0.1+0.2) != debug 0.3` (F6).
7. Int-literal overflow diagnostics at 2^62−1 / 2^62 / 2^63−1 (F7).
8. Perf smoke-gates (time-bounded): native `println [1..=100000]` < 2 s (F8); interp `sum [1..=100000]` < 5 s (F9).
9. `xs = 1 :: xs` → must not segfault (F10).
10. Triple-quoted interp hole with spaces followed by indented line — exact byte golden (F11).
11. Nested-string-in-hole and unclosed-hole lexer errors: located at the hole, not EOF (F12).
12. NaN as Map/Set key behavior lock-in once Ord Float total order is decided (F14).
13. Unicode codepoint semantics (currently working, apparently untested): length/reverse/slice/index on emoji+CJK+combining, run==build.
14. Missing-file message parity across run/check/build (F15).
