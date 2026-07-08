# Test-gap analysis (area: test-gap-analysis)

Method: read SYNTAX.md fully; surveyed all `test/` fixture dirs (counts + names + sampled
contents); cross-referenced every SYNTAX.md construct and every `stdlib/*.mdk` module against
parse / check / eval / llvm-build / wasm coverage; spot-probed ~12 suspicious gaps on the binary.
Probes live in `scratchpad/probes/gap/`.

## Coverage map (summary)

Fixture volume per stage: parse 288 (+287 construct) | typecheck 42 pos + 66 err + 14 panic +
36 exhaust | eval 69 + 18 runtime-err | llvm 388 + 88 typed + 14 modules + build_diff ~60 +
construct-coverage 287 | **wasm 155 + 8 typed + 31 modules** | error-quality corpus ~40 graded |
lint 48, fmt 62, lsp, repl, doc, new all gated.

Well-covered everywhere: literals, arithmetic/comparison, closures/HOF/partial app, ADTs +
match (ctor/tuple/cons/as/wildcard/guards), records (construct/update/pun), let/mut/refs,
guards + where, strings/chars/unicode, arrays, ranges, TRMC/deep recursion, effects (dedicated
effect_* domains), multi-module resolve/check/eval, interfaces+dispatch (llvm_typed: 88).

Thin/absent (details + probe results below):
- **wasm backend** is the weak stage across the board — the playground's backend has ~0.4x the
  fixture count of llvm and is missing entire construct families (see fixtures list).
- **Negative-test balance**: 288 positive parse fixtures vs 17 parse_error fixtures; import
  errors = 1 fixture; zero fixtures compare `build`-path diagnostics against `check`-path.
- **Attributes, `bench`, `export import`** — parse-only coverage, and all three are broken or
  dead beyond the parser (findings F1, F2, F4).
- **stdlib doctests**: 13 modules' doctest suites pass today but are gated for only ~9 modules;
  fs/io/net have no doctests at all; hash_map/hash_set panic under `medaka test`.

---

## F1: Any attribute on a signature-less definition silently unbinds it
- Severity: high
- Class: silent-wrong + doc-mismatch
- Launch blocker: yes (SYNTAX.md's own example is the failing shape)
- Repro:
  ```
  @inline
  f x = x + 1
  main = println (f 3)
  ```
  `$ medaka run attr_nosig.mdk` →
  `attr_nosig.mdk:3:16: Unbound variable: f`
  Same for `@deprecated "use bar"` and `@must_use`. With a type signature between the
  attribute and the definition (`@inline` / `f : Int -> Int` / `f x = ...`) it works —
  which is why the single existing fixture (`construct_fixtures/attr_inline.mdk`) is green.
- Expected: attributed decl stays bound (SYNTAX.md shows `@inline` directly above `foo x = x`).
- Hypothesis: parser/desugar attaches the attribute by consuming the following decl and drops
  it when there's no signature to anchor to.

## F2: `export import` re-export works in `run`, panics the emitter in `build`
- Severity: high
- Class: run-build-divergence (+ compiler panic leaking to user)
- Launch blocker: yes
- Repro: three files —
  `base.mdk`: `export` / `double x = x * 2`; `mid.mdk`: `export import base.{double}`;
  `main.mdk`: `import mid.{double}` / `main = println (double 21)`
  `$ medaka run main.mdk` → `42`
  `$ medaka build main.mdk -o out` →
  `error: emitter failed compiling .../main.mdk`
  `runtime error [E-PANIC]: unbound variable 'double' (not a local, ctor, or known fn)`
- Expected: build == run. Reproduced twice.
- Hypothesis: emitter's module loader doesn't chase re-exported names through `export import`.
- Coverage note: `export import` has exactly one parse fixture; no eval/build/wasm fixture.

## F3: Multi-module `medaka build` type errors lose their locations (all `1:0`, no caret)
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro: any error-bearing file that has an `import` —
  ```
  import map
  m = Map { "a" => 1 }
  main = println (lookup "a" m)
  ```
  `$ medaka check f.mdk` → `f.mdk:3:4: Unknown type: Map` … (correct lines/cols + carets)
  `$ medaka build f.mdk -o out` → `f.mdk:1:0: Unknown type: Map` … (every diagnostic at 1:0,
  no caret/snippet). Single-file builds report correctly.
- Expected: build-path diagnostics identical to check-path.
- Coverage note: no gate compares build vs check diagnostics — this class can't regress-fail today.

## F4: `bench "name" = expr` parses but nothing ever runs it
- Severity: low
- Class: missing-feature (dead syntax documented in SYNTAX.md)
- Launch blocker: no
- Repro: `bench "identity" = 42` + `main = println "ok"`;
  `$ medaka test bench.mdk` → `(no doctests found)`, exit 0. No subcommand runs benches.
- Expected: either a bench runner or drop it from SYNTAX.md ("Tests & benchmarks" section).
- Coverage note: zero fixtures anywhere contain `bench`.

## F5: `medaka test stdlib/hash_map.mdk` panics
- Severity: medium
- Class: crash (user-facing panic from a stock stdlib module)
- Launch blocker: no (but ugly for a preview: users will `medaka test` stdlib files)
- Repro: `$ medaka test stdlib/hash_map.mdk` →
  `runtime error [E-PANIC]: unbound identifier: hashInt` (same for hash_set.mdk).
- Expected: clean report (or a clean "unsupported" message). Known-deferred in the gate
  comments, but the deferral note doesn't say it *panics*.

## F6: Int literals beyond 62 bits silently wrap — Int is 63-bit, undocumented
- Severity: medium
- Class: silent-wrong / doc-mismatch
- Launch blocker: no
- Repro:
  ```
  main =
    println 4611686018427387903      -- 2^62-1: prints itself
    println (4611686018427387903 + 1) -- prints -4611686018427387904
    println 9223372036854775807       -- prints -1 (!)
  ```
  Same output on `run` and `build` (consistent). No lexer/typecheck diagnostic for a literal
  that doesn't fit.
- Expected: at minimum a lex/typecheck error for out-of-range literals; docs stating Int is 63-bit.
- Coverage note: only `wasm/fixtures/w_int64_boundary.mdk` touches boundaries; no native fixture.

## F7: Map/Set literal requires `import map.*` — bare `import map` gives "Unknown type: Map"
- Severity: low
- Class: error-ux / doc-mismatch
- Launch blocker: no
- Repro: `import map` + `m = Map { "a" => 1 }` → `Unknown type: Map`. Works with `import map.*`.
  SYNTAX.md's Map/Set-literal section doesn't mention the import requirement at all.
- Expected: SYNTAX.md note + a "did you mean `import map.*`" style help.

## F8 (aggregated error-UX notes seen while probing)
- `Duplicate interface: Monoid` and `Method 'x' is not part of interface 'Y'` print
  `<unknown location>` (no file/line) — hit immediately when a user redefines a prelude
  interface name (`Monoid`, `Applicative`...). Class: error-ux, medium-low.
- `1e12` still errors as `Unbound variable: e12` (known open gap; message is misleading).

## Positive surprises (work today, zero or near-zero coverage — see fixtures list)
- Named instances + impl hints (`impl Additive of Squash Int` … `squash @Additive 3 4`)
  work on BOTH run and build; only eval_dict fixtures exist (no llvm/build/wasm fixture).
- `deriving (Eq, Ord, Debug)` + `maximum` over a derived-Ord ADT: run == build. No build
  fixture derives Ord.
- `do` over a user-defined Thenable (Mappable+Applicative+Thenable impl chain): run == build.
  No llvm fixture does user-monad `do` (only Option/Result).
- Map literal (`Map { "a" => 1 }` via `import map.*`): run == build.
- Ungated stdlib doctest suites ALL PASS natively: math (36 ex + 6 props), time, option,
  result, hex, base64, path, nonempty, validation, and — despite the gate's stale deferral
  note — map (7 props), array, mut_array (11/11) run clean end-to-end.

---

## Suggested regression fixtures

Prioritized; grouped by the harness each belongs to. (P0 = bug-locking or playground-critical,
P1 = coverage a preview user will exercise in minutes, P2 = completeness.)

### 1. wasm gates — `test/wasm/fixtures*` (`diff_wasm.sh` / `diff_wasm_typed.sh` / `diff_wasm_modules.sh`)
The playground runs this backend; everything below is tested on llvm only today.
- **P0 string interpolation**: `"x=\{a} sum=\{1+2}"`, multi-hole, triple-quoted interp.
  Zero `\{` fixtures anywhere under `test/wasm/`.
- **P0 runtime error paths**: div-by-zero, mod-by-zero, non-exhaustive match, list/string
  index OOB (native has build_diff `div_by_zero`/`mod_by_zero`/`nonexhaustive`; wasm has only
  `w7_array_oob` + `w10_panic`). Playground users WILL hit these; error text parity matters.
- **P0 dispatch parity sweep** (fixtures_typed is 8 files vs llvm_typed's 88): superclass
  (`requires`) dispatch, default-method impls, named instances + `@hints`, conditional impls
  (`impl Eq (List a) requires Eq a`), user-monad `do`, `deriving (Eq, Ord, Debug)`,
  Foldable/Traversable methods, return-position dispatch (`pure`).
- **P1 stdlib-on-wasm**: map/set (incl. Map/Set literals), json parse/serialize roundtrip,
  string kernel (interp + slicing + unicode already partly covered), mut_array push loop.
- **P1 construct parity**: `do` over Option/Result, sections/pipe/compose (`(+1)`, `|>`, `>>`),
  record rest-pattern `{ name, ... }`, char-range pattern `'a'..='z'`, triple-quoted strings,
  if-let / let-else (let_else exists — keep), `function` keyword, backtick infix.
- **P2 int boundary**: port F6's 63-bit wrap probe as a wasm/native parity fixture.

### 2. build gates — `test/build_diff_fixtures/` (`diff_compiler_build.sh`) + `test/llvm_fixtures*`
- **P0 `export import` re-export** (F2): the 3-file repro as an `mm`-style module fixture —
  currently a hard emitter panic; fixture should be added red-then-green with the fix.
- **P0 attributes** (F1): `@inline`/`@deprecated`/`@must_use` on a *signature-less* def,
  referenced from main — locks the unbind bug; plus a `@deprecated` usage-warning fixture
  once attributes do anything.
- **P1 named instances + impl hints** (works today, untested at build): probe `named2.mdk`.
- **P1 `deriving (Ord)` + maximum/minimum/compare on derived ADT** (works, untested).
- **P1 user-monad `do`** (Mappable/Applicative/Thenable impl chain; works, untested at build).
- **P1 Map literal via `import map.*`** (works; build_diff `map_literal` should be checked to
  use the literal form, not `fromList`).
- **P2 array index OOB on the native binary** (eval_error has it; build_diff covers list/string
  index-slice but not array OOB panic text).
- **P2 int-literal boundary** (F6) — same fixture as wasm's, native golden.

### 3. build-path diagnostics gate — NEW small harness (peer of `diff_compiler_check.sh`)
- **P0**: for each of ~5 error-bearing multi-module programs, assert
  `medaka build` stderr == `medaka check` stderr (locks F3's `1:0` location collapse — this
  whole failure class is currently un-gateable).

### 4. doctest gate — `test/diff_compiler_test.sh` (+ `stdlib/*.test.golden`)
- **P1 gate the passing-but-ungated modules** (all verified green natively today):
  `math`, `time`, `option`, `result`, `hex`, `base64`, `path`, `nonempty`, `validation`.
- **P1 un-defer `map`, `array`, `mut_array`** — the gate header's deferral reasons are stale:
  all three run clean end-to-end now (verified). If props are RNG-fragile, trim to doctests.
- **P2 hash_map/hash_set**: add as expected-panic fixtures or fix the `hashInt` unbound panic
  (F5) first; today a user-visible panic is completely ungated.
- **P2 write doctests for fs/io/net** (currently zero examples in module docs) — even 2-3
  pure-path examples (path math, `lines`, formatting) that don't touch real IO.

### 5. parse/lex negative tests — `test/parse_error_fixtures/` (`diff_compiler_parse_errors.sh`) and `test/error_quality_fixtures/`
17 negative vs 288 positive today. Add (each is a message-quality lock, per ERROR-QUALITY.md):
- **P1** comment-as-first-line-of-block (known parse error — no fixture pins its message).
- **P1** unterminated triple-quoted string; unterminated interpolation `"\{x"`.
- **P1** layout mistakes: tab/space indentation mix; wrong-column continuation
  (`else let x = e ⏎ body` — the "excellent" message in INVENTORY.md deserves a gate).
- **P1** out-of-range int literal (F6) once it becomes an error.
- **P2** `1e12` scientific notation (locks whatever message replaces `Unbound variable: e12`).
- **P2** reserved-word binding (`match = 5`) — INVENTORY notes generic message, ungated.

### 6. resolve/import negative tests — `test/import_error_fixtures/` (currently ONE fixture)
- **P1** `import list.flatten` (unknown name) — INVENTORY.md documents this as a **silent
  empty-stderr exit-1**; no gate pins it.
- **P1** duplicate interface / method-not-in-interface `<unknown location>` messages (F8) —
  fixture: user file redefining `interface Monoid`.
- **P2** import cycle between two user modules; self-import.

### 7. `medaka test` harness — `test/compiler_test_fixtures/`
- **P2 `bench` declaration** (F4): fixture asserting whatever the decided behavior is
  (runner output or a "benches are not run" notice) — today it's silently ignored.

### 8. parse fixtures (positive) — `test/parse_fixtures/`
- **P2** `bench` decl (only `prop` is covered); `combine @Hint` impl-hint expression
  (currently only in `hardening.mdk`); nested-update sugar `{ p | a.b = v }` already covered —
  no action.

## Suggested doc fixes (cheap, pre-launch)
- SYNTAX.md Attributes section: currently shows the exact broken shape (F1) — until fixed,
  document the signature requirement.
- SYNTAX.md Map/Set literals: note the `import map.*` / `import set.*` requirement (F7).
- SYNTAX.md header still says ground truth is `lib/parser.mly` + `test/test_parser.ml` —
  OCaml paths deleted 2026-06-26; should point at `compiler/frontend/parser.mdk` and the
  `diff_compiler_*` corpora.
- Document Int = 63-bit tagged (F6) in SYNTAX.md/README.
