# BOOTSTRAP.md — Native self-compile slices

Status of the native (LLVM) self-compile bootstrap: take a REAL self-hosted
compiler subcommand, compile it natively (emit textual LLVM IR -> `clang` -> link
`runtime/medaka_rt.c` + libgc), and prove its output **byte-matches the
tree-walker interpreter** over real fixtures.

Unlike `test/diff_selfhost_llvm_modules.sh` (which forces an EMPTY core prelude),
the bootstrap pushes the REAL `stdlib/core.mdk` prelude through `emitProgram` —
the actual bootstrap gate.

## B1 — native LEXER ✅ **DONE (19/19 byte-identical to the interpreter)**

**Result: 19/19 `test/diff_fixtures/*.mdk` byte-match** — the FIRST end-to-end
self-compile slice: a natively-compiled piece of the Medaka compiler behaving
identically to the reference tree-walker on real source. The last holdout
(`triple_str`) was a pre-existing emitter bug: `emitCmp` did string `==`/`!=` as
pointer identity; now routes through `@mdk_string_eq` when EITHER operand is
`LTStr` (mirrors the pattern-match literal path).

**Goal:** natively compile `selfhost/lex_main.mdk` (reads a file, `tokenize`s,
prints the canonical token stream) and byte-diff against
`medaka run selfhost/lex_main.mdk <fixture>`.

**Harness:** `test/bootstrap_lex.sh` (models `diff_selfhost_llvm_modules.sh`;
real `core.mdk`; diffs over every `test/diff_fixtures/*.mdk`).
**Emit driver:** `selfhost/llvm_bootstrap_lex_main.mdk` — clone of
`llvm_emit_modules_main.mdk` that runs the REAL `emitProgram` but calls
`enableGapRecord ()` first, so the 8 UNREACHABLE dead-code gaps in `core.mdk`
(`max`/`min` in `maximum`/`minimum`, the `Arbitrary` impls) become harmless `"0"`
placeholders instead of aborting. The byte-diff is the safety net: a gap the
lexer actually REACHES would diverge a fixture and FAIL — a passing diff proves
every placeholder was dead code.

### Done in this slice
1. **Two real emitter bugs fixed** (both in `selfhost/llvm_emit.mdk`; all 10
   `diff_selfhost_*` gates stay byte-identical):
   - **`e` / Euler shadowing.** `emitVar` intercepted the bare name `"e"` (and
     `pi`/`intMaxBound`/…) as a math constant BEFORE checking the local env, so a
     local/parameter named `e` resolved to `2.718281828459045`. The lexer uses
     `e` as a parameter pervasively (`identToken … e`, `let e = identEnd …`), so
     `substr src pos e` was emitted with `e` = a float cell -> wild array index ->
     SIGSEGV in `@mdk_at`. Fix: a local of that name now shadows the constant
     (`isLocal` check first; reserved value keywords `True`/`False`/`otherwise`
     and constructors still bind ahead of the env, as they can't be rebound).
   - **Gap placeholders left blocks unterminated.** When gap-recording is ON, the
     decision-tree gap sites (`CTGuard`, the unit/heterogeneous switch heads) only
     recorded the gap and emitted no terminator, so the dead-code `Arbitrary` impls
     produced structurally-invalid LLVM (`alloca` then a dangling label) and clang
     rejected the whole module. Each now stores a `"0"` placeholder and branches to
     the decision-end block — valid IR for the (dead) function.
2. **`@main` argv wiring confirmed present.** `emitProgram`'s `@main` already has
   the C signature `(i32 %argc, ptr %argv)` and calls
   `@mdk_set_args(i32 %argc, ptr %argv)` before the body, so `args ()` returns the
   file path. No emitter change needed.
3. With the `e`-fix, `tokenize <fixture>` natively returns the **correct token
   count** (e.g. 83 for `if_else.mdk`, matching the interpreter), and a probe that
   inlines `lex_main`'s logic byte-matches the interpreter on `if_else.mdk`.

### Remaining blocker — flat-emit bare-name function collision  [RESOLVED]
`lex_main.mdk` defines a private `emit : String -> <IO> Unit`, and `lexer.mdk`
defines an unrelated private `emit : … -> List RawTok` (the operator scanner
helper, heavily used by `scanOp`). The multi-module emit path flattens every
module's decls into ONE list (`coreD ++ concatMapList snd modules`) and mangles
function names by **bare name** (`@mdk_<name>`), with no module qualification.
So both `emit`s collapse to `@mdk_emit`: only one `define` survives, and
`@main`'s call `@mdk_emit(%path)` (1 arg) dispatches to the surviving 8-arg lexer
`emit` with garbage args -> the lexer prints nothing (just the `()` Unit
auto-print). The interpreter avoids this via per-module frames; the flat native
emit does not.

**FIXED (module-qualified private-fn mangling).** `selfhost/private_mangle.mdk`
(`mangleUnits`) runs PER UNIT, BEFORE `elaborateModules` flattens the module
boundaries. It finds top-level function names defined in >1 unit (the
collisions), and for each unit renames ITS module-PRIVATE (`pub = False`)
colliding functions to a unique `<mid>__<name>` symbol (mid sanitized to
`[A-Za-z0-9_]`), rewriting every in-module reference SCOPE-AWARELY (a reference is
renamed only where the name is the free top-level name, never where a local
binder shadows it — mirrors typecheck.mdk's `rewriteArgScoped` binder threading).
Exported functions keep their bare name (cross-module-referenced). Private ⇒ not
importable ⇒ references are self-contained, so no cross-module fixup is needed.
Wired into BOTH flat-emit drivers (`llvm_bootstrap_lex_main.mdk` and
`llvm_emit_modules_main.mdk`); the golden/oracle drivers never call it, so every
golden/oracle dump and all 10 selfhost gates stay byte-identical. Result:
`lex_main.emit` -> `@mdk_lex_main__emit`, `lexer.emit` -> `@mdk_lexer__emit`; the
native lexer now produces the correct token stream.

Two harness/measurement fixes also landed:
- `test/bootstrap_lex.sh` appended `\n()` (newline-then-parens) to the oracle to
  account for the native Unit auto-print, but `lex_main.emit` renders via `joinNl`
  (NO trailing newline) + `putStr`, so the oracle ends at the last token with no
  newline and native concatenates `()` directly after it (`…EOF()\n`). The append
  is now exactly `()` (matching the comment's documented `()\n` intent after
  `$(self)` strips the trailing newline). The sibling `llvm_modules` harness keeps
  `\n()` because its oracle output IS newline-terminated.

### NEW sole blocker — `emitCmp` does not route String `==` to `@mdk_string_eq`
`triple_str.mdk` is the lone remaining failure (18/19). Root cause is UNRELATED to
mangling and lives in `selfhost/llvm_emit.mdk`'s `emitCmp` (≈ line 1407): for
`==`/`!=`/`<`/… it dispatches only on `LTFloat` vs an integer `_` fallback. The
`_` arm `untagInt`s both operands and emits `icmp eq i64` — so for **`LTStr`**
operands it compares the two heap POINTERS, i.e. pointer identity, NOT string
contents. `mdk_string_eq` is used by the pattern-match path (≈ line 3185) but NOT
by the `==` binop path. Effect: native `"" == ""` and even `"ab" == "ab"` are
False (distinct `mdk_str_lit` pointers). In the lexer this breaks
`firstNl … acc = acc == "" || …` (lexer.mdk:534): `acc == ""` is False natively, so
`leadingNl` never flips True, so `maybeStrip`/`stripIndent` skips the triple-string
dedent → `triple_str.mdk` token 10 emits the raw un-dedented content. None of
`stripIndent`/`maybeStrip`/`firstNl`/`at` are renamed by the mangling pass — this
is a pre-existing emitter bug. **Fix (separate slice, out of B1 mangling scope):**
add an `LTStr` arm to `emitCmp` that calls `@mdk_string_eq` (returns tagged Bool
`3`) and branches on `icmp eq i64 r, 3`, exactly as the pattern path already does.

## B2 — native PARSER ✅ **DONE (26/26 byte-identical to the interpreter)**

**Result: 26/26 `test/parse_fixtures/*.mdk` byte-match** the interpreter. The
self-hosted PARSER (a monadic combinator parser over the lexer's token stream)
natively compiled, end-to-end, producing the SAME canonical AST S-expression
(`programToSexp`) as `medaka run selfhost/parse_main.mdk <fixture>`.

The parser exercises far more of the compiler than the lexer — the `Parser`
monad's `Mappable`/`Applicative`/`Thenable` impls, the precedence ladder, deep
mutual recursion among nullary combinator globals, records, ranges — so it
surfaced **four real emitter bugs**, all clean fixes in `selfhost/llvm_emit.mdk`
(plus one runtime helper). Each helps later slices.

**Harness:** `test/bootstrap_parse.sh` (clone of `bootstrap_lex.sh`: real
`core.mdk`, generic bootstrap driver, libgc/clang block, `()` Unit-auto-print
convention; FIXDIR = `test/parse_fixtures`). Both sides emit selfhost
S-expressions, so a RAW byte-diff is correct (no float normalization — unlike
`diff_selfhost_parse.sh` which diffs selfhost-vs-OCaml).
**Emit driver:** reuses the GENERIC `selfhost/llvm_bootstrap_lex_main.mdk`
(takes the entry as an argument — not lexer-specific despite the name).

### Four emitter bugs fixed (all in `selfhost/llvm_emit.mdk`)
1. **Under-applied impl method → truncated direct call.** A point-free prelude
   binding (`length = fold f 0`) lowers the impl method applied to FEWER args than
   the impl fn's arity; `emitImplCall` emitted a call MISSING its trailing
   param(s), reading a garbage register → crash. Fix: `emitImplCallSat` builds a
   PARTIAL-APPLICATION closure (`emitPapClosure` + `emitPapDefine` — a forwarder
   that loads captured args from the closure cell and tail-calls the impl) when
   `argOps < arity`; saturated calls unchanged. Plus the inverse: tagged impl
   groups are now ETA-EXPANDED to the method's full declared arity in
   `gatherGroup` (mirroring `emitDefaultDefine`), so a point-free impl
   (`@mdk_impl_List_length` was emitted NULLARY while call sites passed 1 arg)
   takes every call-site arg.
2. **Under-applied known function → truncated direct call.** Same class for plain
   top-level fns passed partially applied to a combinator
   (`map (desugarDottedField e) fields` — 1 of 2 args lowered as a 1-arg direct
   call to a 2-arg fn). Fix: `emitKnownFnSat` routes the `isKnownFn` call site
   through the same PAP machinery when under-applied.
3. **Top-level value globals initialised in source order, not dependency order.**
   The native `@main` init prologue computed each nullary value-binding rhs in
   SOURCE order, but the parser binds combinator values FORWARD of their producers
   (`prog = andThen skip …`, `skip` defined later) → `prog` captured the
   still-zero `@mdk_g_skip` cell → null `runP` crash. Fix: `orderedValBinds`
   topologically sorts value bindings by their EAGER inter-global references
   (`eagerVars` — like `freeVars` but does NOT descend into `CLam` bodies, since a
   reference inside a closure resolves at call time, not init time; counting it
   forges false cycles between mutually-recursive combinators like
   `stmtsLoop`/`stmtsCons`). A genuine value cycle keeps source order.
   Companion fix: a not-yet-initialised global reference now emits a deferred
   `load @mdk_g_<name>` (resolved at the instruction's RUNTIME) instead of a gap
   `0` — critical for a reference INSIDE a lambda body emitted during an enclosing
   global's init (the closure runs long after every global is initialised, so the
   load sees the real value; a baked-in `0` was a permanent null).
4. **String `==`/`!=` between statically-untyped operands compared as pointers.**
   B1 fixed `emitCmp` to route `LTStr` operands through `@mdk_string_eq`, but two
   String-typed PARAMETERS used only in `n == name` (coalesceClauses' clause
   grouping) infer to `LTInt` (the emitter's body-based `inferSigs` can't resolve
   two mutually-dependent params), so the integer `icmp eq` compared heap
   pointers → distinct equal strings tested unequal → `where`-block `go` clauses
   were not coalesced. Fix: a new runtime helper **`mdk_value_eq`** (in
   `runtime/medaka_rt.c`, mirroring `mdk_append`'s runtime String/List
   discrimination) distinguishes a boxed String cell (header `MDK_STR_TAG`) from an
   immediate at run time; `emitCmp` routes the unknown-type (`LTInt`) `==`/`!=`
   case through it. Ordering ops and statically-typed operands keep the integer
   compare.

### Validation
- `test/bootstrap_parse.sh` → **26/26**. `test/bootstrap_lex.sh` stays **19/19**.
- All `diff_selfhost_*` gates byte-identical (the four fixes are emit-only /
  runtime-helper; none touch a front-end-shared dump path).

## B3 — native DESUGAR ✅ **DONE (26/26 byte-identical to the interpreter)**

**Result: 26/26 `test/parse_fixtures/*.mdk` byte-match** the interpreter. The
self-hosted DESUGAR stage (parse + desugar) natively compiled, end-to-end,
producing the SAME canonical desugared-AST S-expression (`programToSexp`) as
`medaka run selfhost/desugar_main.mdk <fixture>`.

Desugar adds passes (`deriving`, record puns, container literals, list
comprehensions, do-blocks, operator sections, string interp, `?`-questions) on
top of the parser, so the native binary now includes `desugar.mdk`'s code — more
emitter surface than B2. It surfaced **two real emitter bugs**, both clean fixes
in `selfhost/llvm_emit.mdk`.

**Harness:** `test/bootstrap_desugar.sh` (clone of `bootstrap_parse.sh`:
ORACLE/entry = `selfhost/desugar_main.mdk`, FIXDIR = `test/parse_fixtures`, same
generic driver, real `core.mdk`, libgc/clang block, `-Wl,-stack_size` flag, `()`
Unit-auto-print convention). Both sides emit selfhost S-expressions → raw
byte-diff.

### Two emitter bugs fixed (both in `selfhost/llvm_emit.mdk`)
1. **Constructor with arity>0 used FIRST-CLASS → built a malformed nullary cell.**
   `map PVar vars` (deriving's `conPatVars`) passes the constructor `PVar`
   (arity 1) UNAPPLIED to `map`. `emitApp` only allocates a ctor cell when the
   ctor is SATURATED; a bare/partial ctor name reaches `emitVar`, which did
   `emitCtorAlloc e x []` — a ZERO-FIELD `PVar` cell (an immediate tag), NOT a
   callable closure. `List.map` then loaded a "code ptr" from that immediate and
   `call`ed it → `SIGBUS`. Fix: `emitVar` now eta-wraps an arity>0 ctor into a
   captureless static closure (`emitCtorEtaClosure` → `emitCtorEtaDefine`, mirror
   of the known-fn `emitEtaClosure` but the forwarder body is `emitCtorAlloc` over
   its `%argK` words). Arity-0 ctors stay the immediate `emitCtorAlloc e x []`
   (already a complete value). Surfaced by every `deriving (Eq|Ord|Debug|Display)`
   on a constructor that carries fields (`datatypes.mdk`, `decls_extra.mdk`).
2. **Guarded clause falling through to a later, broader clause → `@mdk_oob`.**
   `rewriteRecordPun recordNames (ESetLit name items) | <guard> = … ` followed by
   a catch-all `rewriteRecordPun _ e = e`: when the guard fails, desugar lowers it
   to `CApp (CVar "__fallthrough__") (CLit LUnit)`, which the interpreter treats as
   "this clause didn't match → try the next clause" (`eval.mdk`'s VFallthrough →
   `fallthroughToNone`). The emitter compiled `__fallthrough__` to `call
   @mdk_oob()` (abort) and built ONE combined Maranget tree whose leaf bodies could
   not branch to a sibling clause — so a Set/Map literal (`Set { … }` parses as
   `ESetLit`, hitting the guarded clause; its guard `contains name recordNames`
   fails because `Set` is not a record) aborted with "array index out of bounds".
   Fix: `emitClauseTree` now emits the clauses as a CHAIN of single-clause decision
   trees (`emitClauseChain`) sharing one result slot + end label; a module-level
   `fallthroughLabelRef` holds the current next-clause block. A clause's pattern
   miss (`CTFail`) OR a guard `__fallthrough__` branches to that label; the last
   clause's label is the OUTER fallthrough (`""` → the historical `@mdk_oob` at
   top level). `emitDecision` (a `match` in expression position) saves/nulls the
   ref across its own tree, so a body-level match's non-exhaustive `CTFail` stays
   a genuine abort rather than inheriting the enclosing clause's fallthrough. The
   gates compare program OUTPUT (not IR text), so re-structuring multi-clause IR is
   safe as long as semantics match — they do.

### Validation
- `test/bootstrap_desugar.sh` → **26/26**. `bootstrap_parse.sh` stays **26/26**,
  `bootstrap_lex.sh` stays **19/19**.
- All `diff_selfhost_*` gates byte-identical (both fixes are emit-only; none touch
  a front-end-shared dump path). The clause-chaining change re-shapes the IR for
  every multi-clause function, but every gate diffs against the interpreter and
  passes.

## B4 — native RESOLVE ✅ **DONE (14/14 byte-identical to the interpreter)**

**Result: 14/14 `test/resolve_fixtures/*.mdk` byte-match** the interpreter. The
self-hosted RESOLVE stage (name binding / scope resolution) natively compiled,
end-to-end, emitting the SAME diagnostic S-expressions (`resolveToLines`) as
`medaka run selfhost/resolve_main.mdk <runtime> <core> <fixture>`. The fixtures
are mostly ERROR-path cases (`UnboundVariable`, `DuplicateDefinition`,
`ExternWithBody`, `MethodNotInInterface`, `UnknownType`/`Ctor`/`Interface`/
`Effect`, `NonRecursiveValueLet`, `AsPatternMisplaced`, `QuestionMisplaced`,
multi-error) — the native binary produces byte-identical diagnostic lines.

Unlike B1–B3, `resolve_main` takes **THREE file-path args** — `<runtime.mdk>
<core.mdk> <target.mdk>` — and seeds its name environment by parsing
`runtime.mdk` (externs) + `core.mdk` (prelude) at RUNTIME, then parses+desugars
the target and resolves it. (The emit-time prelude is still the real
`stdlib/core.mdk`; resolve_main *reading* runtime/core at runtime is independent
of that.)

**Harness:** `test/bootstrap_resolve.sh` (clone of `bootstrap_desugar.sh`:
ORACLE/entry = `selfhost/resolve_main.mdk`, FIXDIR = `test/resolve_fixtures`,
same generic driver, real `core.mdk`, libgc/clang block, `-Wl,-stack_size` flag,
`()` Unit-auto-print convention). BOTH the oracle and native invocations pass the
3 args (`$RUNTIME $CORE $fix`); native `args ()` returns argv[1..] so all three
reach `resolve_main`. Both sides emit selfhost diagnostics running the SAME
deterministic resolve code → raw byte-diff, NO sort/normalization. (The
`.expected` files in `resolve_fixtures/` are the OCaml-reference golden for
`diff_selfhost_resolve.sh`; they are NOT this harness's oracle.)

### One emitter bug fixed (in `selfhost/llvm_emit.mdk`)
**List-typed `++` chain mis-selected `mdk_string_append` → memmove crash.**
`buildEnv` (resolve.mdk) builds the name environment with chained list appends:
`externNames runtimeDecls ++ pValues ++ userValueNames prog ++ imported` (each
operand a `List String`). The emitter selects `++`'s helper by the LEFT operand's
static LTy: `LTStr` → `mdk_string_append`, `LTCon` → `mdk_list_append`, else →
runtime `mdk_append` (whose result it *defaults* to `LTStr`). Two compounding
inference gaps:
- `typeOf` had **no `CList` arm**, so the empty-list base of a list-returning
  multi-clause fn (`externNames [] = []`) typed as `LTInt` → the fn's inferred
  return LTy was `LTInt` → the first `++` fell to the runtime-dispatch arm whose
  result defaults to `LTStr` → the CHAINED outer `++` saw `LTStr` and statically
  emitted `mdk_string_append` on a List cell → `memmove` over a garbage length →
  segfault.

  Fix: `typeOf (CList _) = LTCon` and `typeOf (CRangeList _ _ _) = LTCon` (a
  list/range-list is a Cons/Nil constructor chain). Now `externNames` & friends
  infer `LTCon`, so the whole `++` chain routes through `mdk_list_append`.
- That `CList`-fix exposed a second bug in `paramUseTy`: it inferred a param's
  type from a `::` operand as if `::` were a SYMMETRIC binop (`l :: r` ⇒ left
  takes right's type). But `::` is asymmetric — `l` is the ELEMENT, `r` is
  `List element`. With `CList → LTCon`, `splitLines`'s String accumulator `acc`
  (used as `acc :: splitLines …`) suddenly inferred `LTCon` from the list tail,
  so its OTHER use `acc ++ charToStr …` (a genuine String append) emitted
  `mdk_list_append` on a String → crash (the inverse of the first bug).

  Fix: a dedicated `paramUseTy … (CBinPrim "::" l r)` arm — a var on the RIGHT of
  `::` is a list (`LTCon`); a var on the LEFT (the element) is NOT inferable from
  the list tail, so it's skipped (recurse for another determining use). `acc`
  then correctly infers `LTStr` from its `++ charToStr` use.

### Validation
- `test/bootstrap_resolve.sh` → **14/14**. `bootstrap_desugar.sh` stays **26/26**,
  `bootstrap_parse.sh` **26/26**, `bootstrap_lex.sh` **19/19** (the `paramUseTy`
  fix was found *via* a triple_str lexer regression and re-greened it).
- All `diff_selfhost_*` gates byte-identical (both fixes are emit-only inference
  refinements; neither touches a front-end-shared dump path).

## B5 — native METHOD-MARKER ✅ **DONE (26/26 byte-identical to the interpreter)**

**Result: 26/26 `test/parse_fixtures/*.mdk` byte-match** the interpreter. The
self-hosted MARK stage (`marker.mdk`, ~290 lines — rewrites interface-method /
constrained-fn `EVar` occurrences to `EMethodRef` / `EDictApp`) natively
compiled, end-to-end, emitting the SAME canonical marked-AST S-expression
(`programToSexp (markWithPrelude …)`) as `medaka run selfhost/mark_main.mdk
<core> <fixture>`.

Like B4 but `mark_main` takes **TWO file-path args** — `<prelude.mdk>
<target.mdk>` — parsing+desugaring the prelude (`stdlib/core.mdk`) and the
target at RUNTIME, then `markWithPrelude`-ing the target against the prelude's
interface methods + constrained fns. (The emit-time prelude is still the real
`stdlib/core.mdk`; mark_main *reading* core at runtime is independent of that.)
No `runtime.mdk` arg — mark doesn't seed an extern environment.

**Harness:** `test/bootstrap_mark.sh` (clone of `bootstrap_resolve.sh`:
ORACLE/entry = `selfhost/mark_main.mdk`, FIXDIR = `test/parse_fixtures` — the
same 26-fixture corpus as B3 desugar, which all parse+desugar+mark cleanly;
**2-arg invocations** `<core> <fixture>` instead of B4's 3 args; generic emit
driver, real `core.mdk` prelude, libgc/clang block, `-Wl,-stack_size,0x20000000`,
`()` Unit-auto-print convention; raw byte-diff, NO sort, NO float normalization).

### Zero new emitter bugs
The marker stage surfaced **no new divergences** — 26/26 on the first run. It is
a small structural rewrite over the already-emittable AST/CExpr surface, reusing
the prior slices' emitter fixes (string `==`, PAP closures, value-global init
ordering, ctor eta-wrap, guarded-clause chaining, `CList → LTCon` inference). No
`selfhost/llvm_emit.mdk` or `runtime/medaka_rt.c` change was needed.

### Validation
- `test/bootstrap_mark.sh` → **26/26**. Earlier bootstraps stay green:
  `bootstrap_resolve.sh` **14/14**, `bootstrap_desugar.sh` **26/26**,
  `bootstrap_parse.sh` **26/26**, `bootstrap_lex.sh` **19/19**.
- All 15 `diff_selfhost_*` gates byte-identical (harness-only slice — no emitter
  or front-end change).

## B6 — native TYPECHECK ✅ **DONE (10/10 byte-identical to the interpreter)**

**Result: 10/10 `test/typecheck_fixtures/*.mdk` byte-match** the interpreter.
The self-hosted TYPECHECK stage (`typecheck.mdk`, ~4000 lines — the largest,
most stateful module: Hindley-Milner inference via mutable tyvar cells, level
brackets, effect rows, the heaviest typeclass dispatch in the compiler, ~378
`Ref`/`set_ref`/`.value` sites) natively compiled, end-to-end, emitting the SAME
inferred top-level schemes (`name : scheme`, one per binding) as `medaka run
selfhost/typecheck_main.mdk <fixture>`. This is the real completeness test of the
native backend, and it surfaced **two genuine emitter/driver bugs**.

`typecheck_main` takes **ONE file-path arg** (`<target.mdk>`); the fixtures are
self-contained / prelude-free, so per-fixture inference depth stays bounded (the
prelude is NOT typechecked at runtime). No segfault from stack depth — the
`-Wl,-stack_size,0x20000000` (512 MB) flag was sufficient; the deferred
big-stack / TRMC work was NOT needed for this slice.

**Harness:** `test/bootstrap_typecheck.sh` (clone of `bootstrap_resolve.sh`:
ORACLE/entry = `selfhost/typecheck_main.mdk`, FIXDIR = `test/typecheck_fixtures`;
**1-arg** invocation `<fixture>`; generic emit driver, real `core.mdk` prelude,
libgc/clang block, `-Wl,-stack_size,0x20000000`, `()` Unit-auto-print
convention). Like `diff_selfhost_typecheck.sh`, **BOTH sides are SORTED** before
the byte-compare (top-level bindings emit in a non-line-comparable order; the
`()` Unit line sorts to the same position on both sides).

### Two bugs fixed

**1. `private_mangle.mdk` — collision-rename wrongly renamed an EXPORTED
function (the sole emit blocker).**
`typecheck_main` loads `typecheck.mdk`, which defines a *private* `joinNl`, while
`util.mdk` defines an *exported* `joinNl` that `exhaust.mdk` (also loaded)
imports by bare name. `mangleUnits` collision-renames a unit's private
top-level functions that collide across units. But the `export` keyword precedes
the SIGNATURE, so the function's `DFunDef` clause (parsed on the next line as a
separate decl) carries `pub = False` — the export lives on the `DTypeSig True`
(mirroring `resolve.mdk`'s `expValuesDirect`, which exports off `DTypeSig True`).
`mangleUnits` keyed solely off `DFunDef.pub`, so it renamed `util.joinNl` to
`util__joinNl` while `exhaust.mdk`'s bare imported reference was left unrewritten
→ the self-hosted `elaborateModules` (run during emit) panicked `unbound
variable: joinNl`. Fix: collect each unit's pub-via-`DTypeSig`/`DExtern` names
(`pubSigNames`) and exclude them from the rename in `declRenameEntries` /
`letBindRenameEntry`.

**2. `llvm_emit.mdk` — chained `++` over a runtime-dispatched operand emitted a
direct `@mdk_string_append` on a list value → SIGSEGV.**
The `++` lowering's unknown-operand fallback emits the runtime-dispatched
`@mdk_append` (correct value: inspects the cell header, string→string append /
list→list append) but tagged its result `LTStr`. A CHAINED `++`
(`a ++ b ++ c` = `(a ++ b) ++ c`) then saw the inner result's static `LTStr` and
emitted a DIRECT `@mdk_string_append` for the outer — which reads a list cell as
a String header and segfaults. `typecheck.mdk`'s `freeEffvars` builds a
`List Int` exactly this way (`freeEffvars a ++ rowFreeEffvars r ++ freeEffvars
b`), so EVERY polymorphic scheme (whose generalization walks effvars) crashed.
Fix: a new `LTUnknown` LTy tags the runtime-dispatched-append result. A `++` over
an `LTUnknown` left operand re-routes through `@mdk_append` (NOT a direct
`@mdk_string_append`), and `==`/`!=` route through `@mdk_value_eq` (runtime
String/word discriminator) instead of `@mdk_string_eq`. `LTUnknown` otherwise
follows `LTStr` (print → `@mdk_print_str`, `isStrLTy`), since the dominant
string-builder downstream is the only one reached in practice. Value-identical to
the old direct path for the string case, so all 15 `diff_selfhost_*` gates stay
byte-identical.

### Validation
- `test/bootstrap_typecheck.sh` → **10/10**. Earlier bootstraps stay green:
  `bootstrap_mark.sh` **26/26**, `bootstrap_resolve.sh` **14/14**,
  `bootstrap_desugar.sh` **26/26**, `bootstrap_parse.sh` **26/26**,
  `bootstrap_lex.sh` **19/19**.
- All 15 `diff_selfhost_*` gates byte-identical (the `LTUnknown` change is
  value-equivalent to the prior `LTStr` default for every string case the gates
  exercise; the list case it fixes was a latent crash never hit before B6).

## B7 — native EVAL ✅ **DONE (20/20 byte-identical to the interpreter)**

**Result: 20/20 `test/eval_fixtures/*.mdk` byte-match** the interpreter. The
self-hosted EVAL stage (`selfhost/eval.mdk`, ~1765 lines — the tree-walking
interpreter itself: closures/env/match, `VMulti` UNTYPED typeclass dispatch,
`externBindings` primitive table, `pp_value` rendering) compiled natively
(emit → `clang` → link `runtime/medaka_rt.c` + libgc) renders the SAME
`pp_value` of the `main` binding as `medaka run selfhost/eval_main.mdk
<fixture>`.

**With B7, ALL SEVEN pipeline stages — lex → parse → desugar → resolve → mark
→ typecheck → eval — are individually native-compiled and proven byte-identical
to the tree-walker interpreter.**

`eval_main` takes **ONE file-path arg** (`<target.mdk>`); the fixtures are
self-contained / prelude-free and aggregate their results into a single `main`
value, so the output is ONE deterministic `pp_value` line. eval_main uses the
slice-1 untyped path (no marker/typecheck — arg-tag "first impl wins"
`VMulti` dispatch), so this slice stresses runtime dispatch hardest of all the
stages.

**Harness:** `test/bootstrap_eval.sh` (models `bootstrap_typecheck.sh`:
ORACLE/entry = `selfhost/eval_main.mdk`, FIXDIR = `test/eval_fixtures`,
generic emit driver `selfhost/llvm_bootstrap_lex_main.mdk` with gap-recording +
`private_mangle.mangleUnits`). Output is a SINGLE deterministic value line —
**NO sort, NO float normalization** (both sides run the SAME eval). eval_main
uses **`putStrLn`** (not `putStr`), so its stdout is `<value>\n`; the native
runtime then auto-prints `main`'s Unit as `()\n`, giving `<value>\n()\n`. The
oracle is rebuilt to the same shape (`<value>` + newline + `()`); the value
content is compared byte-for-byte.

### Two emitter bugs fixed

1. **Over-application of a known function** (`selfhost/llvm_emit.mdk`,
   `emitKnownFnSat`). A known fn of arity N applied to **more than N** args
   (`makeAdder 10 5` — `makeAdder n = (m => n + m)` returns a closure that
   consumes the extra arg) fell into the saturated `otherwise` branch, which
   passed ALL args to `@mdk_<name>`: the trailing args were silently dropped
   into a function that ignores them and the returned closure was never applied
   → garbage result. Fix: a new `lengthS argOps > arity` guard (`emitOverApp`)
   saturates the direct call with the FIRST N args, then applies the residual
   closure VALUE to each remaining arg through an indirect call (`emitApplyExtra`
   — load code_ptr from cell field 0, `call codePtr(closure, arg)`, the same
   shape as `emitIndirect`). Added local `takeS`/`dropS` helpers. This is a
   GENERAL emitter correctness fix (over-application was previously OUT of
   scope) — every prior stage was green only because none over-applied a
   known fn.

2. **Flat-emit pub-name collision with a redefined prelude function**
   (`selfhost/private_mangle.mdk`). `eval.mdk` exports its own `apply`
   (`apply f x = match applyOpt f x …`, the dispatch-aware value application)
   while the prelude `core.mdk` ALSO exports `apply` (`apply f a = f a`). The
   mangler renamed only *private* cross-module collisions and kept all pub names
   bare, so both `apply`s emitted `@mdk_apply`; LLVM dropped the duplicate
   (keeping the prelude's naive `f a`), and `eval.mdk`'s `applyValue`/`applyDicts`
   /`applyValues` calls routed to it — calling a tagged `Value` (VClosure/VMulti/…)
   as a raw closure → load garbage code_ptr → `EXC_BAD_ACCESS` at the indirect
   `blr`. Fix: a NON-CORE module that **redefines a prelude (core) name** — pub or
   private — now gets that definition renamed to `<mid>__<name>` with its
   intra-unit references rewritten (`shouldRename`'s `preludeRedef` rule;
   `coreNames` threaded from `mangleUnits`). Core keeps the bare prelude symbol
   for importers. This models the correct local-shadows-import semantic the
   loader already enforces. `private_mangle` runs ONLY in the emit drivers (never
   the oracle/golden drivers), so no golden/oracle dump changes. (`eval.mdk`'s
   `apply` is genuinely module-internal: importers use the `applyValue` alias
   precisely because `import eval.{apply}` is ambiguous with the prelude.)

### Validation
- `test/bootstrap_eval.sh` → **20/20**. Earlier bootstraps stay green:
  `bootstrap_typecheck.sh` **10/10**, `bootstrap_mark.sh` **26/26**,
  `bootstrap_resolve.sh` **14/14**, `bootstrap_desugar.sh` **26/26**,
  `bootstrap_parse.sh` **26/26**, `bootstrap_lex.sh` **19/19**.
- All `diff_selfhost_*` gates byte-identical (the over-app + prelude-redefine
  mangle fixes are emit-only and dead for every gate the corpus exercises — no
  golden corpus over-applies a known fn or redefines a prelude pub name through
  the flat-emit `private_mangle` path).

---

## C1 — native emitter reproduces IR ✅ **DONE (6/6 byte-identical to the interpreter)**

The seven `B*` slices natively compiled each PIPELINE STAGE and proved each
byte-matches the tree-walker. C1 is the first step of self-hosting the COMPILER
BACK-END: natively compile the EMITTER ITSELF —
`selfhost/llvm_emit_modules_main.mdk`'s whole module graph (`llvm_emit.mdk` +
`core_ir_lower.mdk` + the front end + prelude) — and prove the resulting native
`emit` binary turns each fixture into the SAME LLVM IR the interpreted emitter
does. This is the largest, most string-heavy emit target yet (the `.ll` is
~10 MB) and the FIRST time the emitter's OWN code runs natively, so it exercises
emitter correctness the earlier slices never did.

Harness: `test/selfcompile_emit.sh`. Builds the native `emit` via the gap-tolerant
bootstrap driver (`llvm_bootstrap_lex_main.mdk`, real `core.mdk` at BUILD time so
its dead-code gaps become placeholders; the native binary's own runtime
`emitProgram` has gap-recording OFF). Then for each of the 6
`test/llvm_fixtures_modules/<dir>` (same corpus + EMPTY-core invocation as
`diff_selfhost_llvm_modules.sh`) it diffs `ir_native` vs `ir_interp`
byte-for-byte. Native auto-prints `main`'s `Unit` as a trailing `()\n`, appended
to the interpreted IR before the diff (same convention as the `bootstrap_*.sh`).

### One emitter bug fixed (in `selfhost/llvm_emit.mdk`)

**Guarded match arms in the emitter's OWN source → blanked bodies in the native
emitter.** `llvm_emit.mdk` was the only selfhost stage that still contained
*guarded* `match` arms (the other six stages were written guard-free precisely
because the emitter cannot lower a guard — `emitTree`'s `CTGuard` arm is a
documented gap). When the gap-tolerant driver self-compiled the emitter, those
two guarded arms each became a `store i64 0` placeholder (the recording-ON gap
shape), so in the native binary the affected functions silently returned `0`/Unit:

- `emitGroupBody`'s `[(pats, body)] if allPVar pats => …` — every arity-≥1 impl
  method (`describe Dog = 1`, etc.) is a single-clause group, so the native
  emitter matched the `[_]` list shape, hit the gapped guard, and emitted an
  EMPTY impl-method body (`define … { entry: }`) instead of the decision tree.
  This broke 4 of the 6 fixtures (adt_dispatch, dict_constr_module,
  impl_body_prim_dispatch, prim_arg_dispatch). The two passing fixtures
  (data_ctor — no impls; return_dispatch — arity-0 impls via the literal-`0`
  clause, no guard) were exactly the ones that never reach the guarded arm.
- `emitCmp`'s `LTInt if isEqOp op => emitValueEq …` — the same gap shape for the
  unknown-static-type equality route.

Fix (emit-only, IR byte-identical to the guarded form): rewrite both guarded
arms as `if`-EXPRESSIONS. `emitGroupBody` matches `[(pats, body)] =>` then
branches on `if allPVar pats then … else emitClauseTree …`; `emitCmp` matches
`LTInt =>` then `if isEqOp op then emitValueEq … else emitIntCmp …` (the shared
integer-compare path factored into a new `emitIntCmp`). This is the established
self-compilability convention — the same reason the other stages carry no
guards — not a semantics change: the interpreted emitter produces identical IR
(`diff_selfhost_llvm_modules.sh` stays 6/6).

### Validation
- `test/selfcompile_emit.sh` → **6/6** byte-identical (adt_dispatch, data_ctor,
  dict_constr_module, impl_body_prim_dispatch, prim_arg_dispatch,
  return_dispatch).
- All seven bootstraps stay green: `bootstrap_lex.sh` **19/19**,
  `bootstrap_parse.sh` **26/26**, `bootstrap_desugar.sh` **26/26**,
  `bootstrap_resolve.sh` **14/14**, `bootstrap_mark.sh` **26/26**,
  `bootstrap_typecheck.sh` **10/10**, `bootstrap_eval.sh` **20/20**.
- All `diff_selfhost_*` gates byte-identical (the guard→`if` rewrites are
  semantics-preserving — the interpreted emitter's IR is unchanged).


## C2 — native compiler compiles a REAL program ✅ **DONE (19/19 + IR byte-match)**

C1 proved a native-compiled emitter reproduces the interpreted emitter's IR on
small module fixtures. C2 takes the next step: use a NATIVE-compiled, gap-tolerant
emitter to compile the self-hosted LEXER DRIVER (`selfhost/lex_main.mdk`)
end-to-end — the first time the native compiler compiles a REAL, prelude-bearing
program. Same end state as B1 (`bootstrap_lex.sh`, 19/19) EXCEPT the emit step is
done by a NATIVE binary instead of the OCaml-hosted interpreter.

Harness: `test/selfcompile_lex.sh`.
1. Build the native gap-tolerant emitter: interpreted `llvm_bootstrap_lex_main.mdk`
   emits its OWN module graph → clang + `runtime/medaka_rt.c` + libgc → native
   `bootstrap-emit`.
2. `./bootstrap-emit <runtime> <core> lex_main.mdk <selfhost>` → `lex.ll` — the
   BIG, REAL emit (the native emitter recurses over lex_main's whole graph and
   builds a multi-MB IR string).
3. clang `lex.ll` → native `lex`; for each `test/diff_fixtures/<f>.mdk`,
   `./lex <f>` byte-matches the interpreter oracle (`medaka run lex_main.mdk <f>`,
   with the trailing-`()` Unit auto-print convention). Plus the STRONGER check:
   diff the native-emitted `lex.ll` against the interpreted-emitter's `lex.ll`
   byte-for-byte.

### Stack story — option (a), 512 MiB, no worker thread

The native emitter's deep Core-IR recursion + multi-MB IR-string construction over
lex_main's whole graph is the real-size input that stresses the native emitter's
OWN stack. It fits within the largest `-Wl,-stack_size` the linker allows on arm64
macOS — **0x20000000 (512 MiB)**; the linker REJECTS anything larger on arm64
(`ld: -stack_size must be <= 512MB on arm64 platforms`). So option (a) — the
max-allowed stack flag — sufficed, and NO big-stack worker thread (option (b)) was
needed. `STACK_SIZE` is overridable but defaults to the 512 MiB ceiling.

### One emitter bug fixed (string ordering `<`/`<=`/`>`/`>=`)

C2 is the first program where the native emitter RUNS string ordering comparisons
at emit time: its own `private_mangle.sanitizeId` / `safeChar` do `c >= "a"`,
`c <= "z"`, etc. to sanitize module names. `emitStrCmp`'s `otherwise` arm (the
`<`/`>`/`<=`/`>=` path on strings) carried a documented deferral — it did an
integer `icmp` on the string *pointers* ("Ordering ops on strings are not exercised
by the bootstrap; a `@mdk_string_compare` route can replace it when needed").

That pointer compare is wrong for boxed string cells. In the native `bootstrap-emit`
binary it made `safeChar "l" = False` for every non-`_` char, so `sanitizeId`
turned each char of a module id into `_` → `@mdk________emit` instead of
`@mdk_lexer__emit`. The interpreted emitter dodged this (its `safeChar` runs in the
OCaml interpreter, where String `<=` is correct), which is exactly why B1
(interpreted-emit) was green while C2 (native-emit) first diverged ONLY in the
mangled names.

Fix (emit + runtime):
- `runtime/medaka_rt.c`: add `mdk_string_compare_raw(a,b)` → a PLAIN `-1/0/1` i64
  (not the tagged `Ordering` cell `mdk_string_compare` returns for the
  `Ord String.compare` method).
- `selfhost/llvm_emit.mdk`: declare it, and rewrite `emitStrCmp`'s ordering arm to
  `cmp = call @mdk_string_compare_raw(lv, rv)` then `icmp <intPred op> i64 cmp, 0`
  (e.g. `a < b` ⟺ `cmp < 0`), reusing `intPred`'s `slt`/`sgt`/`sle`/`sge` +
  `boolFromI1`. (Note: the operand must be statically `LTStr` for `emitCmp` to route
  here — a string LITERAL on either side suffices, which `safeChar`/the lexer always
  have; two signature-only `String` params with no literal still fall to the LTInt
  default, an unchanged pre-existing limitation not exercised by the lexer.)

This is semantics-preserving for every existing gate (none emit a native String
ordering compare), so all `diff_selfhost_*` gates stay byte-identical and C1 stays
6/6.

### Validation
- `test/selfcompile_lex.sh` → **19/19** byte-match the interpreter oracle, AND the
  native-emitted `lex.ll` == the interpreted-emitter `lex.ll` **byte-for-byte**
  (the C1 guarantee, now at REAL scale: the native emitter reproduced the
  interpreter's compilation of a real, prelude-bearing program).
- `test/selfcompile_emit.sh` stays **6/6**; all seven bootstraps green
  (`bootstrap_lex.sh` 19/19 … `bootstrap_eval.sh` 20/20); all 15 `diff_selfhost_*`
  gates byte-identical.


