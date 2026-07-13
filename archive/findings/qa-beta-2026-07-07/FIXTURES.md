# Regression fixtures to add — beta hardening, 2026-07-07

Merged from the 8 QA reports (`reports/*.md`; each report's own "Suggested regression
fixtures" section has extra per-area detail). Organized by harness. Two kinds:
- **[bug]** — locks a FINDINGS.md item: add red (or with the fix), cite the P-id.
- **[pin]** — behavior that works TODAY but has no coverage; add green now so it can't rot.

Priorities: P0 = playground-critical or crash-locking; P1 = first-day user surface;
P2 = completeness.

## 1. wasm gates — `test/wasm/fixtures*` (diff_wasm / diff_wasm_typed / diff_wasm_modules)
The playground runs this backend; it has ~0.4× llvm's fixture count and is missing whole
construct families. This is the single most important fixture batch for the beta.
- P0 [bug P0-7] un-annotated (Num-polymorphic) self-tail-call at depth 100k — assert
  `return_call` in the WAT / no stack overflow.
- P0 [pin] string interpolation: multi-hole, expression holes, triple-quoted, unicode
  (zero `\{` fixtures exist under test/wasm/ today).
- P0 [pin] runtime error paths on wasm: div-by-zero, mod-by-zero, non-exhaustive match,
  list/string index OOB — error-text parity with native (users WILL hit these in the
  playground).
- P0 [pin] dispatch parity sweep (fixtures_typed is 8 files vs llvm_typed's 88):
  superclass `requires` dispatch, default methods, named instances + `@hints`,
  conditional impls (`impl Eq (List a) requires Eq a`), user-monad `do`,
  `deriving (Eq, Ord, Debug)`, Foldable/Traversable, return-position `pure`.
- P1 [pin] stdlib-on-wasm: map/set incl. literals, json roundtrip, mut_array push loop.
- P1 [pin] construct parity: `do` over Option/Result, sections/pipe/compose, record
  rest-pattern, char-range pattern, if-let/let-else, `function` keyword, backtick infix.
- P2 [bug P1-1] 63-bit int boundary parity fixture.

## 2. playground seam gates — NEW (node-only, CI-able; see reports/playground-wasm.md)
- P0 [pin] pipeline smoke: the 3 embedded examples + hello through
  compile.mjs → wat2wasm → worker-glue == `medaka build` output. (All pass today;
  nothing automated runs the examples.)
- P0 [bug P0-8] worker-import completeness: for a corpus including `stringToFloat`,
  assert every `(import "env" …)` in emitted WAT is supplied by worker.js's glue —
  a static grep-level gate would have caught F3.
- P0 [bug P0-9] `import map` + `import set` through the seam → assert zero diagnostics.
- P1 [bug P1-14] robustness corpus: 2000 nested parens / 2000 decls / 20k-term chain →
  assert a coded diagnostic, no hang; plus a compile-side timeout test once added.
- P1 [bug P1-13] `import math` through the seam → assert the friendly not-in-playground
  message once it exists.

## 3. run-vs-check/build agreement gate — NEW harness (highest-value new gate)
For each fixture: assert `medaka run` exits nonzero **iff** `medaka check` does, and
that build/run outputs match when green. Seed corpus:
- P0 [bug P0-1] `1 + "a"`, `1 == "a"`, `[1,"a"]`, if-branch mismatch, `f == g`,
  `Ref == Ref`, wrong annotation, overlapping impls, missing superclass,
  else-less non-Unit if (`f x = if x > 0 then x`).
- P0 [bug P0-18] the inverse pair: standalone-fn+method name collision; Map with
  function keys (check must report what run refuses).
- P0 [bug P0-17] impl missing a method → check errors.
- P0 [bug P0-5] non-mut reassign (local, param, pattern-bound, type-changing);
  top-level reassign; `mut` branch-write (run value == build value, no emitter panic).
- P0 [bug P0-4] positional record-ctor pattern `Person _ _` under run.
- P0 [bug P0-3] deriving matrix: {record-block, data-record, data-positional} ×
  {Display, Debug, Eq, Ord} × {run, build} — currently 3 of these cells crash.
- P0 [bug P0-2] failing refutable `let` through a function: native == E-LET-REFUTE,
  not SIGSEGV; `xs = 1 :: xs` → diagnostic, not segfault (both engines);
  `sum [1..=100000]` under run → answer or clean overflow error, never SIGBUS.
- P0 [bug P0-10] hash_map/hash_set set+get under `medaka run`.
- P0 [bug P0-14] `export import` 3-file re-export under build.
- P1 [bug P1-5] guarded-clause fallthrough: native must be E-NONEXHAUSTIVE-MATCH (not
  E-INDEX-OOB); interpreter clause-miss must not say "no matching impl for dispatch".
- P1 [bug P1-6] readLine/args/getEnv/readFile: run parity with build (or the documented
  native-only error).
- P1 [bug P1-12] stdout-flush: print-then-divide-by-zero; run's stdout contains the line.
- P2 [bug P2-3] impl-for-type-alias: check accepts iff run dispatches.

## 4. build-path diagnostics gate — NEW small harness (peer of diff_compiler_check.sh)
- P0 [bug P1-10] for ~5 error-bearing multi-module programs, assert `medaka build`
  stderr == `medaka check` stderr (locks the all-at-1:0 collapse — currently un-gateable).

## 5. parse/lex negative tests — `test/parse_error_fixtures/` + `test/error_quality_fixtures/`
(17 negative vs 288 positive fixtures today; rebalance.)
- P0 [bug P0-11] parse-error location corpus: `let type = 5` in a body, `x += 1`,
  or-pattern, `-1` literal pattern, split `let…in`, `for` loop, anonymous record,
  `f (x : String)` — each asserting the diagnostic range is NOT the decl head/line 0.
- P1 [bug P1-9] hint-family goldens as hints land: `#`/`//` comments, `elif`, `lambda`,
  `and`/`or`, `xs[0]`, `===`, tuple-call `add(1, 2)`, `String.toUpper`, anonymous record.
- P1 [pin] existing model hints so wording never regresses: `def`, `for`, `return`,
  `\x ->`, `::`, `show`, `true`, `;`, `case…of`, `/=`, `Maybe`→`Option`, main-must-be-
  a-value message.
- P1 [pin] unterminated triple-quoted string; unterminated interp hole `"\{x"`;
  comment-as-first-line-of-block; mixed tab/space (assert a layout diagnostic once
  fixed); BOM file.
- P2 [bug P1-2] scientific-notation literals `1e12`/`1e-05`/`5.0e-324` — golden errors
  now, value goldens once supported; plus print-then-reparse round-trip fixture.
- P2 [bug P1-1] out-of-range int literal at 2^62−1 / 2^62 / 2^63−1.

## 6. typecheck negative tests — `test/check_*_fixtures/`
- P0 [bug P0-17] impl completeness (missing method).
- P1 [bug P2-1] duplicate record-literal field; unknown deriving interface; user
  `impl Eq Int` overlap-with-prelude; mixed-arity clauses (arity message); duplicate
  function clause (unreachable warning); signature-without-definition.
- P1 [bug P1-10] located-diagnostic asserts: prelude-type collision (`data Option…`),
  recursive alias, method-not-in-interface, overlap, missing-superclass — file:line
  present, not `<unknown location>`.
- P2 [bug P2-2] ill-kinded impl (`impl Mappable Int`) → kind error, no `Int Int` leak.
- P2 [pin] occurs-check trio (`f x = f`, `x => x x`, `f x = f [x]`); Ref
  value-restriction pair; ambiguous shared-field suggestion.

## 7. tooling gates — repl / test / fmt / doc / new / CLI
- P0 [bug P0-6] failing doctest AND failing prop → `medaka test` exit != 0.
- P0 [bug P0-12] REPL pipe-script: lex error then parse error then a valid line —
  session survives, last line evaluates; `import list.{reverse}` then `reverse [1,2]`
  → `[2, 1]`.
- P1 [bug P0-13] cwd-independence: src/main.mdk + src/helper.mdk run from project root
  and via absolute path from elsewhere.
- P1 [bug P1-15] doctest robustness: panicking example reported as one FAIL with
  file:line, rest of the suite still runs; `>`-on-`{- |`-line either found or warned.
- P1 [bug P2-7] `fmt --check <dir>` with one unformatted file → exit 1; unknown
  subcommand → did-you-mean; `--version` exists; missing-file message parity across
  run/check/build; `medaka test` no-arg exits nonzero.
- P1 [pin] `medaka new` scaffold → run+build+test all green end-to-end.
- P2 [pin] fmt idempotence + run-before==run-after on a weird-but-valid corpus;
  `check --json` golden for a clean file; `check` output newline-terminated.
- P2 [bug P2-8] REPL/doc constraint display (`:type map` shows `Mappable c =>`).

## 8. doctest gate — stdlib coverage
- P1 [pin] gate the 9 passing-but-ungated suites: math, time, option, result, hex,
  base64, path, nonempty, validation (all verified green natively today).
- P1 [pin] un-defer map / array / mut_array — the gate's deferral notes are stale;
  all three verified green end-to-end.
- P2 [bug P0-10] hash_map/hash_set: fixture once the interpreter hashInt/hashString
  panic is fixed (or expected-error fixtures meanwhile).
- P2 fs/io/net: add 2–3 pure-path doctests each (path math, `lines`) — currently zero.

## 9. eval/interp fixtures — `test/eval_*` + diff_compiler_eval_modules
- P0 [bug P0-9] `import map` + `import set` jointly, Map lookup → `Some two` through
  eval_modules (ctor-collision lock).
- P0 [bug P0-3] record-form deriving under run (pairs with the build-side fixture).
- P1 [bug P1-16] `map = 99` value-shadow of a prelude method — pin whichever semantics
  is chosen.
- P1 [pin] mut-closure snapshot semantics (run==build — currently the one consistent
  mut behavior); Ref/setRef/.value counter; top-level lazy binding evaluated exactly
  once (run==build).
- P2 [bug P2-5] triple-quoted interp-hole-with-spaces byte golden; nested-string-in-hole
  located error.

## 10. numerics/runtime pins
- P1 [pin] unicode codepoint semantics (length/reverse/slice/index on emoji+CJK+
  combining), run==build — works today, apparently untested.
- P1 [bug P1-3] float Debug round-trip: `debug (0.1+0.2) != debug 0.3`.
- P1 [bug P1-4] perf smoke gates (time-bounded): native `println [1..=100000]` < 2 s;
  interp `sum [1..=100000]` < 5 s.
- P2 [bug P1-11] NaN-as-Map-key behavior once Ord Float total order is decided.
- P2 [pin] hex/binary/octal/underscore literals; Num-poly literal mixing (`1 + 1.5`);
  reversed/empty ranges; slice clamping; `f -1` ≡ `f (-1)`.

## Doc fixes (cheap, pre-launch — from gap-analysis + bindings reports)
- SYNTAX.md: attributes section shows the broken signature-less shape (P0-15) —
  document the signature requirement until fixed.
- SYNTAX.md: Refs example uses nonexistent `set_ref`; document `setRef` + `.value`.
- SYNTAX.md: Map/Set literals need `import map.*`/`import set.*`.
- SYNTAX.md: header still cites deleted OCaml paths (`lib/parser.mly`) as ground truth.
- README/SYNTAX.md: document Int = 63-bit tagged; negative `/`/`%` conventions.
- SYNTAX.md: drop or implement `bench` ("Tests & benchmarks" documents dead syntax).
