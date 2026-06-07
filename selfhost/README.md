# selfhost — Medaka-in-Medaka compiler (Stage 1)

The self-hosted Medaka compiler, ported one pipeline stage at a time from the
OCaml reference in `lib/` and validated against it via differential testing.
See the **North star → Stage 1** section of [`../PLAN.md`](../PLAN.md).

Runs **on the existing tree-walking interpreter** (`medaka run …`) — correctness
first; native codegen is Stage 2.

## House style

Idiomatic Medaka, not transliterated OCaml — the self-host port is also how we
*dogfood* the language, so we lean into its idioms rather than minimizing the
diff with `lib/`:
- **Multi-clause functions** with pattern-matching heads (incl. literal heads
  like `keywordOrIdent "let" = TLet`), not `match` on the sole argument. Reserve
  `match` for case analysis on a *computed/local* value.
- **Type signatures on every top-level function.**
- Higher-order functions (`map`, etc.) where they read clearly; treat
  idiom-friction (e.g. the Phase 134 `map` quirk) as a bug to fix, not avoid.
- Structural parallelism with the OCaml reference is kept **only** in the core
  scan/parse algorithms, where it buys byte-for-byte validation.

## Layout

| File | Role |
|------|------|
| `lexer.mdk` | Port of `lib/lexer.mll`. `Token` ADT + `tokenToString` (mirror the OCaml `token_to_string` byte-for-byte) + `tokenize`. Prelude + global externs only — no stdlib import, so `selfhost/` is the sole project root. |
| `lex_main.mdk` | Runnable entry: `medaka run selfhost/lex_main.mdk <src.mdk>` reads the file, tokenizes, prints one token per line in the canonical reference form. |
| `ast.mdk` | The self-host AST — a Medaka mirror of `lib/ast.ml`'s surface (pre-desugar) nodes; the target the parser builds. Constructor names match `ast.ml`. |
| `sexp.mdk` | `programToSexp` — a canonical structural S-expression dump of the AST, mirroring `dev/astdump.ml` byte-for-byte; the parser's validation format (the `tokenToString` analog). |
| `parser.mdk` | Port of `lib/parser.mly`. A **monadic combinator** parser over `List Token` — a `Parser` monad (`Mappable`/`Applicative`/`Thenable`) with `do`-notation + `many`/`sepBy1`/`choice`/`chainl1`; `parse : String -> List Decl`. Precedence is the stratified ladder, one function per level. |
| `parse_main.mdk` | Runnable entry: `medaka run selfhost/parse_main.mdk <src.mdk>` reads the file, parses, and prints the structural S-expression. |
| `desugar.mdk` | Port of `lib/desugar.ml`. Lowers surface sugar to core: the bottom-up `mapExpr`/`mapDecl` engine + the passes `merge_iface_defaults → expand_decl (deriving) → list-comps → questions → do-blocks → sugar`; `desugar : List Decl -> List Decl`. |
| `desugar_main.mdk` | Runnable entry: parse + desugar a file, print the structural S-expression (diffs against `astdump --desugar`). |
| `marker.mdk` | Port of `lib/method_marker.ml`. Marks interface-method / constrained-fn occurrences (`EVar`→`EMethodRef`/`EDictApp`); includes the Phase 78a/78b prelude-shadowing logic. `markWithPrelude : List Decl -> List Decl -> List Decl` (prelude, target). |
| `mark_main.mdk` | Runnable entry: `medaka run selfhost/mark_main.mdk <prelude.mdk> <src.mdk>` parses + desugars both, marks the target, prints the S-expression (diffs against `astdump --mark`). |
| `resolve.mdk` | Port of `lib/resolve.ml` (single-file path). Name-binding / scope / unknown-name checks over a list-based env seeded from runtime + prelude; `resolveProgram : List Decl -> List Decl -> List Decl -> List ResError`. |
| `resolve_main.mdk` | Runnable entry: `medaka run selfhost/resolve_main.mdk <runtime.mdk> <core.mdk> <src.mdk>` prints one diagnostic per line (diffs against `diagdump --resolve`, the harness sorts). |
| `resolve_modules_main.mdk` | Multi-module runnable entry: `medaka run selfhost/resolve_modules_main.mdk <runtime.mdk> <core.mdk> <mod1.mdk> [mod2.mdk …]` threads `resolveModule` over the files in order (caller supplies dependency-first order), validating imports against accumulated exports; prints all modules' diagnostics (diffs against `diagdump --resolve-modules`, the harness sorts). |
| `annotate.mdk` | The STAGE2 §2.0 lexical-addressing EMIT pass (`annotateProgram : List Decl -> List Decl`, `EVar n` → `EVarAt n (ALocal frame slot)`), in a lean ast+util-only module. The Core IR drivers run it so each `CVar` is born lexically addressed; eval has a DORMANT `EVarAt` consume arm but the AST eval pipeline does **not** run it (measured no tree-walker win — see *Performance*). |
| `exhaust.mdk` | Port of `lib/exhaust.ml`'s `check_guard_exhaustiveness` (guard coverage over the raw AST; Maranget `useful` matrix). No prelude — the ctor oracle is built from the file's own data decls + builtins. `exhaustToLines : List Decl -> String`. |
| `exhaust_main.mdk` | Runnable entry: `medaka run selfhost/exhaust_main.mdk <src.mdk>` prints one guard warning per line (diffs against `diagdump --exhaust`, the harness sorts). Parses **without** desugaring (guards must still be `EGuards`). |
| `eval.mdk` | Tree-walk interpreter (Stage-1 capstone, **slice 1**). `Value`/`EvalEnv` ADTs + `pp_value` (byte-for-byte with `lib/eval.ml`) + the engine: `eval`/`apply`/`match_pat`/binops over `(name, Ref value)` env frames; single-file `evalMain`/`evalOutput` and the multi-module `evalModules`/`evalModulesOutput`. Also carries one Stage-2 affordance: a `VClosureF` `Value` variant (a closure whose body is an opaque host fn, not an AST `Expr`) so the Core IR evaluator can reuse this runtime's `apply`/dispatch without `eval.mdk` depending on `core_ir.mdk`. |
| `eval_main.mdk` | Runnable entry: `medaka run selfhost/eval_main.mdk <src.mdk>` parses + desugars a self-contained (prelude-free) file, evaluates it, prints `pp_value` of `main` (diffs against `dev/eval_probe.exe`). |
| `eval_prelude_main.mdk` | Like `eval_main` but prepends one or more parsed prelude files: `medaka run selfhost/eval_prelude_main.mdk <prelude.mdk>... <src.mdk>` — `core.mdk` for interface methods, `+ list.mdk` for the List combinators / comprehensions (diffs against `dev/eval_probe.exe --prelude` / `--prepend`). |
| `eval_run_main.mdk` | **True execution**: `medaka run selfhost/eval_run_main.mdk <prelude.mdk>... <src.mdk>` runs the program for its **stdout** (putStr/putStrLn captured to a buffer), prelude-shadow-dropping the user's redefinitions. Diffs against the `=== EVAL ===` goldens (`test/diff_selfhost_eval_run.sh`). |
| `eval_typed_main.mdk` | **Typed execution** (return-position dispatch): `medaka run selfhost/eval_typed_main.mdk <runtime.mdk> <prelude.mdk>... <src.mdk>` threads desugar → `typecheck.elaborate` (stamps `EMethodAt` tags) → eval on one shared tree, so `pure`/`empty`/do-blocks dispatch by concrete return type. Diffs against `medaka run` (`test/diff_selfhost_eval_typed.sh`). |
| `eval_dict_main.mdk` | **Dict-passing execution**: like the typed path but also dictionary-passes `=>`-constrained functions (`typecheck.elaborateDict`) — both the *user* program's and the *prelude*'s own (`when`/`unless`, via `preludeReturnPosDictNames`) — so a return-position method used at a constraint variable's type (e.g. `empty` inside `f : Monoid a => a -> a`, or `pure ()` inside `when`) resolves through the dict parameter the caller supplies, which arg-tag / RKey dispatch cannot do. Diffs against `medaka run` (`test/diff_selfhost_eval_dict.sh`). |
| `typecheck.mdk` | HM core (**slice 1**). `Mono`/`Scheme` + union-find `unify`, level-based `generalize`/`instantiate`, `pp_mono`, and `infer`/`inferPat`. `checkToLines : List Decl -> <Mut> String`. |
| `typecheck_main.mdk` | Runnable entry: `medaka run selfhost/typecheck_main.mdk [runtime.mdk] <src.mdk>` prints `name : scheme` per top-level binding (diffs against `dev/tc_probe.exe`; both sorted). With a runtime.mdk arg its externs are seeded into scope, so `core.mdk` (+ a user program) type-checks against the `=== TYPES ===` goldens. |
| `check_match_main.mdk` | Runnable entry for the **type-aware match-exhaustiveness** check (`check_match`, fired per `EMatch` from inside `typecheck`): `medaka run selfhost/check_match_main.mdk <runtime.mdk> <src.mdk>` parses + desugars + type-checks the target (runtime externs seeded, **no prelude** — mirrors `check_program_no_prelude`) and prints one `Warning: non-exhaustive match …` line per `match` whose non-guarded arms don't cover the scrutinee's type. Diffs against `dev/diagdump.exe --check-match` (the harness sorts). The check itself (`typecheck.checkMatchToLines` + `inferMatch`) **reuses** `exhaust.mdk`'s exported `Oracle`/`buildOracle`/`useful`/`desugarPat`/`tupleCtorName`. |
| `check.mdk` | **Composed front-end** — `medaka run selfhost/check.mdk <runtime.mdk> <core.mdk> <src.mdk>` wires parse → desugar → resolve → exhaust → typecheck into one program (the self-hosted analog of `medaka check`). Prints resolve diagnostics, else guard warnings + inferred schemes. `test/diff_selfhost_check.sh` validates it reproduces the 16 TYPES goldens (clean) and 14 resolve diagnostics (broken). |
| `loader.mdk` | Port of `lib/loader.ml`: `loadProgram : String -> List String -> <IO> Result String (List (String, List Decl))` — DFS topo-sort of a root file's transitive `import`s (dependency-first; cycle detection). Flat single-root simplification. `loader_main.mdk` prints the module order. |
| `check_modules_main.mdk` | **Multi-module typecheck front-end** (the bootstrap front-end): `medaka run selfhost/check_modules_main.mdk <runtime.mdk> <core.mdk> <entry.mdk> [root ...]` loads entry + imports, typechecks them in dependency order against the shared prelude (`typecheck.checkModules`), prints the entry module's own schemes. Diffs against `dev/tc_module_probe.exe` (`test/diff_selfhost_check_modules.sh`, all 13 selfhost modules incl. `annotate`). |
| `eval_modules_main.mdk` | **Multi-module execution** (the loader-driven eval path): `medaka run selfhost/eval_modules_main.mdk <core.mdk> <entry.mdk> [root ...]` loads entry + imports, evaluates them in per-module frames over the shared prelude (`eval.evalModules`), forces the entry's `main`, prints captured stdout. Diffs against `medaka run <entry>` (`test/diff_selfhost_eval_modules.sh`). |
| `eval_typed_modules_main.mdk` | **Typed multi-module execution** (the composition of `eval_typed_main` + `eval_modules_main`): `medaka run selfhost/eval_typed_modules_main.mdk <runtime.mdk> <core.mdk> <entry.mdk> [root ...]` loads entry + imports, then `typecheck.elaborateModules` threads the marker + route-stamping through the loader's module graph (per-module-frame typecheck in dependency order, `EMethodAt` routes stamped per module) before `eval.evalModules` runs the elaborated trees — so a stage that uses return-position dispatch (the `Parser` monad's `pure`/`andThen`) routes by RKey. The Leg-C/D bootstrap driver (runs the parser *and* the typechecker stage on the self-hosted eval); diffs against `medaka run <entry>` (`test/diff_selfhost_selfproc.sh`). |
| `core_ir.mdk` | **Stage 2 §2.1 Core IR** (slices 1/3/5) — the backend-neutral, serializable IR lowered from the elaborated AST: `CExpr`/`CArm`/`CGuard`/`CStmt`/`CBind`/`CImplEntry`/`CImplBody`/`CProgram`. Lives *above* any ISA (the on-ramp discipline): dispatch is the structural immutable `CMethod`/`CDict` (Routes read out of the AST's `Ref Route` cells), variables carry a lexical `Addr`, and typeclass impls/defaults are lowered (Ty-free) into `CImplEntry` for the driver to install. See `STAGE2-DESIGN.md` §2.1. |
| `core_ir_lower.mdk` | `lower : Expr -> CExpr` / `lowerProgram : List Decl -> CProgram` — the elaborated-AST → Core IR pass. The surface→primitive collapse happens here: `&&`/`||`→`CIf`, `|>`→`CApp`, `>>`/`<<`→`CLam`, type annotations erased, multi-clause groups coalesced. `lowerImpls` lowers each impl-method clause + interface default into a `CImplEntry` (tag / dispatch positions / specificity score reused verbatim from `eval.mdk`'s `declImplEntries`). |
| `core_ir_eval.mdk` | The direct Core-IR tree-walker `ceval`/`cevalProgram`/`cevalMain`/`cevalOutput` — the §2.1 equivalence oracle. REUSES `eval.mdk`'s host runtime (`Value`, env, `apply`/dispatch/fall-through, `matchPat`, externs, `pp_value`, the slice-3 value helpers, and the impl-coalesce machinery) via the one added `VClosureF` variant, so multi-clause + guard fall-through and arg-tag dispatch run the same `VMulti`+`VFallthrough`+`VTypedImpl` path the AST interpreter uses. Slice 3 = records/refs/arrays/ranges/index/slice/blocks; slice 5 = installing impls as arg-tag `VMulti`s + the `CMethod`/`CDict` return-position arms. |
| `core_ir_main.mdk` | Runnable entry: `medaka run selfhost/core_ir_main.mdk <src.mdk>` parses → desugars → `annotateProgram` (so each `CVar` is born lexically addressed) → lowers → evaluates the Core IR, prints `pp_value` of `main`. Diffs against `dev/eval_probe.exe` — the SAME oracle `eval_main` uses, i.e. the §2.1 *equivalence* gate (`test/diff_selfhost_core_ir.sh`, the full 19 prelude-free engine fixtures). |
| `core_ir_prelude_main.mdk` | Prelude-loaded Core IR entry (analog of `eval_prelude_main`): `medaka run selfhost/core_ir_prelude_main.mdk <prelude.mdk>... <src.mdk>` prepends the parsed prelude, annotates + lowers + evaluates, prints `pp_value` of `main`. Drives slice 5's impl install over real stdlib dispatch (Eq/Ord/Debug/Display/Num + deriving). Gates: `test/diff_selfhost_core_ir_prelude.sh` (core.mdk, 5) + `test/diff_selfhost_core_ir_list.sh` (core.mdk + list.mdk, 2). |
| `core_ir_typed_main.mdk` | Typed Core IR entry (analog of `eval_typed_main`): `medaka run selfhost/core_ir_typed_main.mdk <runtime.mdk> <prelude.mdk>... <src.mdk>` desugars → `typecheck.elaborate` (stamps EMethodAt/EDictAt routes) → lowers (routes read out into `CMethod`/`CDict`) → `cevalOutput`. The ONLY corpus that drives the `CMethod` arm — return-position dispatch (RKey), e.g. a user Applicative's `pure`. Diffs stdout against the reference typed path `medaka run <file>` (`test/diff_selfhost_core_ir_typed.sh`, 2). |
| `core_ir_run_main.mdk` | True-execution (stdout) Core IR entry (analog of `eval_run_main`): `medaka run selfhost/core_ir_run_main.mdk <prelude.mdk>... <src.mdk>` prepends the prelude (prelude-shadow-dropping the user's redefinitions, like `eval_run_main`), annotates + lowers, and evaluates the Core IR for its OUTPUT (`cevalOutput`). Diffs the captured stdout against the `=== EVAL ===` goldens (`test/diff_selfhost_core_ir_run.sh`, 18) — the SAME goldens `eval_run_main` matches. |
| `core_ir_modules_main.mdk` | Multi-module Core IR entry (the loader-driven Core-IR path — analog of `eval_modules_main`): `medaka run selfhost/core_ir_modules_main.mdk <core.mdk> <entry.mdk> [root ...]` loads entry + imports, desugars + annotates each, LOWERS them per-module to Core IR and evaluates them in per-module frames over the shared prelude (`core_ir_eval.cevalModules`), printing the root module's `main` stdout. Diffs against `medaka run <entry>` (`test/diff_selfhost_core_ir_modules.sh`, 4) — the SAME oracle `eval_modules_main` uses. |
| `core_ir_sexp.mdk` | **Stage 2 §2.1 Core IR serializer** — `cprogramToSexp : CProgram -> String` (and all sub-serializers: `cexprSexp`, `cbindSexp`, `carmSexp`, `ctreeSexp`, `cheadSexp`, `cimplEntrySexp`, etc.). Lossless structural S-expression dump mirroring `sexp.mdk`'s style: every node tagged by constructor name, `CVar` carries its `Addr`, `CMethod`/`CDict` carry their `Route`s. The canonical frozen-IR serialization format — the LLVM contract input and future `medaka build` artifact cache basis. |
| `core_ir_sexp_parse.mdk` | **Stage 2 §2.1 Core IR deserializer** — `parseCProgram : String -> CProgram`. Tokenizes the S-expression (quoted strings, parens, bare atoms), builds an `SExp` tree, then pattern-matches each tag back to the typed `CProgram`/`CExpr`/... ADTs. All 18 engine-corpus fixtures round-trip faithfully. |
| `core_ir_dump_main.mdk` | Runnable entry for the Core IR serializer: `medaka run selfhost/core_ir_dump_main.mdk <src.mdk>` parses → desugars → `annotateProgram` → lowers → `cprogramToSexp`. Snapshot goldens live in `test/core_ir_sexp_fixtures/`; `test/diff_selfhost_core_ir_sexp.sh` diffs fresh dumps against them (catches accidental lowering/serializer drift). |
| `core_ir_roundtrip_main.mdk` | Runnable entry for the round-trip gate: `medaka run selfhost/core_ir_roundtrip_main.mdk <src.mdk>` lowers → serializes → parses back → evaluates (`cevalMain`) → prints `pp_value`. Diffs against `dev/eval_probe.exe` (`test/diff_selfhost_core_ir_roundtrip.sh`, all 18 engine fixtures). A passing result proves the serialization is semantics-faithful. |
| `bytecode.mdk` | **Stage 2 §2.2 bytecode compiler + stack VM** (slices 1–6) — the first lowering of the Core IR *below* an ISA. `compile : CExpr -> List Instr` emits a flat, position-independent instruction stream (relative jumps); `runChunk` is a stack machine threading `(ip, value-stack, env)` over the `Instr` `Array`. REUSES `eval.mdk`'s host runtime verbatim — `Value`, env, `applyValue`/dispatch/fall-through, `matchPat`, the arithmetic + record + range + index helpers, externs, `pp_value`. Slice 1 = literals, lexically-addressed variables, application, primitive binops/unops, tuples, lists, `if`, let-sequencing blocks. Slice 2 = `IMatchArms` (ordered-arm `CMatch` dispatch) + `IMatchDecision` (decision-tree `CDecision` dispatch, mirroring `cevalDecision`'s tree walk with compiled arm body chunks) + `IBindFail` (CSLetElse pattern-bind-or-else). Slice 3 = `IMakeArray`, `IMakeRecord`, `IField`/`IFieldValue`, `IRecordUpdate`, `IRangeList`/`IRangeArray`, `IIndex`, `ISlice`, plus `CSAssign` in blocks. Slice 4 = `IMakeClosure` (CLam → VClosureF), `ILetBound` (non-rec let-in), `ILetRec` (recursive let with cell back-patch), `ILetGroup` (where-block / local mutual-rec group — eager nullary, VClosureF for parameterised, VMulti for multi-clause, mirroring `cevalLetGroup`/`cGroupValue`). Slice 5 = `IMethod` (CMethod — return-position dispatch via `narrowMethod`/`routeTag`) + `IDict` (CDict — dict application via `applyDicts`); `bcEvalProgram` installs typeclass impls via `coalesceImpls` before user groups. Slice 6 = `bcEvalModules`/`bcEvalModulesOutput` — multi-module per-module frames mirroring `cevalModules` (prelude installs globally; each module's lowered CBind groups install into its own local frame via `bcInstallGroups`; ctors + impls coalesce globally; `importFrameOf`/`pubReexports` reused verbatim). **Zero `eval.mdk` changes** — every reused name was already exported. |
| `eval_bytecode_main.mdk` | Runnable entry for the bytecode VM (analog of `core_ir_main.mdk`): `medaka run selfhost/eval_bytecode_main.mdk <src.mdk>` parses → desugars → `annotateProgram` → lowers to Core IR → COMPILES to bytecode → runs the stack VM → prints `pp_value` of `main`. Diffs against `dev/eval_probe.exe` — the SAME oracle `eval_main`/`core_ir_main` use (`test/diff_selfhost_eval_bytecode.sh`, 19 fixtures across slices 1–5, ~1.5s). |
| `eval_bytecode_modules_main.mdk` | Multi-module bytecode VM entry (analog of `core_ir_modules_main.mdk`): `medaka run selfhost/eval_bytecode_modules_main.mdk <core.mdk> <entry.mdk> [root ...]` loads entry + imports, desugars + annotates each, LOWERS per-module to Core IR and evaluates in per-module bytecode frames over the shared prelude (`bytecode.bcEvalModulesOutput`), printing the root module's `main` stdout. Diffs against `medaka run <entry>` (`test/diff_selfhost_eval_bytecode_modules.sh`, 4 fixtures, the SAME oracle `eval_modules_main`/`core_ir_modules_main` use). |
| `eval_bytecode_typed_modules_main.mdk` | **TYPED multi-module bytecode VM entry** (§2.3 item 1 — analog of `eval_typed_modules_main.mdk`): `medaka run selfhost/eval_bytecode_typed_modules_main.mdk <runtime.mdk> <core.mdk> <entry.mdk> [root ...]` loads entry + imports, desugars, then `typecheck.elaborateModules` threads the marker + route-stamping through the loader's module graph (per-module-frame typecheck in dependency order, `EMethodAt` routes stamped per module), then annotates (`annotateProgram`) and runs each elaborated module through the bytecode VM (`bytecode.bcEvalModulesOutput`). All three selfproc probes (lex/parse/tc) pass byte-for-byte through this typed path. This required adding `CVariantUpdate` support throughout the Core IR pipeline (lowering `EVariantUpdate` — named-field constructor update syntax used in `typecheck.mdk`). |
| `eval_bytecode_typed_main.mdk` | TYPED bytecode-VM entry (analog of `core_ir_typed_main.mdk`): `medaka run selfhost/eval_bytecode_typed_main.mdk <runtime.mdk> <prelude.mdk>... <file.mdk>` desugar → elaborate (typechecker stamps EMethodAt/EDictAt routes) → lowerProgram → compile + run through the bytecode VM for stdout, exercising `IMethod`/`IDict` (slice 5) with real elaborated routes. Diffs byte-for-byte against `medaka run <file>` (`test/diff_selfhost_eval_bytecode_typed.sh`, 3 typed fixtures). |
| `eval_bytecode_typed_dict_main.mdk` | **TYPED DICT-PASSING bytecode-VM entry** (§2.3 item 2 — analog of `eval_dict_main.mdk`): `medaka run selfhost/eval_bytecode_typed_dict_main.mdk <runtime.mdk> <prelude.mdk>... <file.mdk>` desugar → `elaborateDict` (typecheck stamps routes + dict_pass prepends leading dict params) → `lowerProgram` → `bcEvalOutput`. Validates the full dict-passing corpus — instance-`requires` element dicts (Phase 83/84), method-level constraint dicts (Phase 69.x-e), and nested two-level instance dicts — through the bytecode VM. Gate: `test/diff_selfhost_bytecode_eval_dict.sh` — 17/17 byte-identical. |
| `eval_bytecode_run_main.mdk` | True-execution (stdout) bytecode-VM entry (analog of `core_ir_run_main.mdk`): `medaka run selfhost/eval_bytecode_run_main.mdk <prelude.mdk>... <file.mdk>` shadow-drops redefine prelude fns, annotates + lowers to Core IR, compiles to bytecode, runs the VM for IO output. Diffs against `=== EVAL ===` goldens (`test/diff_selfhost_eval_bytecode_run.sh`, 18 fixtures, the SAME goldens `eval_run_main`/`core_ir_run_main` use). |
| `llvm_emit.mdk` | **Stage 2 §2.4 LLVM de-risking SPIKE** (slices 1–8; not the real backend) — `emitProgram : CProgram -> String` lowers the Core IR to *textual* LLVM IR. Slice 1 = the scalar subset (integer/float arithmetic, comparisons, unary `-`/`!`, `let`, `if`, top-level value bindings, type-directed print). Slice 2 = top-level functions (`name p… = …` → `define i64 @mdk_<name>`) + saturated direct **calls** (`CApp`), with self-recursive tail calls lowered to `musttail call`+`ret` (the calling-convention proof — TCO-correct under `clang -O0`; cross-function `musttail` deferred). Slice 2b = **Bool/Float function boundaries**: a two-pass signature inference (`inferSigs`/`typeOf`/`paramUseTy`) recovers each function's param + return type from the type-erased Core IR (param type from its first typed use — `if`/`!` ⇒ Bool, an arith/compare operand shares its sibling, an argument takes the callee's param type — return type structural), so a Bool-returning function prints `true`/`false` and a Float param unboxes/reboxes. The ABI is unchanged (every value is a uniform i64 word — Int/Bool immediate, Float boxed-pointer-as-i64), so no `define`/`call`/`musttail` prototype change; the type only selects int-vs-float instructions + the print routine. Slice 3 = **ADT constructors + pattern matching**: a constructor lowers to a boxed heap cell (one-word string-hashed i64 tag + field words via `@mdk_alloc`, the slice-1 Float-box path extended to N fields, word = `ptrtoint` of the cell — low bit 0, disjoint from immediate ints); a `match` lowered to a `CDecision` decision tree becomes an LLVM CFG (each `CTSwitch` tests the focus head — load tag → `icmp`/`br` for constructors, immediate compare for int literals — and descends into the matched cell's fields as the new focus columns; a leaf re-matches its arm's pattern against the scrutinee via `getelementptr` loads, evaluates the body into an `alloca` result slot, branches to the decision's end block), mirroring `core_ir_eval`'s `cevalDecision`/`cevalTree`/`cevalSwitch` one-to-one (value-walk → block-emit). Slice 4 = **closures + higher-order functions**: each `CLam` is lambda-lifted to a top-level `define @mdk_lamN(i64 %clos, i64 %arg…)` and allocates, at its site, a boxed closure cell `{header, code_ptr, captured…}` (the slice-3 ctor alloc reused verbatim with "fields" = `[code_ptr, capture…]`; captured set = freeVars(body) − params ∩ the live emit env); an application whose head is not a known fn/ctor (a closure-valued param / let-binding / returned closure / immediately-applied lambda) lowers to an INDIRECT call (load code_ptr, `call` the pointer passing the closure word as the leading argument, RUNTIME-DESIGN.md §8.5), and a named top-level fn used as a value is eta-wrapped into a captureless static closure forwarding to `@mdk_<name>`. **Saturated calls only** — the type-erased Core IR can't see a closure's arity at the call site, so partial application / over-application are out (the real backend will carry arity in the cell). Slice 5a = **records, tuples, mutable refs**: Records lower to boxed cells exactly like ADT constructors (`emitCtorAlloc`/`storeFields`/`loadField` verbatim); field access uses a per-name field-order table built by scanning `CRecord` nodes up front. Tuples use the same cell layout with `header = hashName "$tuple"`; `let (a,b,c) = t` (`CLet PTuple` / `CBlock CSLet PTuple`) binds elements by `loadField`. Mutable refs lowered inline: `Ref x` → 1-field `emitCtorAlloc "$ref"`; `set_ref r x` → GEP offset 8 + store; `r.value` → `loadField 0`. Slice 5b = **built-in list/tuple match heads + recursive closures**: the decision tree's `HCons`/`HNil`/`HTuple` heads are routed through `conHeadInfo` to constructor tests against `hashName "Cons"/"Nil"/"$tuple"` (the same tag the alloc site stamps, so construct/match agree), `bindPattern` gains `PCons`/`PList []`, and a recursive function-`let` (`CLet True (PVar f) (CLam …)`) lambda-lifts with `f` bound to `%clos` inside the lifted body (self-call re-enters the same cell, `f` excluded from captures). Slice 6 = **typeclass dispatch (return-position)**: `CMethod` with an `RKey` route is statically resolved → a DIRECT call to the impl's lifted `@mdk_impl_<tag>_<method>` (no runtime tag test; the bootstrap path), while `RDict`/`RDictFwd` read a runtime dict-parameter witness word → an inline if-chain over the method's impls; `CDict` (a `=>`-constrained-fn occurrence) → a direct `@mdk_<name>(dictWords ++ argWords)` (`dict_pass` already prepended the leading dict params). Slice 7 = **arg-position (arg-tag) dispatch**: a method dispatched on its argument's runtime constructor type lowers NOT to a `CMethod` but to a bare `CVar` (the marker rewrites only return-position occurrences) resolving to the coalesced VMulti — so the call site (`emitApp`) loads the discriminating arg's cell tag and either calls the lone impl directly (one impl group) or emits a type if-chain over `ctorsOfType` (impls at distinct ADTs; ADT-only); multi-clause / pattern-param impl bodies coalesce same-`(method,tag)` `CImplEntry`s into one lifted fn whose body is a decision tree built by the shared `compileTree` (arity ≥2 wrapped in a synthetic tuple to reuse `emitDecision` verbatim). Slices 6–7 need types, so they run through the TYPED driver `llvm_emit_typed_main.mdk` (`elaborateDict` route-stamp + `dict_pass`) gated by `test/diff_selfhost_llvm_typed.sh` against the typed tree-walker oracle `core_ir_dict_pp_main.mdk` (6 fixtures in `test/llvm_fixtures_typed/`). A sibling consumer of the same Core IR `core_ir_eval`/`bytecode` consume — Axis-1 discipline in miniature (slice 7 exports the backend-neutral `compileTree`/`canonPat`, the shared decision-tree pass). Slice 8 = **arrays + ranges**: `CArray` allocates a length-prefixed boxed cell `[ raw_len | elem0 | elem1 … ]` (header word = raw element count; same `storeFields`/`loadField` field convention — `loadTag` reads the count). `CIndex` bounds-checks (two icmps → `@mdk_oob()` noreturn on OOB) then GEPs dynamically via `loadFieldDyn`. `CRangeArray` and `CSlice` emit an alloca-counter loop (the spike's first non-recursion loop; no phi nodes). `CList`/`CRangeList` deferred. Value rep is a **PROVISIONAL** uniform 64-bit tagged word (low-bit-1 immediate `Int`/`Bool`/`Char`, boxed `Float`/ADT/closure/record/tuple/ref/array via `@mdk_alloc`); the tag/box arithmetic is emitted *into the IR* (deliberately visible) so the rep is revisable in one place. Still out-of-scope (panic rather than mis-lower): CList/CRangeList, the `HUnit` match head and non-Int literal heads, guarded/range/record arms (`CTGuard`), non-empty `PList` binding, partial/over-application, and Ref capture. The rep + calling-convention proposal it fed is `RUNTIME-DESIGN.md` §8. |
| `llvm_emit_main.mdk` | Runnable entry for the LLVM spike (analog of `core_ir_main.mdk`): `medaka run selfhost/llvm_emit_main.mdk <src.mdk>` parses → desugars → `annotateProgram` → lowers to Core IR → emits a textual LLVM module to stdout (sharing the entire front-end + lowering with `core_ir_main.mdk`, swapping only the final consumer). `test/diff_selfhost_llvm.sh` compiles the emitted `.ll` + `../runtime/medaka_rt.c` with `clang`, runs the binary, and diffs its stdout against `dev/eval_probe.exe` — the SAME oracle, the usual equivalence-gate shape (39 prelude-free fixtures in `test/llvm_fixtures/`: 8 scalar + 5 function/recursion + 4 Bool/Float boundary + 5 ADT/match + 5 closure/HOF + 4 records/tuples/refs + 4 list/tuple-match/recursive-closure + 4 arrays/ranges). |
| `timer.mdk` | Per-stage wall-clock timing helpers (`perfEnabled`, `now`, `emitPhase`, `emitTotal`, `totalDecls`, `allocSnap`, `emitPhaseA`, `emitTotalA`) guarded by the `MEDAKA_PERF` env var. All output goes to stderr; unset ⇒ pure no-op so any driver that imports this stays byte-identical to its un-instrumented counterpart. `emitPhaseA`/`emitTotalA` are extended variants that include an allocation-delta column (`Gc.allocated_bytes` proxy, bytes→MB). Used by `perf_main.mdk`, `profile_main.mdk`, and `profile_modules_main.mdk`. |
| `perf_main.mdk` | **Multi-module pipeline profiler**: `MEDAKA_PERF=1 medaka run selfhost/perf_main.mdk <runtime.mdk> <core.mdk> <entry.mdk> [root ...]` times the full typed multi-module path — **parse** (runtime+core lex+parse+desugar), **load** (`loadProgram`: all transitive imports), **desugar** (all modules), **elaborate** (`elaborateModules`: marker + per-module typecheck), **eval** (`evalModulesOutput`) — and prints `[perf] stage\tNs\tops` lines to stderr. See `PERF-NOTES.md` for the recorded baseline (15 modules, ~6.0s total). |
| `profile_main.mdk` | **Single-file per-stage profiler**: `MEDAKA_PERF=1 medaka run selfhost/profile_main.mdk <runtime.mdk> <core.mdk> <target.mdk>` separately times **parse-prelude** (runtime+core setup), **parse** (lex+parse), **desugar**, **resolve**, **mark**, **typecheck** for one target file — breaking apart the `elaborate` composite that `perf_main.mdk` reports as a single phase. Each phase also reports an allocation-delta column (`Gc.allocated_bytes` proxy, MB). `MEDAKA_PERF` unset ⇒ silent exit (no useful stdout — measurement tool only). Use `test/profile_selfhost.sh [N]` to run min-of-N over representative files and print a table. See `PERF-NOTES.md` for the recorded baseline (`lexer.mdk`: ~0.97s total; parse dominates at 36%). |
| `profile_modules_main.mdk` | **Multi-module per-stage profiler** (marks `elaborate` split): `MEDAKA_PERF=1 medaka run selfhost/profile_modules_main.mdk <runtime.mdk> <core.mdk> <entry.mdk> [root ...]` times **parse** (runtime+core), **load** (`loadProgram`), **desugar**, **mark** (`markModules`: rpNames + prePassDict), **typecheck** (`checkModules`; HM only, no eval) separately — breaking the `elaborate` lump that `perf_main.mdk` reports as one phase. Each phase reports time + alloc-delta (MB). `MEDAKA_PERF` unset ⇒ silent exit. Use `test/profile_selfhost.sh [N]` for min-of-N tables. See `PERF-NOTES.md` for the baseline (15 modules: load 3.46s/57%, typecheck 2.03s/34%, mark 0.083s/1.4%). |
| `vm_perf_modules_main.mdk` | **VM vs tree-walker perf comparison (multi-module)**: `MEDAKA_PERF=1 medaka run selfhost/vm_perf_modules_main.mdk <core.mdk> <entry.mdk> [root ...]` times `evalModulesOutput` (tree-walker) vs `bcEvalModulesOutput` (bytecode VM) on the same loaded module graph, with annotation time reported separately. Stdout is the tree-walker output (byte-identical to `eval_modules_main.mdk`). See `PERF-NOTES.md` §"§2.2 Capstone" for the baseline (`selfproc_lex_probe`: tree-walker 0.240s, bytecode-vm 0.657s → 2.74×). |
| `medaka.toml` | Project config (import root). |

The OCaml-side validation references live in `dev/`: `lextok.exe` (token-stream
dumper), `astdump.exe` (AST S-expression dumper, with `--parse`/`--desugar`/
`--mark` stage modes), and `diagdump.exe` (`--resolve`/`--exhaust`/`--check-match`
single-file diagnostics dumper, plus `--resolve-modules <mod...>` for the
multi-module `resolve_module` path over an ordered file list).  `--check-match`
runs the type-aware path (parse → desugar → `check_program_no_prelude`) and dumps
only the non-exhaustive-match warnings.

## Validation

```sh
dune build --root .                           # build the reference binary
sh test/diff_selfhost_lexer.sh                # diff the Medaka lexer vs OCaml goldens
sh test/diff_selfhost_parse_errors.sh         # parser/lexer rejection path (~0.4s)
sh test/diff_selfhost_check_match.sh          # type-aware non-exhaustive-match warnings vs diagdump --check-match (11 fixtures)
sh test/diff_selfhost_eval_errors.sh          # eval runtime-error messages vs reference (~1s)
sh test/diff_selfhost_typecheck_errors.sh     # typecheck TYPE ERROR accumulation (3 fixtures × 2 drivers, ~1s)
sh test/diff_selfhost_selfproc.sh             # the bootstrap (#3) self-processing gate (4 legs, ~18s)
sh test/diff_selfhost_core_ir.sh              # Stage 2 §2.1 Core IR equivalence gate — engine corpus (19, incl. §2.3 item 3 effect_poly)
sh test/diff_selfhost_core_ir_prelude.sh      #   …with core.mdk prelude dispatch (5)
sh test/diff_selfhost_core_ir_list.sh         #   …with core.mdk + list.mdk (2)
sh test/diff_selfhost_core_ir_typed.sh        #   …typed return-position dispatch / CMethod (2)
sh test/diff_selfhost_core_ir_run.sh          #   …true-execution stdout / === EVAL === goldens (18)
sh test/diff_selfhost_core_ir_modules.sh      #   …loader-driven per-module frames (4)
sh test/diff_selfhost_core_ir_sexp.sh         #   …serializer snapshot gate / cprogramToSexp goldens (18)
sh test/diff_selfhost_core_ir_roundtrip.sh    #   …round-trip: lower→sexp→parse→eval == oracle (18, proves lossless)
sh test/diff_selfhost_eval_bytecode.sh        # Stage 2 §2.2 bytecode VM slices 1–5 — closures+dispatch (19 ok, ~1.5s; incl. §2.3 item 3 effect_poly)
sh test/diff_selfhost_eval_bytecode_modules.sh #   …slice 6 — multi-module per-module frames (4 ok)
sh test/diff_selfhost_eval_bytecode_typed.sh  #   …typed path: elaborate→lower→VM vs `medaka run` oracle (3 ok)
sh test/diff_selfhost_eval_bytecode_run.sh    #   …true-execution stdout: shadow-drop→annotate→lower→VM vs EVAL goldens (18 ok)
sh test/diff_selfhost_bytecode_selfproc.sh    #   §2.2 capstone + §2.3 item 1: lex/parse/tc through untyped+typed bytecode VM (6/6 ok)
sh test/diff_selfhost_eval_dict.sh            #   §2.3 item 2: dict-passing corpus through typed tree-walker (17/17 ok)
sh test/diff_selfhost_bytecode_eval_dict.sh   #   §2.3 item 2: same corpus through typed bytecode VM (17/17 ok)
sh test/diff_selfhost_eval.sh                 #   §2.3 item 3: effect-poly erasure (effect_poly) + full engine corpus via tree-walker (19 ok)
sh test/diff_selfhost_llvm.sh                 # Stage 2 §2.4 LLVM spike — emit→clang→link→run→diff, scalar + function + Bool/Float + ADT/match + closure/HOF + records/tuples/refs + list/tuple-match/rec-closure slices (35/35; needs clang)
sh test/diff_selfhost_llvm_typed.sh           # Stage 2 §2.4 LLVM spike slices 6–7 — TYPED dispatch (return-pos CMethod RKey/RDict + arg-pos bare-CVar arg-tag); oracle = typed Core-IR tree-walker (6/6; needs clang)

# Per-stage wall-clock profiling (measurement only; output goes to stderr):
MEDAKA_PERF=1 medaka run selfhost/perf_main.mdk \
    stdlib/runtime.mdk stdlib/core.mdk selfhost/all_modules_entry.mdk selfhost
sh test/profile_selfhost.sh [N]              # min-of-N per-stage table for lexer.mdk, parser.mdk, all_modules_entry.mdk (default N=3)
```

The harness runs the Medaka lexer over every fixture in `test/diff_fixtures/`
and diffs its token stream against that fixture's golden `=== TOKENS ===`
section (those goldens are emitted by the OCaml `Lexer.tokenize_string`). A
fixture flips from `FAIL` to `ok` as the corresponding lexer behavior is ported;
the stage is done when all pass.

## Status

- ✅ Scaffold + harness wiring (token ADT, canonical serializer, runnable entry,
  diff loop).
- ✅ Tokenizer ported: int/float/string/char literals (with escapes
  `\n \t \r \0 \\ \"`, char-only `\'`, and the `\u{…}` unicode escape in **both**
  string and char literals — every escape rule of `lib/lexer.mll`) + hex/bin/oct literals,
  idents/keywords, operators/punctuation, line + nestable `{- … -}` block
  comments, **string interpolation**, the `@`/`AS_AT` adjacency rule, and the
  INDENT/DEDENT/NEWLINE layout algorithm (plus else-continuation filter and
  leading-operator continuation).
- ✅ **Triple-quoted strings** (`""" … """`): only `"""` closes (single/double
  quotes stay literal), raw newlines are kept, `\{…}` interpolates, and the
  content dedents via `stripIndent` when it opens with a raw newline. An
  interpolation opened from a triple string is tracked by a *negative* interp
  depth so the closing `}` resumes the triple continuation (vs the single-string
  one). Covered by `test/diff_fixtures/triple_str.mdk`.
- ✅ **Validated two ways**, both byte-for-byte against the OCaml reference:
  - **17/17 curated fixtures** — `sh test/diff_selfhost_lexer.sh`.
  - **All real `.mdk` files** (every stdlib module + this lexer lexing itself)
    — `sh test/diff_selfhost_lex_files.sh`, which diffs against
    `dev/lextok.exe` (the OCaml reference dumper). FLOAT literal *text* is
    normalized away (OCaml `%g` vs `floatToString`: `1.0` → `1` vs `1.`; the
    TFloat value is identical). One more serialization-only nuance: non-ASCII /
    control bytes in STRING/CHAR render raw (`debugStringLit`) vs `\NNN`-escaped
    (`%S`) — same value, different debug escaping.
- ✅ **Lexer fully in line with the OCaml counterpart** (`lib/lexer.mll`): every
  pattern the reference lexer accepts, the self-hosted lexer accepts, producing
  the identical token *values*. The only divergences are the two
  serialization-only debug-rendering nuances above (FLOAT text, non-ASCII byte
  escaping) — the token values match. The one construct neither lexer handles is
  *nested* string interpolation (a `"…"` string literal inside a `\{…}`
  expression), which the OCaml reference rejects too ("Unterminated string
  literal"), so it isn't valid Medaka and there's nothing to mirror.

### Parser (Stage 1, in progress)

- ✅ Scaffold: `ast.mdk`, the `sexp.mdk` structural dumper, the OCaml reference
  dumper `dev/astdump.exe`, and the diff harness — validation in place *before*
  parse logic, same as the lexer.
- ✅ **Slice 1** (`parser.mdk`): the arithmetic ladder, application, atoms
  (literals, vars/constructors, parens, tuples, list literals), simple param
  patterns, the type grammar, and top-level `DFunDef`/`DTypeSig`.
- ✅ **Slice 2**: the rest of the operator ladder (`||`, `&&`, comparisons,
  `::` right-assoc, `++`), `=>` lambdas, single-line `if`/`then`/`else`, and
  postfix field access (`.field`) — via a generic `chainLeft`/`chainRight`.
- ✅ **Slice 3**: single-line `let … in`, **`match`** with indented arms (the
  first `INDENT`/`DEDENT` layout handling), the full pattern hierarchy
  (constructor application, `::`, tuple, list patterns), and a single-expression
  indented decl body. Validated on `test/parse_fixtures/`.
- ✅ **Rewritten as a monadic combinator parser** (after Phase 136 unblocked
  recursive polymorphic combinators and a perf comparison showed it's perf-neutral
  vs direct recursive descent). Same grammar/AST output (10/10 corpus still
  matches), but dogfoods `do`/`Thenable`/a custom `Parser` monad. The progress
  guard now lives in a primitive `many` (stops on failure *or* no-progress, so it
  can't loop). Recursive parsers must recurse through a `do`-continuation, never
  by passing themselves as a strict argument (that forces a recursive value mid-
  definition → `CamlinternalLazy.Undefined` under strict eval).
- ✅ **Slice 4**: multi-statement indented blocks — bare blocks (`EBlock`) and
  `do`-blocks (`EDo`) with `DoExpr`/`DoBind`/`DoLet` statements.
- ✅ **Slice 5**: effect types (`<IO> Unit`, `<IO, Mut> a`, `<IO | e> a`, the bare
  tail `<e> a`).
- ✅ **Slice 6**: `data`/`record` declarations — inline + block forms,
  visibility prefixes, positional and named-field payloads, `deriving (…)`.
- ✅ **Slice 7**: string interpolation (`"…\{expr}…"` → `EStringInterp` of
  alternating `InterpStr`/`InterpExpr` parts).
- ✅ **Slice 8**: function guards (`EGuards` of `| guard, … = body` arms, incl.
  `<-` pattern-bind guards), unary minus (`EUnOp "-"`, tighter than `*`),
  expression type annotations (`EAnnot`, loosest level) + `_` lambda params
  (`PWild`), and record literal/update expressions (`ERecordCreate` /
  `ERecordUpdate`). **15/15 real `test/diff_fixtures/` files** parse identically.
- ✅ **Slices 9–13**: everything the real stdlib needs —
  - imports (`DUse`/`UsePath`), `extern` (`DExtern`), `export`/`public export`
    visibility, constrained sigs (`TyConstrained`);
  - `where` blocks (`ELetGroup` w/ clause coalescing), range literals
    (`ERangeList`), array literals, as-patterns (`PAs`), full lambda-LHS →
    pattern conversion;
  - block-form `if`/`match` bodies, else-less `if`, `prop`/`test`/`bench` decls;
  - `interface`/`impl` (`DInterface`/`DImpl`: supers, defaults, named impls,
    `requires`, multi-clause methods), the full operator ladder (`|>` `>>` `<<`
    `!` + backtick infix), operator sections (`ESection`), unit/literal
    patterns.
- ✅ **Stage 1 parser complete.** Validated byte-for-byte against the OCaml
  reference (`dev/astdump.exe`) on **all 13/13 real stdlib `.mdk` files**, the
  **15/15 real `test/diff_fixtures/`**, **23/23 curated `test/parse_fixtures/`**,
  and — the milestone — **its own entire 6-file source** (`selfhost/*.mdk`,
  including `lexer.mdk` and `parser.mdk` parsing themselves). The reference
  dumper `dev/astdump.ml` was extended in lockstep so no decl/expr renders as a
  `TODO` placeholder on any stdlib file.
- ✅ **List comprehensions** (`EListComp`, generator/guard/`let` qualifiers),
  added after the fact so `hash_map.mdk`'s `keys`/`values` dogfood
  `[k | (k, _) <- entries m]`. Required extending `dev/astdump.ml` first (it had
  rendered `EListComp` as `TODO`).
- ✅ **Remaining surface-grammar gaps closed** — `function` (`EFunction`), `?`
  (`EQuestion`), array slice/index `e.[lo..hi]`/`e.[i]` (`ESlice`/`EIndex`),
  array range `[|lo..hi|]` (`ERangeArray`), `let mut` + assignment
  (`DoAssign`/`DoFieldAssign`), let-else (`DoLetElse`), do-block function-let,
  range patterns (`PRng`, int + char), `if` match-arm guards, and record
  patterns (`PRec`, `C { f = p, … }` / `C { .. }`). Most needed a
  `dev/astdump.ml` extension first (they were `TODO`). Toy coverage lives in
  `test/parse_fixtures/rare_constructs.mdk`.

  *(Parser combinators were spiked and parked — blocked on Phase 136; see PLAN.)*

- ✅ **Hardening pass (2026-06-04): every SYNTAX.md construct swept through the
  diff harness; all real `parser.mdk` gaps vs the OCaml parser closed.** The
  earlier "coverage complete" claim was optimistic — a systematic sweep found 16
  constructs the OCaml parser accepts that the port rejected or mis-parsed. Now
  added:
  - expression-level `let` forms: `let mut … in`, `let rec … [with …] in`
    (→ `ELetGroup`), annotated `let x : T = e in …` (and `let mut x : T`);
  - as-pattern lambda params `xs@rest =>` (new `EAsPat` node, lowered by
    `exprToPat`; incl. the `(x::_)` `SecLeft "::"`-recovery case from the
    reference `expr_to_pat`);
  - `if let P = e then … else …` (parse-time → two-arm `EMatch`);
  - impl hints `e @Name` (`AT IDENT`/`AT UPPER` → `EVar "@Name"` atom);
  - import aliases `import a.B as C`, Uppercase path components, `import test.…`;
  - end-of-line `where`, `where` over all guard arms, match-arm `where` (both
    placements — the arm body now reuses `parseBodyExpr`);
  - nested record update `{ p | a.b.c = v }` (`desugarDottedField`);
  - **type aliases** (`DTypeAlias`), **newtypes** (`DNewtype`, + `deriving`),
    **top-level `let rec … with`** (`DLetGroup`), **attributes**
    (`@inline`/`@deprecated`/`@must_use` → `DAttrib`), and the unified
    `Con { … }` form → record-create / **`Map` literal** (`EMapLit`) /
    **`Set` literal** (`ESetLit`) / field puns.

  (The sweep also surfaced a lexer gap — `\u{…}` escapes in *strings* lexed as
  `u{…}` — independently fixed on main by `22ca755`, so the parser sees the
  decoded codepoint.)

  The six TODO-blocked nodes (`DTypeAlias`/`DNewtype`/`DLetGroup`/`DAttrib`/
  `EMapLit`/`ESetLit`) needed matching serializers added to **both**
  `dev/astdump.ml` AND `selfhost/sexp.mdk`, plus the AST nodes in `ast.mdk`.
  Validated: **52 real source files** (stdlib + the self-host compiler parsing
  itself) + the `parse_fixtures` corpus byte-match the OCaml reference. The only
  surface both parsers still reject is nested interpolation / (untested)
  triple-quote edge cases — genuinely lexer-side, not a parser gap.

  **✅ Desugar + method_marker now port the Phase-B nodes.** The seven Phase-B
  nodes above (`DTypeAlias`, `DNewtype`, `DLetGroup`, `DAttrib`, `EMapLit`,
  `ESetLit`, `EAsPat`) are now handled by `selfhost/desugar.mdk` and (by reusing
  the same `mapProg` engine) `selfhost/marker.mdk`, byte-for-byte with the OCaml
  reference (`astdump --desugar`/`--mark`):
  - `DTypeAlias`/`DLetGroup` pass through unchanged (the reference's `map_decl`
    leaves them untraversed too — its catch-all — so a method ref inside a
    top-level `let rec … with` body is left un-marked on *both* sides);
  - `DNewtype` deriving expands to generated `impl`s via a synthetic
    single-variant data deriver (`deriveForNewtype` → Eq/Ord/Debug/Display;
    `deriveOrdData`/`lexCompareExprs` added; Num/Generic newtype derivers stay
    deferred — unused by the corpus);
  - `DAttrib` recurses through `expandDecl`/`mapDecl` (attribute stays on the
    head decl, generated impls trail it bare);
  - `EMapLit`/`ESetLit` lower to `(fromEntries [...] :~ Name …)` via
    `lowerContainerLiterals` (after `desugarRecordPuns` rewrites `Name { a, b }`
    record-pun braces to `ERecordCreate`); this required adding the **`EHeadAnnot`**
    node to `ast.mdk`/`sexp.mdk` (the lowering's `:~` head-pin target);
  - `EAsPat` needs no desugar clause — the parser's `exprToPat` already lowers
    `xs@rest =>` to `PAs`, so it never reaches a desugar/mark dump (same as the
    reference, whose `astdump.ml` has no `EAsPat` case).

  Accordingly the lone Phase-B fixture (`decls_extra.mdk`) has **graduated** from
  `test/parse_only_fixtures/` into the shared `test/parse_fixtures/` corpus, now
  consumed clean by `diff_selfhost_{parse,desugar,mark}.sh` (25/95/95). Phase-A
  fixtures (built only from already-handled AST nodes) live in
  `test/parse_fixtures/hardening.mdk` as usual.

  **✅ Phase-B nodes ported through resolve:** `resolve.mdk` now has explicit
  `checkDecl` arms for all three survivors (`DTypeAlias` validates the RHS type,
  `DNewtype` validates the field type, `DAttrib` recurses into the inner decl);
  `dataRecordNames`/`ctorNames` register their type/constructor names in the env;
  `checkExpr` handles `EAsPat` → `AsPatternMisplaced`. `EMapLit`/`ESetLit` are
  eliminated by desugar so need no resolve clause. Three new
  `test/resolve_fixtures/` cases validate against the OCaml reference:
  `type_alias_unknown`, `newtype_unknown`, `as_pat_misplaced`. `sexp.mdk` now
  serializes `EAsPat` and `astdump.ml` matches it (catch-all removed — all `Expr`
  constructors are now explicitly handled). (`test/parse_only_fixtures/` is now
  empty but retained for future parse-only constructs blocked on a later stage.)

## Roadmap — remaining Stage 1 stages

Lexer, parser, **desugar**, **method_marker**, **resolve** (single-file path),
and **exhaust** (both the guard-coverage pass *and*, inside typecheck, the
type-aware `check_match` match-exhaustiveness) are done, as are the **typecheck**
and **eval** capstones. This section sketches how each was ported.

**Validation infrastructure for every remaining stage is already built** (the
"de-risk first" pass):
- `dev/astdump.exe` takes `--desugar` / `--mark` to dump the AST after those
  stages (the `--parse` default is unchanged). `test/diff_selfhost_{desugar,mark}.sh`
  diff the self-host stage against it.
- `dev/diagdump.exe --resolve|--exhaust|--check-match` dumps each stage's diagnostics in a
  canonical, sorted, location-stripped form. `test/resolve_fixtures/` (14) and
  `test/exhaust_fixtures/` (5, incl. negative controls) are the net-new negative
  corpus + committed goldens; `test/diff_selfhost_{resolve,exhaust}.sh` run them.

### The methodology carries over

Every remaining stage is **differentially testable against the OCaml reference**,
the same way the lexer/parser were — and most of the oracle infrastructure
already exists:

- **AST→AST stages** (desugar, method_marker) keep the same `program` type, so
  they dump as S-expressions through the existing `dev/astdump.exe` ↔
  `selfhost/sexp.mdk` machinery. The diff is just `source → both pipelines →
  compare dumps`, and the **entire corpus** (stdlib + `test/diff_fixtures/` +
  `selfhost/`'s own source) becomes the test set for free. First task for each:
  add a dump mode to `astdump` (e.g. run `Desugar.desugar_program` before the
  `strip_locs` dump) and mirror any new/changed node in `ast.mdk`/`sexp.mdk`.
- **typecheck** emits type *schemes* — already serialized as the `=== TYPES ===`
  section of every `test/diff_fixtures/*.golden` (see `dev/gen_golden.ml`). The
  diff is inferred-scheme-per-binding.
- **eval** produces runtime values (closures/refs — not serializable), but its
  **stdout** is already captured as the `=== EVAL ===` golden section. The diff
  is program output: run it, compare what it printed.
- **resolve / exhaust** emit *diagnostics* (error / warning strings) — trivially
  diffable, but they need **negative fixtures** (programs with deliberate unbound
  vars, privacy violations, non-exhaustive matches); today's corpus is all valid
  programs, so this is net-new test material.

Each new IR shape gets the same `ast.mdk ↔ sexp.mdk ↔ dev/astdump.ml` lockstep
treatment used throughout the parser port. Mutable-state-heavy designs re-express
with `Ref` + the `hash_map`/`map` stdlib (which is exactly why those were flagged
Stage-0 prerequisites in `../PLAN.md`).

### Stages, in suggested order (easy-first; hardest last)

| # | Stage | ~LOC | Difficulty | In → Out | Validate via |
|---|-------|------|-----------|----------|--------------|
| 1 | ✅ **desugar** | ~980 | low–med | `program → program` | astdump `--desugar`, **95/95 corpus** |
| 2 | ✅ **resolve** | ~1000 | med | `program → diagnostics` (+ name env) | diagdump `--resolve`, **full corpus + 14 fixtures** |
| 3 | ✅ **method_marker** | ~420 | low–med | `program → program` (marks `EMethodRef`/`EDictApp`) | astdump `--mark`, **full corpus** |
| 4 | ✅ **exhaust** | ~465 | hard (algorithm) | `program → warnings` | diagdump `--exhaust`, **full corpus + 5 fixtures**; type-aware `check_match` via diagdump `--check-match`, **11 fixtures** |
| 5 | ✅ **eval** | ~2350 | hard (plumbing) | `program → values / stdout` | `dev/eval_probe.exe` + **all 16 `=== EVAL ===` goldens** (untyped *and* typed paths) |
| 6 | ✅ **typecheck** | ~4650 | **very hard** | `program → schemes` | `dev/tc_probe.exe` + **all 16 `=== TYPES ===` goldens** |

1. ✅ **Desugar — DONE.** `selfhost/desugar.mdk` + `desugar_main.mdk`: the
   bottom-up `mapExpr`/`mapDecl` engine plus the passes `merge_iface_defaults →
   expand_decl (Eq/Debug/Display/Ord/Generic deriving) → desugar_record_puns →
   lower_container_literals → desugar_list_comps → desugar_questions →
   lower_do_blocks → desugar_sugar`. Matches `astdump --desugar` byte-for-byte on
   the full corpus (95 files, incl. desugaring its own source). Key wins that made
   it tractable: desugar is deterministic with no stateful gensym (positional
   `__a%d` / fixed `__x`,`__fallthrough__` names), and its output uses only nodes
   `sexp.mdk` already renders. **Phase-B nodes now ported** (see the parser
   section): `DNewtype` deriving (synthetic single-variant data deriver),
   `DAttrib` recursion, record-pun desugaring, container-literal lowering
   (`EMapLit`/`ESetLit` → `fromEntries … :~`, the lowering target `EHeadAnnot`
   added to `ast.mdk`/`sexp.mdk`), and `Ord` deriving (`deriveOrdData`). Still
   deferred (unused by the corpus): record derives, `Arbitrary`, and newtype
   `Num`/`Generic`.
   > **Prelude-access prerequisite (NEW — decided next).** Both resolve and
   > method_marker need the *prelude*'s names (resolve seeds prelude
   > value/type/ctor/interface names so a file using `map`/`eq` resolves clean;
   > `--mark` marks prelude-method references — e.g. list.mdk gets 22 EMethodRef
   > for `eq`/`map`/`compare`/…). Desugar didn't need this (purely syntactic on
   > the file). The reference reads them from the embedded `Prelude.program`
   > (= `stdlib/core.mdk`). **Recommended approach** (no new build step, mirrors
   > how the multi-module loader already takes sibling files): have
   > `resolve_main.mdk`/`mark_main.mdk` take the prelude path as an extra arg
   > (`… stdlib/core.mdk <file>`), parse+desugar it, and extract the name sets —
   > the selfhost parser+desugar already match the reference on core.mdk, so the
   > extracted names will match `Prelude.program`'s. The harnesses pass the path.
   > (Alternative: a build-time generated `prelude_names.mdk`, in the spirit of
   > `gen/embed.ml`. Left as a design choice.)
2. ✅ **Resolve — DONE (single-file + multi-module paths).** `selfhost/resolve.mdk` +
   `resolve_main.mdk`: a name environment (lists, not hashtables) seeded with
   primitives + runtime externs (runtime.mdk) + the prelude (core.mdk, both
   passed by path like the marker; `program_is_core` suppresses the prelude seed
   when resolving core itself), then `checkType`/`checkPat`/`checkExpr`/
   `checkDecl` returning **error lists** (pure — no mutable ref; locations
   dropped since the self-host AST has none). Scope threads locally-bound names
   through lambdas/lets/match/do/comprehensions/where-groups; `build_env` collects
   user names + import stubs and detects DuplicateDefinition (order-sensitive,
   seeded) and ExternWithBody. Matches `diagdump --resolve` byte-for-byte on the
   whole corpus *and* the 14 `test/resolve_fixtures/` negative cases — validated
   both ways (right errors on broken files, no false positives on valid ones).
   ✅ **Multi-module path — DONE.** The reference's `resolve_module` is ported
   (`resolve.mdk`'s `ModuleExports` / `buildExports` / `buildEnvMM` /
   `importedNamesMM` / `expandMember*` / `resolveModule` / `resolveModulesToLines`):
   each module's imports are validated against the **real exports** of
   dependency-earlier modules — privacy (PrivateNameAccess), abstract-type ctor
   exports (NoExportedConstructors), unknown modules (UnknownModule), and
   `export import` re-export (including the faithful quirk that a re-exported type
   loses its ctor-export, so a downstream `T(..)` is NoExportedConstructors). The
   runnable entry `resolve_modules_main.mdk` threads `resolveModule` over an
   ordered module list (runtime/core seeded by NAME, undesugared, as in
   `resolve_main`; modules desugared). `test/diff_selfhost_resolve_modules.sh`
   validates it against the new `dev/diagdump.exe --resolve-modules` oracle (which
   drives the real `Resolve.resolve_module`, accumulating exports over an explicit
   ordered file list — and, by *not* going through the Loader, makes UnknownModule
   reachable where the Loader would fail on the missing file first) on 6
   `test/resolve_module_fixtures/` cases **plus the entire selfhost module graph**
   (no false positives, both directions agree).
   The three single-file misplacement errors are ported — **QuestionMisplaced**
   (`?` outside a `let` RHS), **NonRecursiveValueLet** (`let x = … x …` without
   `rec`, re-targeting the UnboundVariable), and **AsPatternMisplaced** (`x@..`
   in a non-binding expression position, via `EAsPat`), each with a
   `test/resolve_fixtures/` case. `sexp.mdk` and `astdump.ml` now both serialize
   `EAsPat` as `(EAsPat ...)` (the `astdump.ml` catch-all is fully removed).
   **Perf hook (still open):** give each variable reference a resolved
   `(frame, slot)` address — see *Performance* below.
3. ✅ **Method_marker — DONE.** `selfhost/marker.mdk` + `mark_main.mdk`:
   interface-method / constrained-fn `EVar`s → `EMethodRef`/`EDictApp` (just the
   name; the typecheck-filled ref is irrelevant pre-typecheck), backtick `EInfix`
   with a marked op → prefix-applied marked ref, methods take precedence. Name
   sets union the prelude + target; the marker reuses desugar's `mapProg`. The
   **prelude-via-path approach worked** — `mark_main` takes `stdlib/core.mdk` as
   an arg and extracts the name sets from a parse+desugar of it. The
   prelude-shadowing logic is fully ported: Phase 78b (`shadow_rename` —
   `map.mdk`'s standalone `isEmpty` → `isEmpty#shadow`) and Phase 78a (drop a
   *droppable* shadowed prelude constrained fn from the constrained set — `count`/
   `find` dropped, `clamp` kept because a core prop references it). Matches
   `astdump --mark` byte-for-byte on the whole corpus, incl. the marker marking
   its own source. Simplification still standing: `shadow_rename` skips the
   "name is also a local binder" exclusion (no corpus file triggers it).
4. ✅ **Exhaust — DONE (guard-coverage pass).** `selfhost/exhaust.mdk` +
   `exhaust_main.mdk`: the standalone `check_guard_exhaustiveness` (Phase 91(2))
   over the **raw pre-desugar AST** (function/where guards still `EGuards`).
   Warns once per same-name clause group whose guards may fall through *unless*
   the non-falling-through clauses' patterns already cover every input — decided
   by a faithful port of the Maranget `useful` pattern-matrix recursion
   (`specialize`/`default`/`head_ctors`/`useful`), with multi-param coverage
   reduced to one synthetic `__tupleN__` column. The constructor oracle is built
   from the file's own data decls + the syntactic builtins (Bool/List/Unit), so
   **no prelude is needed**. Groups gathered from top-level `DFunDef` clauses,
   `where`/let-group (`ELetGroup`) clauses reached anywhere in a body, impl
   methods, and interface defaults. Matches `diagdump --exhaust` byte-for-byte on
   the full corpus + all 5 `test/exhaust_fixtures/` cases (incl. the
   `useful`-machinery "excused by catch-all" control and the multi-warning case).
   The type-aware `check_match` exhaustiveness lives inside typecheck (it needs
   the scrutinee type) and is now **also ported** — see the typecheck stage below
   and `check_match_main.mdk`; it **reuses** this file's exported `Oracle` /
   `buildOracle` / `useful` / `desugarPat` / `tupleCtorName` matrix machinery, the
   only difference being the type-aware ctor oracle and scrutinee column type.
5. 🚧 **Eval — IN PROGRESS (slice 1 of N).** The **Stage-1 capstone**: a
   tree-walk interpreter (`selfhost/eval.mdk` + `eval_main.mdk`) that makes the
   self-hosted compiler *executable on itself*. Plumbing-heavy (per-frame env
   refs, `VMulti` typeclass dispatch, dict-passing semantics) but not
   algorithmically deep. **Validation bridge:** rather than wait for typecheck,
   the engine is exercised on the UNTYPED path — `dev/eval_probe.exe`
   (`Eval.eval_program ~prelude:false` → `Eval.pp_value`) is the oracle, and
   fixtures in `test/eval_fixtures/` are self-contained / prelude-free, each
   aggregating its results into one `main` value rendered by `pp_value`
   byte-for-byte on both sides (`test/diff_selfhost_eval.sh`).
   - **Slice 1 (DONE):** the engine core — literals, vars, application, lambdas/
     closures, let / letrec / let-groups, bare blocks, `match` (+ guards), `if`,
     binary/unary operators (incl. structural `==`/`<` mirroring OCaml's
     `=`/`compare` on `value`), tuples, lists, ADTs (constructor builders +
     pattern matching), multi-clause dispatch (`VMulti`, first-pattern-match),
     and recursion. The env is `(name, Ref value)` frames back-patched via
     `set_ref` (so the cluster carries `<Mut>`; `VPrim` holds a `Value -> <Mut>
     Value`). 7/7 fixtures match.
   - **Slice 2 (DONE):** arrays (`VArray`, `EArrayLit`), indexing (`a.[i]`),
     slicing (`a.[lo..hi]`), and ranges (`[lo..hi]` / `[|lo..=hi|]`), plus the
     **extern kernel** — each primitive a `VPrim` wrapping the reference's own
     native extern with the Value-boundary marshalling `lib/eval.ml`'s
     `primitives` table does (e.g. `stringToChars` wraps native chars into
     one-codepoint `VChar`s; `charFromCode`/`stringIndexOf` return `Some`/`None`
     `VCon`s; `stringCompare` returns `Lt`/`Eq`/`Gt`). Curried multi-arg externs
     nest `VPrim`s. Covers the int/string/char/array kernel (IO/Rand/Panic
     externs are out of scope — the oracle compares a computed value, not
     effects). 9/9 fixtures match.
   - **Slice 3 (DONE):** records and refs — `record`-declared values as
     `VRecord` (create / `.field` access / `{ r | f = v }` update / `Point { x,
     y }` patterns; no constructor-field-order map needed since `record` types
     aren't in `ctor_field_order`), `VRef` + `Ref`/`set_ref` externs + `.value`
     read, and block-local rebinding (`let mut` / `x <- e` via `DoAssign`).
     11/11 fixtures match. (Named-field *data variant* constructors — the VCon
     `ctor_field_order` path + `EVariantUpdate` — now implemented in §2.3 item 1
     via `CVariantUpdate` throughout the Core IR pipeline + `ctorFieldOrdersRef`.)
   - **Slice 4a (DONE) — typeclass method dispatch (user-defined).** `VTypedImpl`
     (head-type tag, dispatch positions, args-seen) + a process-global ctor→type
     table (a top-level `Ref`, mirroring `lib/eval.ml`'s `ctor_to_type` Hashtbl)
     feeding `runtimeTypeTag`. `DInterface`/`DImpl` install: each impl method is
     tagged `VTypedImpl` and same-named methods coalesce into one `VMulti`, sorted
     most-specific-first by free-type-var count; interface **defaults** install
     untagged as a fallback. `apply` gained the `VMulti` arg-tag filter (only
     candidates at a dispatching slot are filtered; if all are filtered out the
     original set is kept) and a tag-preserving `VTypedImpl` arm. Dispatch
     positions come from `dispatchPositionsOf` walking each method's declared
     type for args mentioning the interface type param. Validated on
     self-contained interface/impl fixtures via the existing `prelude:false`
     oracle — 14/14 fixtures match (multi-method interfaces, recursive ADTs,
     default + override).
   - **Slice 4b (DONE) — prelude loading.** `selfhost/eval_prelude_main.mdk`
     prepends the parsed+desugared `core.mdk` (by path, like the marker/resolve
     stages) and evaluates the whole thing, so the eval runs **real
     prelude-using programs**: `Eq`/`Ord`/`Debug`/`Display`/`Num` methods and
     `deriving` all dispatch through `core.mdk`'s impls. Validated against
     `eval_probe --prelude` (`eval_program ~prelude:true`, the embedded prelude)
     — `test/eval_prelude_fixtures/` (3 fixtures: `debug`/`display` over builtin
     + nested types, `Eq`/`Ord` builtin + derived, numeric/combinators).
     Mechanisms added: **`VThunk`** lazy deferral of nullary top-level bindings
     (forced + memoised on first lookup, so point-free prelude defs can reference
     anything installed later, any order); point-free impl methods either deferred
     (`VThunk`, return-position) or **eta-expanded** (`\$eta => body $eta`,
     arg-dispatched, Phase-121 style); and the rest of the pure extern kernel
     (`debugStringLit`/`debugCharLit`, char predicates, bounds, `stringToFloat`).
   - **Still out of scope (untyped-path limits):** **return-position dispatch**
     that needs types — `empty`/`pure`/`minBound` with no discriminating arg stay
     a `VMulti`/error, exactly as the reference's untyped path does; matching the
     typed `=== EVAL ===` goldens for *those* programs would need the elaborated
     (typed + dict-passed) AST. Also still deferred: IO externs (`putStr` etc.) —
     the oracle compares a computed `main` value, not stdout.
   It can be developed against the **reference's** typed + dict-passed AST, so it
   does **not** require typecheck to be ported first; `dict_pass` is the small
   prerequisite for the method-dispatch slices.
6. 🚧 **Typecheck — IN PROGRESS (slice 1 of N).** The complexity engine,
   deliberately last: Hindley–Milner unification (union-find over mutable cells,
   occurs-check), interface/impl coherence, and the Phase-69/69.x dictionary-
   passing elaboration. **Validation bridge:** like eval, the engine is exercised
   WITHOUT the prelude — `check_program_no_prelude` (a `~prepend_prelude` flag
   gating the prelude prepend / impl seeding / registry check) is the oracle via
   `dev/tc_probe.exe`, and `test/typecheck_fixtures/` are self-contained. Because
   the `=== TYPES ===` rendering is `pp_scheme = pp_mono` (constraints dropped),
   the engine slice needs only the HM core, not the dict-passing layer.
   - **Slice 1 (DONE):** `selfhost/typecheck.mdk` + `typecheck_main.mdk` — the HM
     core: `Mono` (`Ref`-based union-find tyvars) / `Scheme = Forall ids mono`,
     level-based `generalize`/`instantiate`, `unify` (occurs-check + level
     adjust), `pp_mono` (matching the reference renderer — `a,b,c…` by
     appearance, `TApp`/`TFun` precedence parens), and `infer`/`inferPat` for
     literals, vars, application, lambdas, let (let-poly), let-groups, if,
     tuples, lists, annotations, ADT constructors (`DData` → ctor schemes), and
     match. 3/3 fixtures match (combinators, ADTs+patterns+recursion, let-poly).
   - **Slices 2–8 (DONE):** operators (by shape), type signatures, interface
     method schemes, records, effect-row annotation labels, externs, and finally
     **dependency-ordered SCC-merged letrec processing** — the prelude has
     forward references and mutual recursion throughout, so groups are
     type-checked in topological order (a callee generalized before its callers
     instantiate it) with cycles merged into one letrec group. With runtime.mdk's
     externs seeded into scope (not output, mirroring `initial_env`'s
     `Runtime.entries`), the self-hosted typechecker infers the **entire
     `core.mdk` prelude** (84/84 schemes) and matches **all 16 `=== TYPES ===`
     goldens** (full prelude + user program) byte-for-byte. The key correctness
     point: a signed binding reports its sig *unified with its body* generalized
     (so `sum : (Foldable t, Num a) => t a -> a` with body `fold (+) 0` reports
     the specialized `a Int -> Int`), not the raw sig.
   - **Not needed for `=== TYPES ===` (constraints aren't rendered):** the
     constraint-solving / coherence / dict-passing machinery. It IS needed for a
     complete self-hosted *elaboration* (mark → typecheck → dict_pass → eval), but
     the type-scheme output the goldens check is constraint-free.
   - **Error accumulation (DONE 2026-06-05):** `typeMismatch` and the
     occurs-check now push `"Type mismatch: …"` / `"Cannot construct infinite
     type involving …"` to a `typeErrors : Ref (List String)` accumulator instead
     of panicking.  `bindVar` guards the union-find link behind a
     `occursCheckFailed` flag so no cyclic cell is written.  `checkToLines` /
     `checkToLinesWithRuntime` emit `TYPE ERROR: <msg>` lines when errors exist
     (matching `tc_probe.exe`'s format) and suppress the scheme output, matching
     the reference's single-exception behavior.  Validated by
     `test/diff_selfhost_typecheck_errors.sh` (3 fixtures × 2 drivers:
     `typecheck_main` + `check.mdk`; int-vs-string mismatch, tuple-arity
     mismatch, occurs-check).
   - **Type-aware match exhaustiveness (`check_match`) — DONE 2026-06-05:**
     `inferMatch` runs the exhaustiveness check after each `match`'s arms have
     unified the scrutinee type, pushing `Warning: non-exhaustive match — some
     values may not be covered` to a `matchWarnings : Ref (List String)`
     accumulator when an all-wildcard query is still `useful` against the matrix
     of the **non-guarded** arms.  It **reuses** `exhaust.mdk`'s exported matrix
     machinery (`Oracle`/`buildOracle`/`useful`/`desugarPat`/`tupleCtorName`);
     the only difference from the guard pass is the column-0 oracle — here the
     ctor set comes from the program's data decls + the inferred scrutinee type's
     head (a tuple maps to a synthetic `__tupleN__` type), set in `matchOracle`
     by the `checkMatchToLines` driver.  The redundancy pass is **not** ported
     (the `--check-match` oracle dumps only the non-exhaustive-match warnings).
     Validated by `test/diff_selfhost_check_match.sh` (11 fixtures: non-exhaustive
     user ADT / Bool / list / tuple / nested-ctor / Int-literal / guarded-arm /
     multi-match, plus exhaustive + wildcard controls) against the net-new
     `dev/diagdump.exe --check-match` oracle.
   - **Genuine remaining limits** (don't surface in the goldens): none in this
     bucket. (Inferred effect *propagation* was a limit here until the Phase 146
     selfhost mirror — now ported; see *Known limits carried forward* below. The
     "signature too general" error is also ported now — `checkSigsTooGeneral` in
     `processSCC`.)

**Ordering rationale.** Easy-first builds momentum and reuses the existing
harness while Medaka fluency matures, leaving the type checker for last. Note the
dependency wrinkle: a *complete* self-hosted pipeline also needs `dict_pass`
(small), and the reference's `Elaborate` two-pass orchestration (mark →
typecheck → re-mark → re-typecheck → dict_pass) must be mirrored once both ends
exist.

**End state of Stage 1.** A Medaka-written front-end
(lex → parse → desugar → resolve → mark → typecheck → exhaust) plus the
interpreter (eval), all running on the existing OCaml interpreter and validated
stage-by-stage against the reference — at which point the self-hosted compiler
can process its own source (the bootstrap). Stage 2 (a Core IR + bytecode VM,
then the LLVM backend) follows; see `STAGE2-DESIGN.md` for the architecture
decision and the staged plan, and **North star → Stage 2** in `../PLAN.md`.

**Stage 2 §2.1 — Core IR, slices 1/3/5 (2026-06-05).** The serializable,
backend-neutral Core IR (`core_ir.mdk`) + the elaborated-AST → Core IR lowering
(`core_ir_lower.mdk`) + a direct Core-IR evaluator (`core_ir_eval.mdk`) are in,
validated by EQUIVALENCE (§2.1's net-new-IR oracle): evaluating the lowered IR
matches evaluating the AST. Coverage now spans six corpora, all byte-identical
to the AST tree-walker:
- **engine** (`diff_selfhost_core_ir.sh`, 19) — slice 1 core + slice 3
  (records / refs / arrays / ranges / index / slice / blocks) + slice 5
  (arg-position typeclass dispatch via installed `VMulti`s);
- **prelude** (`diff_selfhost_core_ir_prelude.sh`, 5) — real core.mdk dispatch
  (Eq/Ord/Debug/Display/Num + deriving) through the slice-5 impl install;
- **list** (`diff_selfhost_core_ir_list.sh`, 2) — + list.mdk combinators /
  comprehensions;
- **typed** (`diff_selfhost_core_ir_typed.sh`, 2) — the `CMethod` arm:
  return-position dispatch (RKey), e.g. a user Applicative's `pure`, lowered from
  the typechecker's stamped `EMethodAt` routes.
- **run** (`diff_selfhost_core_ir_run.sh`, 18) — true execution: the program's
  captured stdout (putStr/putStrLn) over the `=== EVAL ===` goldens, via
  `core_ir_run_main`'s `cevalOutput` (prelude-shadow-dropped, like `eval_run`).
- **modules** (`diff_selfhost_core_ir_modules.sh`, 4) — the loader-driven path:
  per-module Core-IR frames over a shared prelude (`cevalModules`), diffed against
  the AST `eval_modules` over the `eval_modules_fixtures` corpus.

**Stage 2 §2.1 — Core IR serializer + round-trip (2026-06-05).** A canonical
S-expression serializer (`core_ir_sexp.mdk` / `cprogramToSexp`) + deserializer
(`core_ir_sexp_parse.mdk` / `parseCProgram`) + two new gates:
- **snapshot** (`diff_selfhost_core_ir_sexp.sh`, 18) — dumps the Core IR for
  each engine-corpus fixture and diffs against committed goldens in
  `test/core_ir_sexp_fixtures/`; catches accidental lowering or serializer drift.
  Goldens are regenerable when an intentional IR change is made.
- **round-trip** (`diff_selfhost_core_ir_roundtrip.sh`, 18) — the real "frozen IR
  is faithful" gate: lower → `cprogramToSexp` → `parseCProgram` → `cevalMain` →
  `pp_value`, diffed byte-for-byte against `dev/eval_probe.exe` (the AST tree-
  walker). A passing result proves the serialization is semantics-faithful: a
  deserialized `CProgram` evaluates identically to the freshly-lowered one.
  Losslessness includes `Addr` on every `CVar` and `Route` on every
  `CMethod`/`CDict`. The format is also the LLVM contract input: a backend
  consuming the sexp gets the complete, stable IR without depending on the
  Medaka runtime or the self-hosted compiler's in-memory state.

The slice-3 value work (build / deref / index / range) and the slice-5 impl
machinery (`declImplEntries`/`coalesceImpls`/`narrowMethod`/`applyDicts`) are
REUSED verbatim from `eval.mdk` — the Core-IR arms only thread `ceval` and hand
Values to the shared host runtime, keeping one runtime (Axis-2 discipline). The
**multi-module driver** (`cevalModules`/`cevalModulesOutput` in `core_ir_eval.mdk`)
likewise mirrors `eval.mdk`'s `evalModules` structurally — prelude installs
globally, each module's lowered `CBind` groups install into its own local frame
(`CModInfo`), ctors + impls coalesce globally, and the value-agnostic import-frame
machinery (`importFrameOf`/`pubReexports`) is reused verbatim; the only Core-IR
delta is the per-module LOWERING (`lowerGroups` + `lowerImplsWith` against the
joint dispatch table).

**Decision-tree match compilation — DONE (all patterns).** `lower (EMatch …)`
compiles a match's ordered arms into a `CDecision scrut arms tree` (a decision
tree over `CTree`/`CTBranch`/`CHead`), driven by the same Maranget pattern
matrix (`specialize`/`default`/head-ctors) the exhaust stage uses — only the
*output* differs (a tree, not a usefulness verdict). The tree tests each
scrutinee field's head once across all arms instead of re-testing per clause;
leaves carry an arm INDEX and the evaluator re-matches that one arm's pattern to
recover its bindings (a single per-arm walk), so the tree itself needs no
occurrence/binding bookkeeping. Guard fall-through is preserved by `CTGuard i
fail`: a failed guard resumes the ordered semantics over the matrix rows below
the guarded clause, compiled at the same column context so it reads the same
live sub-values. The evaluator (`cevalDecision`/`cevalTree`/`headExtract`)
reuses `eval.mdk`'s `matchPat` for BOTH the head test and field extraction, so
no new value-shape code is needed for any pattern form. **PRec and PRng** are
now also tree-compiled: both canonicalize to `PWild` in the Maranget matrix (the
same treatment as `exhaust.mdk`'s `desugarPat`), arms containing them are marked
as `CTGuard` leaves (via `patNeedsGuard`), and a `matchPat → None` at a guarded
leaf falls through to the `fail` subtree rather than panicking — preserving the
ordered semantics for patterns that may not match (range bounds, specific field
values). All 18 engine-corpus fixtures (including `records` and
`string_ranges_infix`) now route through the tree; all six Core-IR equivalence
harnesses stay byte-identical. **Remaining:** the slot-*indexing* consume half
of lexical addressing (STAGE2 §2.0) is still its own parked supervised rework —
the Core IR already carries the addresses.

**Stage 2 §2.2 — bytecode compiler + stack VM, SLICE 1 (2026-06-05).** The first
lowering of the Core IR *below* an ISA (`bytecode.mdk` + `eval_bytecode_main.mdk`
+ `test/diff_selfhost_eval_bytecode.sh`). `compile : CExpr -> List Instr` emits a
flat, position-independent instruction stream (relative jumps, so a compiled
sub-expression concatenates freely) for the slice-1 engine primitives the design
lists first — "arithmetic + variables (slot-indexed) + application" — plus the
trivial non-pattern/non-closure nodes needed to form a runnable whole program
(literal constants, primitive binops/unops, tuples, lists, `if`, let-sequencing
blocks). `runChunk` is a stack machine threading `(ip, value-stack, env)` over the
`Instr` `Array` (O(1) ip-indexed fetch). It is validated by EQUIVALENCE against
the AST tree-walker, the SAME oracle (`dev/eval_probe.exe`) and harness *shape*
the §2.1 gates use — **4 slice-1 fixtures byte-identical, 12 deferred** to the
slices that will cover them (~0.5s, no new fixtures — reuses the engine corpus).

Reuse discipline (Axis 2 / §2.2 "reuse the host Value/GC/externs") is honoured
strictly: the VM reuses `eval.mdk`'s runtime verbatim — `Value`, env,
`applyValue`/dispatch/fall-through, `matchPat`, the arithmetic kernel, externs,
`pp_value`. A compiled function installs as a `VClosureF` whose host-fn body is
`\e -> runChunk e chunk`, so CLOSURE CREATION, MULTI-CLAUSE DISPATCH and
PATTERN-PARAM BINDING are delegated to the host `applyValue` (exactly as
`core_ir_eval.mdk` does); the VM only ever compiles + runs EXPRESSION bodies. The
on-ramp condition (Axis 1) holds — the throwaway part (the ISA + VM loop) sits
cleanly below the reused Core IR. **Zero `eval.mdk` changes**: every reused name
was already exported (the §2.1 `VClosureF` affordance suffices for the VM too).

**Stage 2 §2.2 — SLICES 2 and 3 (2026-06-05).** Extended `bytecode.mdk` to cover
`match` via compiled decision trees (slice 2) and ADTs/records/refs (slice 3).

Slice 2 adds three instructions: `IMatchArms (List BcArm)` for ordered-arm `CMatch`
dispatch (used when arms contain PRng/PRec patterns or non-tree-able heads); 
`IMatchDecision (List BcArm) CTree` for decision-tree `CDecision` dispatch; and
`IBindFail Pat Int` for `CSLetElse` pattern-bind-or-else. The `BcGuard`/`BcArm`
types compile each arm's body and guards to `Chunk` values at install time; the
step functions call `runBcMatchArms` / `runBcDecision` (mirroring `cevalMatch` /
`cevalDecision` from `core_ir_eval.mdk`) which walk arms/trees and run compiled body
chunks via `runChunk`. `headExtract` + `cBinders` reuse `matchPat` for value
decomposition so no new value-decomposition code is needed. CTGuard fall-through for
PRng/PRec arms is preserved exactly — `bcGuardedBody` resumes the fail subtree when
`matchPat` returns `None`, identical to `cevalGuardedBody`.

Slice 3 adds `IMakeArray`, `IMakeRecord`, `IField`/`IFieldValue`, `IRecordUpdate`,
`IRangeList`/`IRangeArray`, `IIndex`, `ISlice` — plus `CSAssign` (compiled as
`IBind (PVar x)`, an env rebind) in `compileStmts`. The value-level work
(`evalRecordUpdate`, `evalField`, `evalValueField`, `evalRange`, `evalIndex`,
`evalSlice`) is reused verbatim from `eval.mdk`; the step functions only route
opcodes to those helpers.

**Gate: 11 ok, 0 failing, 7 deferred** (slice 4: closures/letrec/where; slice 5:
typeclass dispatch). Two new fixtures added to `test/eval_fixtures/` — `range_pat_tree`
(range patterns through CTGuard decision-tree leaves) and `rec_pat_tree` (record
patterns, requires both slice 2 + slice 3). Total ~1s. **Zero `eval.mdk` changes**.

**Stage 2 §2.2 — SLICES 4 and 5 (2026-06-05).** Closures, letrec, where-blocks, and
typeclass dispatch. All 7 formerly-deferred fixtures now active: **18 ok, 0 failing,
0 deferred (~1.5s). Zero `eval.mdk` changes.**

Slice 4 adds four instructions: `IMakeClosure` (CLam → push a `VClosureF` closing over
the current env, body pre-compiled to a `Chunk` at install time); `ILetBound`
(non-recursive let-in: eval rhs chunk, bind via `matchPat`, eval body chunk in extended
env); `ILetRec` (recursive let: create a `Ref` cell, `pushFrame`, eval rhs — which can
reference the cell — back-patch, eval body); `ILetGroup` (where-block / local
mutually-recursive group: allocate cells, `pushFrame`, install via `bcInstallLetBinds`
— eager `runChunk` for nullary single-clause, `VClosureF` for parameterised, `VMulti`
for multi-clause — exactly mirroring `cevalLetGroup`/`cGroupValue`). `VThunk` laziness
stays TOP-LEVEL only (`bcGroupValue`/`bcThunk`); local let-groups are EAGER for
nullary, matching the tree-walker exactly.

Slice 5 adds `IMethod` (CMethod — `narrowMethod (lookupEnv env name) (routeTag env route)`)
and `IDict` (CDict — `applyDicts env (lookupEnv env name) routes`), and updates
`bcEvalProgram` to install typeclass impls as arg-tag `VMulti`s (via `coalesceImpls`)
BEFORE top-level user groups, mirroring `cevalProgram`'s install order.
`bcImplBodyValue` / `bcImplMethodValue` compile impl bodies to `Chunk`s at install time
(once per clause, not per call): `VThunk` for return-position nullary, eta-expand for
dispatch-position nullary (Phase-121 point-free dispatch preserved), `VClosureF`
otherwise. All dispatch helpers delegate to `eval.mdk`'s existing implementations —
no new dispatch logic in the VM.

**Stage 2 §2.2 — SLICE 6 (2026-06-05).** Multi-module per-module frames.
`bcEvalModules`/`bcEvalModulesOutput` mirror `cevalModules` in `core_ir_eval.mdk`
EXACTLY, swapping only `cInstallTopGroups` (ceval closures) for `bcInstallGroups`
(bytecode VM closures).  `BcModInfo` mirrors `CModInfo`; `bcBuildModInfos` lowers each
module's groups (`lowerGroups`) and impls (`lowerImplsWith`) to Core IR, allocates
per-module local cells, and builds a three-frame env `[localCells, imports, globalCells]`
— the same import-frame machinery (`importFrameOf`/`pubReexports`) reused verbatim.
Prelude installs globally; each module's CBind groups install via `bcInstallGroups`
(VThunk/VClosureF/VMulti, same as top-level single-file); ctors + impls coalesce
globally via `coalesceImpls`.  **4/4 fixtures byte-identical (`test/diff_selfhost_eval_bytecode_modules.sh`).
Zero `eval.mdk` / `core_ir_eval.mdk` changes.**  §2.2 is complete.

---

## Where we are now (all eight stages done) + what's next

All eight stages have validated self-hosted ports matching the OCaml reference
byte-for-byte, plus two integration milestones beyond per-stage validation:

- **Composed front-end** — `selfhost/check.mdk` wires parse → desugar → resolve →
  exhaust → typecheck into one program (`test/diff_selfhost_check.sh`: reproduces
  all 16 `=== TYPES ===` goldens *and* the 9 resolve diagnostics).
- **True execution** — `selfhost/eval_run_main.mdk` runs programs for their stdout
  (output captured to a buffer), matching all 16 `=== EVAL ===` goldens
  (`test/diff_selfhost_eval_run.sh`).
- **Typed eval path (return-position dispatch / RKey)** —
  `selfhost/eval_typed_main.mdk` threads desugar → `typecheck.elaborate` → eval on
  one shared tree, so `pure`/`empty`/do-blocks in a user monad dispatch by their
  concrete return type (`test/diff_selfhost_eval_typed.sh`, oracle = `medaka run`).
  This is the *only* part of dictionary-passing the compiler needs — see below.
- **Type-aware match exhaustiveness (`check_match`)** — the last Stage-1 stage
  piece, ported inside `typecheck` (`inferMatch` → `checkMatchToLines`, reusing
  `exhaust.mdk`'s matrix machinery), validated by `test/diff_selfhost_check_match.sh`
  against the net-new `dev/diagdump.exe --check-match` oracle (11 fixtures).

**What's next.** Every Stage-1 stage and sub-pass now has a validated self-hosted
port; the remaining genuine work is the broader Stage-2 backend (Core IR slices +
bytecode VM, then LLVM) tracked in `../PLAN.md` and `STAGE2-DESIGN.md`. (Inferred
effect *propagation* was a gap here until the Phase 146 selfhost mirror — now
ported; the "signature too general" error is also ported now.)

### The bootstrap (#3) — "the compiler processes its own source"

The decisive self-hosting milestone: run the self-hosted compiler on the
`selfhost/*.mdk` sources themselves.

#### ✅ Multi-module typecheck front-end — DONE

The self-hosted front-end (loader → desugar → multi-module typecheck) now
typechecks **all 13 of its own modules** (incl. the §2.0 `annotate`) and matches the OCaml reference
byte-for-byte. Validated by `test/diff_selfhost_check_modules.sh` against
`dev/tc_module_probe.exe` (the reference doing the same: real `Loader` +
`typecheck_module`).

- **`selfhost/loader.mdk`** — port of `lib/loader.ml`: DFS topo-sort over a
  module's transitive `import`s (cycle detection via an in-progress stack),
  parsing each via the self-hosted parser. Simplified for the flat single-root
  selfhost tree (no subdir `/`↔`.` rewriting, no LSP buffer, no multi-root
  ambiguity). `loader_main.mdk` prints the order (matches the reference DFS).
- **`typecheck.checkModules`** (+ `check_modules_main.mdk`) — threads per-module
  exports in dependency order. The prelude (core) is checked once and all its
  schemes + data decls seed every module; each module then contributes only its
  **public** value schemes (private helpers stay module-local — the
  per-module-frame property without a frame, so same-named helpers across modules
  never collide) plus its public data decls (re-registered so imported ctors +
  named-field-variant record info resolve). **No `eval_modules` needed** — the
  front-end is typecheck-only.
- **`dev/tc_module_probe.exe`** — the reference oracle: loader + threaded
  `typecheck_module`, dumping the entry module's own schemes (the multi-module
  analog of `tc_probe`).

Three genuine **self-hosted-typecheck fixes** the real modules exposed (none hit
by any single-file golden, so latent until now):
1. `registerVariants` now registers record info for **named-field data variants**
   (`C { f : T }`, e.g. ast's `DInterface`) — keyed by the constructor, result
   type the data type — so `C { f, … }` patterns/literals resolve.
2. `infer` + `allEVars` gained an **`EVariantUpdate`** arm (`C { base | f = v }`,
   e.g. desugar's `DInterface { d | methods = … }`) — a core node desugar leaves.
3. **`cell.value`** (Ref projection) types by unifying the receiver with `Ref a`
   (so it works even when the receiver is still an unsolved tyvar — the
   self-hosted typecheck infers fn params as fresh vars, not pinned to the sig).

The one effect-annotation gap (`check.mdk`'s unsigned IO wrappers inferred `Unit`
vs the reference's `<IO, Mut> Unit` — the inferred-effect-propagation limit below)
was originally worked around by **signing those wrappers** (per the house style: a
sig on every top-level fn). Effect inference has since been fully ported (Phase 146
selfhost mirror, 2026-06-06), so unsigned wrappers now propagate effects too.

#### Remaining for the full bootstrap

1. ✅ **Multi-module EVAL path — DONE.** `eval.evalModules` (+ the runnable
   `eval_modules_main.mdk`) is the loader-driven analog of `evalOutput`: a port
   of `lib/eval.ml`'s `eval_modules`. The prelude (core) installs **globally**
   (all names global); each loaded module's top-level funDefs are **local**, so
   same-named functions across modules stay isolated (Phase 110), while ctors and
   impl methods coalesce **globally** into one coherent `VMulti` per interface
   method. Modules arrive dependency-first (loader order); a module's `import`s
   resolve to the exporting module's cells. The reference's explicit
   deferred-thunk install ordering (Phase 125) is unnecessary here — `VThunk`
   laziness defers every nullary binding to its first lookup, by which point all
   modules' impls are installed. **UNTYPED path** (no typecheck / dict-pass /
   marker), like `evalOutput` — correct for the RKey-only bootstrap source and
   any program without return-position dispatch or `=>`-constrained polymorphism.
   Validated by `test/diff_selfhost_eval_modules.sh` (4 fixtures in
   `test/eval_modules_fixtures/`: cross-module function+ADT, private-helper
   isolation, cross-module interface/impl coalescing, derived `Eq`/`Debug` over
   an imported type), oracle = `medaka run <entry>` (the reference Loader →
   typecheck → `eval_modules`), the same oracle `eval_typed_main` uses.
   Simplification vs the reference: a module exposes **all** its local funDef
   cells as exports (not just `pub` ones) — correct for programs that already
   passed resolve, since a private name is never referenced cross-module — plus
   the cells re-exported by a `pub import`.
2. ✅ **The `Env` constructor clash — DONE.** Eval's `data Env` was renamed to
   `EvalEnv` (resolve.mdk keeps its `record Env`), so a future driver co-loading
   **both** resolve and eval (the full pipeline incl. eval — not the front-end,
   which omits eval) no longer collides on the globally-installed constructor.
3. ✅ **Self-processing target — DONE.** The "it checks/runs itself" closure,
   validated by **`test/diff_selfhost_selfproc.sh`** (the consolidated milestone
   harness) in two legs, using `all_modules_entry.mdk` as the aggregate entry:

   - **Leg A — front-end "checks itself" (the decisive closure).** ONE run of
     `check_all_main.mdk` over `all_modules_entry.mdk` feeds the **whole** selfhost
     source through the self-hosted multi-module front-end (loader → desugar →
     `checkModules`); every module's inferred schemes are diffed against the OCaml
     reference (`dev/tc_module_probe.exe`, real Loader + threaded
     `typecheck_module`). The self-hosted front-end is itself **executed by the
     OCaml `eval_modules` oracle** (`medaka run check_all_main.mdk …`), so a pass
     means: *self-hosted front-end (run on eval_modules) == OCaml-native front-end,
     for all 13 modules of its own source.* (This is the union-closure form of
     `diff_selfhost_check_modules_batch.sh`, promoted to the milestone gate.)
   - **Leg B — eval engine "runs itself."** A real selfhost **stage module** (the
     lexer) is executed through the **self-hosted** eval path (`eval.mdk`'s
     `evalModules`, the untyped per-module-frame tree-walker) over an embedded
     Medaka snippet (`selfhost/selfproc_lex_probe.mdk`), and its token stream is
     diffed against the `eval_modules` oracle (`medaka run <probe>`). Byte-identical
     output proves the self-hosted evaluator correctly **executes** a real selfhost
     stage. This required one minimal additive fix to the self-hosted eval's
     primitive table — `arrayMakeWith` (a higher-order extern: it applies the
     builder `Value` back through `apply`, hence `<Mut>`) was missing, so any
     self-hosted eval of the lexer (`lexer.mdk:278`) or `eval.mdk`'s own slice path
     (`eval.mdk:681`) previously panicked `unbound variable: arrayMakeWith`.

   - **Leg C — TYPED eval engine runs a `Parser`-monad stage.** The same
     self-execution as Leg B, but for a stage whose dispatch the untyped path
     *cannot* resolve: the **parser** (`parser.mdk`) is built on a `Parser` monad
     whose `pure`/`andThen` are **return-position** method dispatch. Running
     `parser.mdk` over an embedded snippet (`selfhost/selfproc_parse_probe.mdk`)
     through `eval_modules` (Leg B's untyped path) panics `no matching clause in
     application`; through the **typed** multi-module path
     (`eval_typed_modules_main.mdk` → `typecheck.elaborateModules`) it matches the
     `eval_modules` oracle byte-for-byte. `elaborateModules` is the composition of
     the single-module typed path (`eval_typed_main.mdk` → `typecheck.elaborate`,
     which stamps `EMethodAt` route tags) and the untyped multi-module path
     (`eval_modules_main.mdk` → `eval.evalModules`): it prePasses the prelude +
     every loaded module (rewriting return-position method occurrences to
     `EMethodAt` over the whole program's RP-method set), typechecks each module in
     dependency order (seeded like `checkModules`), and stamps each module's route
     refs from its now-resolved result types — so `evalModules` narrows
     `pure`/`andThen` by RKey instead of the untyped arg-tag fallback. RKey-only
     (the bootstrap source has no `=>`-constrained user polymorphism, so no
     dict-passing). This is the typed self-hosted eval path the scope note below
     called a "separate, larger bootstrap step" — now built.

   - ✅ **Leg D — TYPED eval engine runs the TYPECHECKER stage.** The natural
     extension of Leg C along the same typed multi-module path: the **typechecker**
     (`typecheck.mdk`) executes on the self-hosted eval, the way Leg C executes the
     parser. Like the parser it is monadic (return-position dispatch), so it routes
     through `eval_typed_modules_main.mdk` → `elaborateModules`, not the untyped
     `eval_modules` (which panics `no matching clause in application`). Validation
     mirrors Leg C: `selfhost/selfproc_tc_probe.mdk` runs `checkToLines` over an
     embedded **self-contained** snippet (record + data decls, ctor schemes,
     record create/update/access, a signature, multi-clause match, tuple/ctor
     patterns, if, lambdas, let-polymorphism, recursion) and renders the inferred
     `name : scheme` lines; the typed path matches the `eval_modules` oracle
     (`medaka run <probe>`) byte-for-byte, added as the fourth leg of
     `test/diff_selfhost_selfproc.sh`. **The anticipated "bigger lift" didn't
     materialize:** the typechecker's `Ref`-based union-find mutation (`<Mut>`),
     the tyvar-id counter, and level enter/exit all run on the self-hosted eval's
     **existing** extern kernel — no new primitives were needed (eval.mdk's
     `Ref`/`setRef`/`.value` slice-3 kernel + the `VThunk`/RKey typed path already
     covered it). RKey-only (no `=>`-constrained user polymorphism in the selfhost
     source). With Leg D green, **every monadic selfhost stage has run on the
     self-hosted eval** — the front-end fully executes itself.

   **Scope note (resolved by Leg C):** Leg B alone stops at the lexer because the
   **parser/typecheck stages use a `Parser` monad** with return-position dispatch
   (`pure x = Parser …`, `andThen`), which the **untyped** `eval_modules` path
   cannot resolve. Leg C threads the marker + `typecheck.elaborate` route-stamping
   through the loader's module graph (`elaborateModules`), executing a real
   `Parser`-monad stage on the self-hosted eval. **Leg D** extends the same typed
   path to the typechecker stage (also monadic), so all four legs together run
   every monadic selfhost stage on the self-hosted eval.

### Stage 2 §2.2 capstone — bytecode multi-module VM runs a real selfhost stage (2026-06-06)

The §2.2 capstone gate: run the self-hosted **lexer** stage through the bytecode
multi-module VM and reproduce its output byte-for-byte against the OCaml oracle.

- ✅ **`selfproc_lex_probe.mdk` through `eval_bytecode_modules_main.mdk`** —
  `bcEvalModulesOutput` evaluates the lexer module + probe in per-module bytecode
  frames and produces the exact same token stream as `medaka run selfproc_lex_probe.mdk`
  (OCaml reference eval_modules). The lexer uses only untyped eval — no return-position
  dispatch — so the untyped bytecode VM handles it fully.
- **Parse/TC probes — closed by §2.3 item 1.** `selfproc_parse_probe.mdk` and
  `selfproc_tc_probe.mdk` previously failed through the untyped bytecode VM because
  those stages use the `Parser` monad whose `pure`/`andThen` are return-position
  dispatch. Closed by `eval_bytecode_typed_modules_main.mdk` (§2.3 item 1): the typed
  multi-module bytecode path runs `elaborateModules` before lowering, so all three
  selfproc probes (lex/parse/tc) now pass byte-for-byte through the typed VM.
  Gate: `test/diff_selfhost_bytecode_selfproc.sh` — 6/6 ok (typed-VM section 3/3; untyped-VM
  parse/tc still carry expected-gap annotations — by design, untyped VM lacks return-pos dispatch).
- **Performance:** 2.74× slower than the tree-walker intra-process on the lex
  probe (tree-walker 0.240s, bytecode VM 0.657s, min-of-3). The predicted
  structural win (no AST re-dispatch + O(1) slot loads + compiled decision trees)
  does not materialize under double interpretation; it awaits §2.4 native codegen.
  Measured via `vm_perf_modules_main.mdk`; full numbers in `PERF-NOTES.md`
  §"§2.2 Capstone".

### Dictionary passing (generality layer — beyond the bootstrap)

The compiler's own source uses **only RKey** return-position dispatch (every site
is at a concrete type — the `Parser` monad, no polymorphic-monad code, no `=>`
constraints in the selfhost source), so the full dictionary-passing system is
**not** required for the bootstrap. It *is* needed for (a) running arbitrary user
programs that use `=>`-constrained polymorphic code, and (b) the LLVM backend
(Stage 2), which consumes the fully-elaborated AST.

**A dict-passing slice now exists** (`eval_dict_main.mdk` +
`typecheck.elaborateDict` + `eval.mdk`'s `VDict`/`EDictAt`/RDict), covering the
*user* program's constrained functions **and the prelude's own**
(`when`/`unless` — see the prelude paragraph below). It handles a `=>`-constrained function
whose body uses a return-position method (`empty`, …) at the constraint
variable's type — the case arg-tag dispatch genuinely cannot resolve — including
multi-type call sites, nested constrained calls (dict forwarding / RDict at the
call site), multiple constraints per function, **self/mutually-recursive
constrained functions** (the recursive call forwards the enclosing fn's own dict),
and **INFERRED (unsignatured) constraints** — a function with no `=>` signature
whose body uses a return-position method (or *calls* a constrained fn) at one of
its own tyvars is promoted automatically, including a constraint that propagates
through a call **chain** to an unsignatured caller.
Validated against `medaka run` by `test/diff_selfhost_eval_dict.sh` (17 fixtures in
`test/eval_dict_fixtures/`). Also validated through the typed bytecode VM by
`test/diff_selfhost_bytecode_eval_dict.sh` — same 17 fixtures, 17/17 byte-identical (§2.3 item 2).

Mechanism (mirrors the reference's marker → typecheck → dict_pass):
- `ast.mdk` — a `Route` ADT (`RNone`/`RKey`/`RDict`) plus `EMethodAt`/`EDictAt`
  carrying route refs the typechecker fills (typed-pipeline-only nodes, like the
  existing RKey `EMethodAt`; never in parse/desugar/mark output, so the
  sexp/astdump lockstep is untouched).
- `typecheck.mdk` — `elaborateDict` rewrites each constrained-fn occurrence to
  `EDictAt`; during inference it collects each fn's constraint tyvars (registered
  **after** body inference, by their *surviving* normalized id — pre-unify ids
  miss the survivor a method occurrence normalizes to) and records call-site dict
  applications; after inference it routes in-body methods (RDict when the
  discriminating type is the enclosing fn's constraint variable, else RKey) and
  call sites (RKey at a concrete type, RDict forwarding a nested constraint), then
  `dict_pass` prepends one `$dict_<fn>_<slot>` parameter per constraint. A
  **self/mutually-recursive** call hits the callee mid-inference (its
  `funConstraintsRef` entry doesn't exist yet), so it's deferred as a `RecDictApp`
  (callee, enclosing fn, live occurrence mono); `realizeRecDictApps` (run after
  inference, before `resolveDictApps`) recovers each constraint var from the mono
  by id (`findTvarInMono`, mirroring the reference's `find_tvar_in_mono`) and
  routes it to the **enclosing** fn's own `$dict_<encl>_<slot>` — the dict already
  in scope. The enclosing hint matters for mutual recursion: merged-group siblings
  share one constraint-var id, so the global `activeDictVars` map would pick an
  arbitrary sibling's dict param; routing through the enclosing fn's own
  constraint slots picks the one actually bound in its body (cf. reference Phase
  136's `enclosing` disambiguation).
- `typecheck.mdk` (inferred constraints — the **two-pass** layer, mirroring the
  reference's mark → typecheck → re-mark → typecheck → dict_pass) — a signature is
  not required to discover a constraint. During inference each return-position
  method site records its enclosing fn + result mono (`methodSiteFns`) and each
  constrained-fn call records its enclosing fn + constraint monos (`dictAppFns`);
  after a letrec group generalizes, `registerInferredConstraints` intersects those
  monos with the member's own quantified ids — an eligible *unsignatured* member
  whose method/call site sits at one of its quantified tyvars is **promoted**
  (registered in `funConstraintsRef`/`activeDictVars` by the surviving normalized
  id, exactly like a signatured one, and recorded in `promotedRef`).
  `elaborateDict` runs this as a fixpoint (`discoverPromoted`): each mark+typecheck
  pass grows the dict-passed set, so a constraint propagating through a call chain
  promotes one caller per pass until it stabilizes; the final pass routes and
  `dict_pass`es the full set. Promotion is gated to the user program's fn names
  (`dictEligibleRef`) — the prelude's constrained fns stay arg-tag/RKey, and the
  RKey-only typed path (`eligibleNames = []`) skips discovery, staying single-pass.
- `eval.mdk` — `VDict` (carrying the impl head tag), `EDictAt` applies one dict
  per route as a leading argument, `EMethodAt` routed RDict reads the dict
  parameter to narrow its method. (Unchanged — promoted fns reuse the same
  RDict/RKey routing as signatured ones.)
- `typecheck.mdk` (prelude constrained fns) — `preludeReturnPosDictNames` selects
  the prelude's *own* `=>`-constrained fns that need dict-passing: those whose body
  references a **return-position method** (only `when`/`unless`, both `… pure ()`).
  Every other constrained prelude fn (`sum`/`any`/`elem`/`clamp`/…) uses only
  arg-position methods, which arg-tag already resolves, so they stay on RKey — and
  the goldens keep type-checking, since the golden paths (`elaborate` =
  `elaborateDict … [] []`) dict-pass nothing; only `eval_dict_*` carries a non-empty
  `dictNames`. This also required teaching `activeDictVarOf` to find the constraint
  var in a `TApp` **head**: `pure : a -> m a` is higher-kinded, so its result mono
  `m Unit` carries the dict var in the application head, not at top level — the
  old bare-`TVar` match returned `None` → arg-tag fallback (the bug; this gap hit
  *user* higher-kinded constrained fns too). A concrete head (a `TCon` after
  unification) still falls through to RKey, unchanged. No `eval.mdk`/`ast.mdk` edits
  were needed — the existing RDict/RKey routing already forwarded once the route
  was resolved.

Because the runtime dict is a flat type-tag (not iface-keyed), it's correct even
for several constraints on one tyvar: all such dicts carry the same type tag, and
each method's VMulti is already interface-specific, so reading any same-tyvar
dict narrows correctly.

**Single-impl return-position methods — FIXED 2026-06-05.** A *user-defined*
interface with a SINGLE impl and a return-position method (`interface Default a
where def : a` + one `impl Default Int`) used to panic on the typed/dict paths
(`def : Int` → `intToString: not an Int`), while a *prelude* method (`empty`,
many impls) worked. Root cause: a single impl binds to a **bare `VTypedImpl`**
(never coalesced into a `VMulti`), and `eval.mdk`'s `narrowMethod` catch-all
(`narrowMethod v _ = v`) skipped the Phase-96 dispatch-wrapper strip for a
non-`VMulti`, so the wrapper leaked into the program. Fixed by adding
`narrowMethod` arms that `stripResolved` a bare `VTypedImpl` once a route has
resolved it (mirrors `lib/eval.ml`'s strip, which fires for *any* `VTypedImpl`
after routing). Regression: `test/eval_typed_fixtures/single_impl_return_pos.mdk`.

**Structured/recursive instance dicts (Phase 83/84 #5) — DONE (2026-06-05).**
The self-host now resolves `def : List (List Int)` → `[[0]]`, three-level
`List (List (List Int))` → `[[[0]]]`, and mixed `Option (List (Option Int))` →
`Some [Some 0]`, matching the reference oracle. Five pieces ported on top of the
single-level base:

1. **`ast.mdk`** — `RKey String (List Route)` (sub-routes, mirrors the reference's
   `RKey (string * res_route list)`) and new `RDictFwd String` (encodes
   `res_fwd_requires = true`; see point 3).
2. **`typecheck.mdk`** — `implDictRoutesFor` now threads the **full** impl table
   through `implDictRoutesIn` (a helper that recurses over the table without
   dropping the tail on a match), so sub-route lookup for `List (List Int)` can
   re-find the "List" impl for the inner element. `implReqRoutes`/`reqRoute` pass
   `implTable` down; new `implRequiresRoutesRec` + `findImplEntry` mirror
   `lib/typecheck.ml`'s `impl_requires_routes_rec`. Each `RKey` now carries the
   recursively-computed sub-routes, building a fully-structured route tree.
3. **`ast.mdk` / `typecheck.mdk` — `RDictFwd` gate.** `resolveSite` emits
   `RDictFwd dname` (instead of `RDict`) when the method's name is in the
   return-position set (`rpNames`). `RDictFwd` means: dispatch by the dict value's
   key like `RDict`, AND forward the dict's own nested `reqs` into the impl body.
   Arg-position methods (`display`/`==` etc.) keep `RDict` and never forward — they
   dispatch by arg-tag and over-applying with extra leading args corrupts them.
4. **`typecheck.mdk` / `dict_pass`** — `siteRDictName` (the `usesImplDict` gate)
   now matches both `RDict d` and `RDictFwd d`, so dict_pass correctly adds the
   `$dict_<method>_<slot>` param to any return-position impl body regardless of
   whether it will forward.
5. **`eval.mdk`** — `VDict String (List Value)` carries the structured element
   dicts. `dictOfRoute` recurses for `RKey key reqs`. New `methodAtNarrow` returns
   `(narrowed, fwdReqs)`: `fwdReqs = []` for `RKey`/`RDict`/`RNone`, and the dict
   value's own `reqs` for `RDictFwd`. New `applyValues` folds a list of values as
   leading args. The `EMethodAt` eval arm: narrow → apply method dicts → apply impl
   dicts → `applyValues v2 fwdReqs` (no-op when `fwdReqs = []`, guarded by the
   `if awaitsArgs v2` reference pattern — the reference gate is implicit here via
   narrowing to a VTypedImpl closure that always awaits its dict arg).

Validated by `test/eval_dict_fixtures/nested_instance_dicts.mdk` (new, diffed
against `medaka run`). All dict/typed/golden/selfproc gates green (17/17 eval-dict,
16/16 selfproc, 18/18 golden).

**Instance-`requires` dict-passing (Phase 83/84 single-level) — DONE (2026-06-05).**
The self-host now resolves `def : List Int` → `[0]` for
`impl Default (List a) requires Default a where def = [def]` by threading the
*element* dict (`Default Int`) into the parametric impl body, exactly as the
reference does. Two call sites at different element types (`def : List Int` →
`[0]`, `def : List String` → `["empty"]`) confirm the threaded dict is per-site,
not type-pinned. The four implemented pieces:
1. **`ast.mdk`** — `EMethodAt String (Ref Route)` gained a second
   `Ref (List Route)` for the selected impl's `requires` dicts (the reference's
   `res_impl_dicts`). Threaded through `eval.mdk`'s `EMethodAt` arm
   (`applyDicts … implRef.value` after `narrowMethod`), `typecheck.mdk`'s
   `inferMethodAt`/`recordSite`/`rewriteRPDict`/`allEVars`, plus `annotate.mdk` and
   `core_ir_lower.mdk` (the latter drops it — Core IR has no requires support).
   (`EMethodAt` is typed-pipeline-only — not in `sexp.mdk`/`astdump`, so the
   serializer lockstep is untouched.)
2. **`typecheck.mdk`** — `checkProgramSeeded` now ALSO infers each parametric
   impl's return-position method bodies (`inferImplBodies`), gated behind
   `implInferEnabled` (ON only for `elaborateDict`; OFF for the `=== TYPES ===`
   golden path `checkProgram` and the multi-module `elaborateModules`, so their
   scheme output stays byte-identical). One tyvar table (`implTvMap`) is shared
   between the impl head (`List a`) and the `requires` (`Default a`); after body
   inference, `registerImplRequires` records the post-unification `requires` ids in
   `activeDictVars` keyed to the impl's `$dict_<method>_<slot>` param, so the
   in-body `def` site routes `RDict`. At the call site, `resolveSite` (now passed a
   `buildImplTable` of impls-with-requires) fills the new impl-dicts ref via
   `matchTyMono` (match the impl head pattern against the concrete result mono) +
   `implReqRoutes` (one `RKey` per requires). Cf. `lib/typecheck.ml` `check_impl`
   (~3108-3173), `find_enclosing_dict` (~3556-3571), `impl_head_subst`/
   `matching_impls` (~3640-3685).
3. **`dict_pass`** (in `typecheck.mdk`) — `dictPassDecl` gained a `DImpl` arm:
   prepend one `$dict_<method>_<slot>` param per `requires` to each return-position
   impl method clause whose body actually reads an impl dict (`usesImplDict` gate,
   via `collectMethodSites`/`bodyRDictNames`). Mirror of `lib/dict_pass.ml:99-119`.
4. **`eval.mdk`** — the `EMethodAt` arm folds the impl-dicts ref's routes onto the
   narrowed impl value as leading args (reusing `applyDicts`). Mirror of
   `lib/eval.ml:803-810`. Empty ref ⇒ no-op (every ordinary site), so all prior
   eval paths are byte-identical.
Validated by `test/eval_dict_fixtures/instance_requires_list.mdk` and
`instance_requires_option.mdk` (diffed against `medaka run`); all
dict/typed/golden/selfproc gates stay green. **Known limit:** `activeDictVars` is a
flat id→name map, so an impl with *two* return-position methods both reading the
element dict would collide on the shared tyvar id — fine for the single-method
interfaces in scope (`Default`/`Monoid`/`Monad`).

**Method-level-constraint dict-passing (Phase 69.x-e) — DONE (2026-06-05).**
An interface method may carry its OWN `=>` constraint over a tyvar that is NOT the
interface param — the canonical case is `foldMap : Monoid m => (a -> <e> m) -> t a
-> <e> m` in `stdlib/core.mdk`, where `Monoid m` constrains the result monoid `m`,
independent of the container `t`. The default body `foldMap f = fold (acc x => acc
++ f x) empty` uses the return-position `empty` at type `m`, which has no
discriminating argument, so plain arg-tag dispatch picks the *first* Monoid impl
(wrong). The self-host now threads the caller-supplied `Monoid m` dict into the
method body exactly as the reference does (`lib/dict_pass.ml` DInterface arm,
`res_method_dicts`; `lib/typecheck.ml` `resolve_method_dicts` / the default-body
loop ~3034-3072; `lib/eval.ml` ~795-802). `foldMap dup [1,2,3]` → `[1,1,2,2,3,3]`
and `foldMap lbl [1,2,3]` → the String-monoid concatenation both match `medaka
run`. The implemented pieces, mirroring the reference:
1. **`ast.mdk`** — `EMethodAt` gained a THIRD `Ref (List Route)` for the method's
   own method-level dicts (distinct from the second ref's impl-`requires` dicts).
   Threaded through `eval.mdk` (`applyDicts … methodRef.value` BEFORE the impl-dicts
   fold, matching dict_pass's param order), `typecheck.mdk`'s `infer`/`inferMethodAt`/
   `recordSite`/`collectMethodSites`/`allEVars`, plus `annotate.mdk` and
   `core_ir_lower.mdk` (drops it). (`EMethodAt` is typed-pipeline-only — no
   `sexp.mdk`/`astdump` clause, so the serializer lockstep is untouched.)
2. **`typecheck.mdk`** — `methodConstraintsRef` records each method's method-level
   constraint var ids, captured while BUILDING the env method schemes
   (`ifaceMethodSchemes`/`methodSchemes` via the new `sigToSchemeTvs`) so the ids are
   the SAME quantified ids a call-site instantiation maps through its subst. A method
   carrying such a constraint is rewritten to `EMethodAt` (via `methodConstraintNames`
   added to `prePassDict`'s set, alongside the return-position names) even when it is
   NOT return-position. `checkProgramSeeded` now also runs `inferDefaultBodies` (gated
   behind `implInferEnabled`, like the impl-body inference): it infers each interface
   default body carrying a method-level constraint, registering the constraint var's
   *surviving* (post-unification) id in `activeDictVars` keyed to `$dict_<method>_<slot>`
   so the in-body `empty` routes RDict. At the call site, `recordMethodDicts` maps each
   constraint id through the occurrence's subst; `resolveMethodDicts` routes each
   (RKey at a concrete monoid, RDict forwarding a constrained caller's dict).
3. **`dict_pass`** (in `typecheck.mdk`) — a new `DInterface` arm
   (`ifaceDictPassMethod`) prepends one `$dict_<method>_<slot>` param per method-level
   constraint to the method's DEFAULT body. Mirror of `lib/dict_pass.ml:82-89`.
4. **`eval.mdk`** — the `EMethodAt` arm folds the method-dicts ref onto the narrowed
   method value as leading args, BEFORE the impl-`requires` dicts (matching dict_pass's
   `dict_pats method k @ impl_pats` order). Empty ref ⇒ no-op (every ordinary site),
   so all prior eval paths are byte-identical.
Validated by `test/eval_dict_fixtures/method_constraint_foldmap_list.mdk`,
`…_foldmap_string.mdk`, and `…_user_iface.mdk` (a user `Crushable` interface
mirroring `foldMap`); all dict/typed/golden/selfproc gates stay green. The t-route
(`tagRef`, computed from the result mono) is left as-is for these methods — for
`foldMap` it lands on the *result* monoid's head tag, which is harmless because no
impl is tagged for a method-level method (`narrowMethod` falls back to the VMulti and
arg-tag picks the container's `fold` inside the default body). **Known limits:**
(1) only the DEFAULT-body path is covered — a *multi*-impl override of a method-level-
constrained method is out of scope (prepending the dict param shifts the
container-dispatch position; in the prelude no impl overrides `foldMap`, so this never
arises); (2) one slot per constraint, single dispatch var (single-param interfaces
like `Monoid`); (3) super-expansion is skipped (`foldMap`'s `++` is arg-position, so
it needs no dict — only `empty` does).

**Pre-existing bug fixed along the way.** `doStmtSites (DoLet _ _ e)` matched 3 of
`DoLet`'s 4 fields (it gained a `Bool` is-fun-def flag); the reference flagged the
constructor-arity error while typechecking `typecheck.mdk`, which broke the *entire*
`diff_selfhost_eval_dict` harness (every fixture's self-output was empty). Fixed to
`DoLet _ _ _ e`.

### Known limits carried forward (don't block the bootstrap)

- **Inferred effect propagation — DONE (Phase 146 selfhost mirror, 2026-06-06).**
  The full effect-tracking subsystem (Phase 79 propagation + 79e escape + 146
  laundering) is now ported into `typecheck.mdk`: open-row inference, ambient
  `curEffect`, `performEffect`/`unifyRow`/escape/laundering checks. An unsigned
  function calling an effectful extern now picks up its effect, and the self-hosted
  typechecker rejects effect laundering byte-identically to the reference (fixtures
  `effect_leak`/`effect_escape`/`effect_subsume`). Invisible in the `=== TYPES ===`
  goldens (empty tails render pure), validated by the typecheck/error harnesses.
- **"Signature too general"** is now reported (`checkSigsTooGeneral` in
  `processSCC` — rejects a declared sig whose distinct tyvars collapse to one
  after body inference, byte-identical to the OCaml `SignatureTooGeneral` error).
- **Performance** — the interpreter is slow (each run re-parses core/list); the
  lexical-addressing + hash-set perf hooks under *Performance* below are the fix.

### Error-path divergences — the self-hosted compiler does not reproduce the reference's *rejection* behavior (verified 2026-06-05)

Every diff harness feeds **well-formed input** (or input whose only fault is a
*semantic* one the resolve / exhaust diagnostic pass is designed to catch). On
those, the ports match byte-for-byte: value-level `eval`, scheme-level
`typecheck`, and the resolve / exhaust *diagnostic lists* were all re-verified on
fresh novel inputs and agree. The reference's behavior on **malformed /
ill-typed / crashing input** is largely covered for the lexer and parser (see
below), but still diverges at the typecheck and eval stages. This is **not** a
blocker for the bootstrap (the selfhost source is all well-formed), but it is a
gap in fidelity. Concretely, by stage:

- ✅ **Lexer — illegal characters now panic (fixed 2026-06-05).** `lib/lexer.mll`
  raises `Failure "Unexpected character: X"` on a byte it can't start a token
  with; the self-hosted lexer now mirrors this with `panic ("Unexpected
  character: " ++ charToStr c)` in `singleOp`'s catch-all (lexer.mdk:769).
  Validated by `test/diff_selfhost_parse_errors.sh` (`illegal_char_hash` fixture).
- ✅ **Parser — full-consumption EOF check added (fixed 2026-06-05).** `resultDecls`
  now takes the token array, panics on `PErr`, and panics with `"parse error"` if
  any token before `TEof` is unconsumed after `many declThenNoise` returns.
  `parse` has the same `List Decl` return type — it panics on malformed input
  rather than silently truncating. Validated by `test/diff_selfhost_parse_errors.sh`
  (4 parse-error fixtures): `f = 1 +` (dangling operator), `g = )` (leading
  garbage), `f = 1\ng = )` (second decl fails), `f x = g x ? 0` (leftover integer
  after postfix `?`). The one remaining gap vs the OCaml reference is **location
  precision**: the reference Menhir parser reports the exact byte offset in
  `parse error L:C`; the self-hosted combinator parser reports only `parse error`
  (no position). The harness normalizes both sides by stripping the ` L:C` suffix
  before comparing.

  The downstream-effect note from before is now resolved: with the EOF check,
  input the reference parse-errors on is **also** rejected by the self-hosted
  parser (e.g. `f x = g x ? 0` — `?` is postfix, `0` is a leftover token,
  caught by the EOF check). The resolve/exhaust diagnostic stages can no longer
  receive input that the reference would have rejected before resolving.
- ✅ **Typecheck — type-error accumulation added (fixed 2026-06-05).**
  `typeMismatch` now pushes a `"Type mismatch: …"` string to a module-level
  `typeErrors` accumulator and returns rather than panicking; the occurs-check
  likewise pushes `"Cannot construct infinite type involving …"` and sets a
  `occursCheckFailed` flag so `bindVar` skips the cyclic link.  `checkToLines` /
  `checkToLinesWithRuntime` emit `TYPE ERROR: <msg>` lines (matching
  `tc_probe.exe`) when errors are present and suppress scheme output — matching
  the reference's single-exception behavior.  Validated by
  `test/diff_selfhost_typecheck_errors.sh` (int-vs-string, tuple-arity,
  occurs-check; each via both `typecheck_main.mdk` and `check.mdk`).
  The type-aware `check_match` exhaustiveness pass (lives inside the reference
  typechecker, needs the scrutinee type) is now **also ported** — it accumulates
  into a separate `matchWarnings` ref, surfaced by `checkMatchToLines` (see the
  typecheck stage notes above). The "signature too general" error is now ported
  too (`checkSigsTooGeneral` in `processSCC`).
- ✅ **Eval — runtime-error messages now match the reference (fixed 2026-06-05).**
  Every `panic` message in `selfhost/eval.mdk` was cross-walked against
  `lib/eval.ml`'s `Eval_error` call sites and the diverging ones were corrected:
  `"no matching clause in application/match"` → `"non-exhaustive match"`;
  `"unbound variable: X"` → `"unbound identifier: X"`;
  `"'++' requires List or String"` → the full Semigroup message;
  unary-op catch-alls split into per-operator messages matching the reference;
  index/slice OOB messages now include the index value / coordinate range;
  `"index: bad operands"` → `"index is not an Int"` / `"index on non-array/list/string"`;
  etc. — 15 sites fixed, 15 sites confirmed already matching. Validated by
  `test/diff_selfhost_eval_errors.sh` (8 runtime-reachable negative fixtures in
  `test/eval_error_fixtures/`; three-stage check: oracle stability → selfhost
  exits non-zero → selfhost message matches golden).

**Shared-limitation non-gaps (ruled out, recorded so they aren't re-investigated):**
float exponent notation (`1.0e10`, `1.5e-8`) is *not* a selfhost gap — **neither**
lexer supports it; both tokenize `1.0e10` as `FLOAT 1` `IDENT "e10"` (the FLOAT
text `1` vs `1.` is the already-documented `%g` normalization). Multi-line
`let … \n in …` (with `in` starting a new line) is rejected by both — OCaml with
a parse error, the self-hosted side also with a parse error (the EOF check
catches the unconsumed tokens), so it is not a capability gap.

### Performance — what to bake into these phases (so we don't forget)

LLVM (Stage 2) raises the ceiling, but the current tree-walker has large,
backend-independent wins available *first*. Most of these should wait until the
pipeline exists and can be profiled — **measure before optimizing**: the
self-hosted compiler is itself the best benchmark (a big, realistic, hot
workload we control), so the prerequisite is cheap observability (per-phase
timing + an allocation counter) to attribute where the time actually goes,
rather than guessing. With that caveat, two items are cheap *now* and expensive
to retrofit, so design them into the initial phases:

- **Lexical addressing — reserve the variable-slot hook in resolve + the Core
  IR. EMIT HALF DONE (2026-06-05).** Today `eval`'s environment is
  `(string * value ref) list list`, so every `EVar` is a linear scan with string
  compares — likely the single hottest cost in the interpreter. The fix is to
  resolve each variable to a `(frame, slot)` index and use array frames for O(1)
  lookup. The first interpreter need not *use* the slot, but resolve should
  *emit* it. The de-risked **emit half landed**: `ast.mdk` gained `data Addr =
  ALocal Int Int | AGlobal` and a new `EVarAt String Addr` node (a *separate*
  node, NOT a field on `EVar` — that would touch all 125 `EVar` sites across 9
  files incl. eval/parser; `EVarAt` confines the change to `ast.mdk` + `resolve.
  mdk`), and `resolve.mdk`'s exported `annotateProgram` rewrites `EVar n` →
  `EVarAt n addr`, computing the `(frame, slot)` from a framed scope that mirrors
  `eval`'s `EvalEnv` exactly (per-param currying = one frame/param innermost-last;
  empty `_`/`None` frames count toward depth; `GBind` guards push a frame;
  `ELetGroup` = one shared frame; block-`let`/`DoLet` non-recursive). It is
  intentionally **unwired** (not called by `resolveProgram`/`resolveModule`), so
  every harness stays byte-identical; the node never reaches a dump (no `sexp.mdk`
  / `astdump.ml` clause needed). See the NEXT item for the consumer follow-up.
  *(Update 2026-06-05: `annotateProgram` has since been relocated out of
  `resolve.mdk` into a lean `annotate.mdk`, and the CONSUME half built + measured —
  no tree-walker win, kept dormant. See the "CONSUME half DONE" bullet below.)*
- **String-building O(n²) — DONE (2026-06-05) for the hot path; see
  `PERF-NOTES.md`.** Verified `++` is copy-based (OCaml `^`, alloc+blit both
  operands) so a fold over n pieces is O(n²): the self-hosted lex of a file scales
  super-linearly (8× input → 2.34s, ~63% quadratic at that size). The fix did
  **not** need a mutable buffer — the existing native `stringConcat : List String
  -> String` (one `String.concat` pass) already gives "amortized-O(1) append +
  single freeze" when fed a cons-built list. Added `util.joinWith`/`intersperseStr`
  and routed `joinNl`/`joinSp`/`renderToks`/`escFrom` through it (lex 8× **2.34→1.01s,
  2.3×**; scaling now linear; byte-identical). Under the tree-walker a vendored
  `mut_array` StringBuilder would be *slower* (Medaka-level per-char push vs native
  concat) and force mutation through pure recursion — rejected on measurement.
  **Key finding: the win is in joins over MANY elements (alloc/GC count), not joins
  of a few large strings** — `renderAll`-style joins of ~96 file outputs measured
  flat and were reverted; the lexer's per-char literal scanners are O(L²) but the
  longest real literal is 98 chars, so left alone. Remaining string-build costs are
  now below the interpreter floor.
- **Lexical addressing / slot-indexed env — CONSUME half DONE, measured NO WIN
  under the tree-walker, kept DORMANT (2026-06-05).** The emitted slot was the
  parked "single most promising un-attempted lead" (by-name env lookup ~28% of
  eval, 49.7M string-compares marking `parser.mdk`). The full consume half was
  built and measured; **it does not help this interpreter.** What landed:
  - the §2.0 EMIT pass moved out of `resolve.mdk` into a lean `annotate.mdk`
    (ast+util only; Core IR drivers import it from there);
  - an `EVarAt` consume arm in `eval.mdk` (`lookupAtAddr`: AGlobal ⇒ by-name
    `lookupEnv` — the self-host analog of the lookup_method shadow-bypass; ALocal
    ⇒ name-checked (frame,slot) index). **Byte-identical across the entire
    eval+core_ir+selfproc corpus in all configs; the slot/name assertion never
    fired (the emit/consume frame model is provably exact).**

  But the measurement (synthetic eval-heavy probe, 60k-iter hot loop, min-of-3):
  **baseline by-name 50.31s, list-indexed ~neutral (52.0s, within noise), array
  frames a clear +14% regression (57.5s).** Reason: in a tree-walker the lookup
  logic is itself interpreted Medaka, so the "O(1) index" is not a native op — it
  costs about what the by-name string-compares cost, and `arrayFromList` on every
  frame push (per call/let/match) outweighs the slot-index saving. **Lexical
  addressing is a bytecode-VM / native-codegen win, not a tree-walker win** — which
  is why the Core IR carries the addresses (`CVar String Addr`) for that consumer.
  So array frames + the eval-pipeline wiring were reverted (frames stay
  `List (List ..)`, drivers don't call `annotateProgram`, AST eval stays by-name);
  the `EVarAt` arm + `annotate.mdk` are kept as **dormant, validated** scaffolding
  (activate by running `annotateProgram` in `evalProgram`/`evalModules`). Full
  numbers + rationale in `PERF-NOTES.md` (2026-06-05 entry).

Recorded for later, **not** initial-phase work (revisit once the front-end is
profilable):

- **Bytecode VM as a "Stage 1.5"** between the tree-walker and LLVM — removes
  per-node AST re-dispatch, gets lexical addressing for free, and its Core IR is
  largely the IR LLVM wants (so it's an on-ramp, not throwaway).
- **Decision-tree pattern-match compilation** (drive it from the same Maranget
  analysis used for exhaustiveness) — tests each scrutinee field once instead of
  re-checking per clause; the parser/lexer are match-heavy, so this helps the
  self-host directly.
- **Static typeclass dispatch** — confirm `EMethodRef` routes resolved at
  elaboration aren't re-searched at runtime in `VMulti`; full monomorphization is
  an LLVM-era concern.
- **Stdlib hygiene** — prefer `Array`/`mut_array` over `List` in hot paths, keep
  common ops tail-recursive, and cache the elaborated+evaluated prelude so the
  many small runs (doctests, test suite) don't re-install it each time.

## Self-host-surfaced compiler fix

**Phase 134 (fixed).** Porting the lexer surfaced a real bug: an `<IO>`-returning
**helper** called from a `match` arm produced no output (clean exit) while the
same logic **inlined** ran correctly. Root cause was *not* the eval driver but
cross-module dict-passing: a private, then-`Num`-constrained 8-arg `emit` in
`lexer.mdk` made `Eval.eval_modules` (which dict-passed the whole program
*jointly*, keying dict-arity by bare name) prepend spurious dict parameters to any
same-named function in another module. `lex_main.mdk`'s unconstrained `emit`
helper then got under-applied, returning a partial closure that was never run.
Fixed by scoping each module's dict-arity table to the references that can resolve
to its own definitions (own decls + transitive importers); the regression is
guarded by `test_loader` (which supplies a genuinely-constrained same-named
sibling). `lex_main.mdk` now uses the clean helper form. (The lexer's `emit` has
since gained a concrete `Int` signature, so it no longer collides on its own.)
