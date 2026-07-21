# DIAGNOSTIC-CODES-DESIGN.md

**Status:** IMPLEMENTED — Stage 1 `ab61283c`, Stage 2 `761516e6`. Both stages landed:
codes are authored at push sites (`pushIncompleteImpl` → `"T-INCOMPLETE-IMPL"` in
`compiler/types/typecheck.mdk`, `"W-GUARD-INEXHAUSTIVE"` in
`compiler/driver/diagnostics.mdk`), and `cjDiagnostic` (`compiler/driver/diagnostics.mdk:769`)
emits the full `code`/`kind`/`help`/`fix`/`range`/`severity` JSON contract. This doc's own
body never added a closing status line — it still reads as an open plan; treat the "Decided
upstream" box and the contract shape as the current source of truth, not "not yet decided."

Design + census for **stable error codes on every Medaka diagnostic**. Companion
to `ERROR-QUALITY.md` (the grading key / copy standard). This doc is the
implementation design for its §5 machine-readable contract and its "Open
decisions" §1 (code scheme) and §5 (warning-range regression).

**Decided upstream (do not re-litigate):**
- **Push-site threading** — codes are *authored* at each diagnostic-producing
  site (or at a per-stage chokepoint), never inferred by a post-hoc classifier.
- **Scheme: per-stage-prefixed readable kebab codes** — `L-*` lex, `P-*` parse,
  `R-*` resolve, `T-*` type, `W-*` warnings. Exact prefixes + per-kind codes
  proposed in §2.
- **Staging** — Stage 1 = codes + `kind` + the warning `{0,0}`-range fix; Stage 2
  = `help`/`fix` JSON fields. Both designed here; Stage 1 detailed.

---

## 0. TL;DR for the orchestrator

- **Distinct error kinds per stage:** DERIVE, never read from here. The codes
  emitted as literals (lex `L-*`, parse `P-*`, warnings `W-*`) enumerate with:

  ```sh
  grep -ohE '"[LPRTW]-[A-Z0-9-]+"' compiler/driver/diagnostics.mdk | sort -u
  ```

  Resolve and typecheck are **ADTs**, so their kinds are counted at the data
  declaration, not by this grep. This bullet used to carry per-stage counts and a
  total; every one of them had rotted (the "lex 4" was 11 by #594), because a
  written-down count has no derivation and no expiry — the same disease #556 fixed
  in `diagnostics.mdk` itself. Run the command.
- **Threading:** three push funcs in typecheck (`pushTypeError`,
  `pushTypeErrorOnce`, `pushTypeErrorOnceAt`) are the only type-error entry
  points → **~55 call sites** must supply a code. Resolve needs **0 call-site
  changes** (one new `resErrorCode : ResError -> Code`, 13 arms). Lex/parse
  attach at their ADT boundary (few sites). **`kind` is DERIVED from the code
  prefix** — only `code` is authored.
- **Golden churn (measured on prototype):**
  - **JSON-only** (code/kind in `cjDiagnostic`): **9** `check_json` goldens (+ a
    handful of LSP JSON goldens). `error_quality` / `native_cli` **unchanged**.
  - **CLI-shows-code** (code in the `ppDiagCliSrc` header): **35** `error_quality`
    goldens + **~57** `native_cli/check` goldens + the 9 JSON = **~100** goldens.
    (`diff_compiler_diagnostics` stays clean iff we keep the code out of `ppDiag`,
    the loc-free diff form — a deliberate lever.)
  - **Recommendation: Stage 1 = JSON-only** (≈9 goldens; satisfies ERROR-QUALITY
    §5 "add `code`+`kind` to every diagnostic"). CLI `[CODE]` is a separate
    opt-in with a one-time ~90-golden recapture.
- **Warning-range locus:** `cjDiagnostic`'s `SevWarning (Some loc)` arm
  (`diagnostics.mdk:528-537`) bakes `path:L:C: Warning:` into `message` and emits
  `{0,0}`. The loc is already snapshotted (`matchWarningLocs`, M2 confirmed); the
  fix is renderer-side + threading loc through the multi-module warn path.
- **Stage-1 size: M.** No re-mint (diagnostics/typecheck self-compile but are not
  the emitter); cost is the ~55 authored codes + fixpoint + golden recapture.

---

## 1. Site inventory (by stage)

Counts are of **distinct error KINDS** (codes map to kinds, not raw sites);
raw-site counts noted where they diverge.

### Lex — `compiler/frontend/lexer.mdk` (`TLexError String`, **5 kinds**)

(Site line-numbers are not tracked here — they rot; grep `lexErrorTok` for the
live set. The kinds are the stable handle.)

| Message | Kind |
|---|---|
| `unterminated string literal` | unterminated-string |
| `unterminated block comment` | unterminated-comment |
| `invalid escape sequence '\x'` (string AND char paths — shared) | bad-escape |
| `character literal must be a single codepoint …` / `… is empty` / `… is not terminated` | bad-char-literal |
| `unexpected character 'c'` | bad-char |

Lexer errors do not reach `Diag` directly — a `TLexError` token is surfaced by
`parseResult` as a `ParseError` (the driver renders it exactly like a parse
error). So an `L-*` code must be recovered from the message or threaded from the
`RawTok`; see §3.

### Parse — `compiler/frontend/parser.mdk` (`ParseError Int Int String`, **~3 kinds**)

~36 distinct `failP "expected …"` / `PErr` messages, **all one ADT** funneled
through `failP`/`PErr`. For coding purposes they collapse to:

| Kind | Trigger | Kind name |
|---|---|---|
| general parse error | every `failP "expected …"` (~34 messages) | parse |
| unexpected EOF | `advanceR TEof` → `"unexpected end of input"` (`:178`) | unexpected-eof |
| `/=` typo | `"unexpected '/=' (did you mean '!=' …)"` (`:3508`) | bad-neq-operator |
| foreign-syntax pre-scans | `parseResult` chain: `/* */` block comment, `if … { }` brace block, `for`/`while` loop, `def`/`function` header, trailing `;` (each a pure token scan that fires only on never-valid Medaka shapes, located at the offending token) | brace-block / for-while / def-keyword / block-comment / semicolon |

(The ~34 `expected …` messages stay distinct *prose* under one code — they are
context, not separate categories. If finer codes are later wanted they can split
without breaking existing consumers, since the umbrella `P-PARSE` is stable.)

### Resolve — `compiler/frontend/resolve.mdk` (`data ResError`, **13 variants = 13 kinds**)

Already a discriminated ADT (`:68`), one `ppResError` arm each (`:1072+`):

`UnboundVariable`, `UnknownConstructor`, `UnknownType`, `UnknownEffect`,
`UnknownField`, `FieldNotInRecord`, `DuplicateDefinition`, `UnknownInterface`,
`MethodNotInInterface`, `ExternWithBody`, `PrivateNameAccess`,
`NoExportedConstructors`, `AbstractFieldAccess`, `UnknownModule`,
`AsPatternMisplaced`, `NonRecursiveValueLet`, `DuplicateBinding`,
`AmbiguousOccurrence`, `InternalExternAccess`.

(That is 19 constructors — I listed "13" loosely above; the true count is **19
resolve kinds**. Each is one code, authored in one place: a `resErrorCode`
function, §3.)

### Exhaust — `compiler/frontend/exhaust.mdk` (**1 warning kind**)

- `guardWarning = "Warning: guards may not be exhaustive"` (`:482`) — the only
  diagnostic produced standalone here (guard coverage on the raw AST).

### Typecheck — `compiler/types/typecheck.mdk` (55 push sites / **~25 kinds** + 1 warning)

The 55 sites all go through `pushTypeError` / `pushTypeErrorOnce` /
`pushTypeErrorOnceAt`; the one warning is a direct `setRef matchWarnings`. Distinct
kinds (enumerated from the message families):

| Kind | Representative message | Code (§2) |
|---|---|---|
| type mismatch | `Type mismatch: <a> vs <b>` (`:2273`,`:2282`,`:2952`) | `T-TYPE-MISMATCH` |
| not a function | `This expression has type <T>, which is not a function …` / `'<f>' takes N argument(s) but is applied to M.` (`inferApp` guard) | `T-NOT-A-FUNCTION` |
| method type mismatch | `Method 'm': expected type <a> but got <b>` (`:2270`) | `T-METHOD-MISMATCH` |
| no impl (class) | `No impl of Num for String` (`:8338`) | `T-NO-IMPL` |
| no named impl | `No impl named 'x' found for …` (`:7157`) | `T-NO-IMPL-NAMED` |
| infinite type | `Cannot construct infinite type involving …` (`:2229`) | `T-INFINITE-TYPE` |
| ambiguous instance | `ambiguous instance for '…'` | `T-AMBIGUOUS-INSTANCE` |
| ambiguous field | `Ambiguous field access: '.f' …` (`:3851`) | `T-AMBIGUOUS-FIELD` |
| unknown field | `Unknown field: f` / `Field f does not belong to record R` (`:2985`,`:3720`) | `T-UNKNOWN-FIELD` |
| missing field | `Missing field f in construction of record R` (`:3732`) | `T-MISSING-FIELD` |
| abstract field | `'T' is exported abstractly; its field 'f' …` (`:3812`) | `T-ABSTRACT-FIELD` |
| unknown record | `Unknown record type: R` (`:2958`,`:3906`) | `T-UNKNOWN-RECORD` |
| unknown ctor | `Unknown constructor: C` (`:3010`) | `T-UNKNOWN-CTOR` |
| unbound var (tc) | `Unbound variable: x` (`:3911`) | `T-UNBOUND` |
| missing constraint | `Could not deduce 'Eq a' … add 'Eq a =>'` (`:9628`) | `T-MISSING-CONSTRAINT` |
| recursive alias | `Recursive type alias \`x\`` (`:2661`) | `T-RECURSIVE-ALIAS` |
| alias arity | `Type alias \`x\` expects N argument(s), got M` (`:2793`) | `T-ALIAS-ARITY` |
| effect leak | effect-leak message (`:906`) | `T-EFFECT-LEAK` |
| effect param | `Invalid effect parameter on <L>: …` / host-pattern (`:972`,`:993`) | `T-EFFECT-PARAM` |
| under-determined effect var | `Under-determined effect variable <e> in method 'm' of interface 'I': …` — an interface method with a free effect tail var in RETURN position but no argument position (#784 Option A; dispatch could launder the effect) | `T-EFFECT-UNDETERMINED` |
| effect launder (impl body) | `Effect laundering in impl of 'm' for interface 'I': the body performs <X>, …` — an impl method body performing an INTRINSIC effect (not sourced from any argument) that is absorbed into a declared effect var and laundered to pure at the call site (#803; distinct from `T-EFFECT-UNDETERMINED`, which is signature-shape, and `T-EFFECT-LEAK`, which is a concrete/pure declared row) | `T-EFFECT-LAUNDER` |
| impl pins method-scheme var | `Impl of 'm' for interface 'I' pins the method's quantified type variable(s) 'b' …` / `… identifies quantified type variables …` / `… identifies effect variables …` — an impl (or specialized default) method body constrains a caller-owned quantified variable of the method scheme: pins a type var to a constructed type, identifies two of them (or one with an impl-head var), or identifies two effect vars (W3 method-scheme fidelity, DICT-SEMANTICS §3; #814).  The effect-atom half of the same check (an atom poured into a method effect var at an occurrence whose declared row lacks it) reuses `T-EFFECT-LAUNDER` | `T-IMPL-TOO-SPECIFIC` |
| non-recursive value let | `'x' is not in scope on the RHS of its own binding …` (`:4923`) | `T-NONREC-VALUE-LET` |
| do not a monad | `do requires a monad` | `T-DO-NOT-MONAD` |
| `<-` bind outside do | `bindOutsideDoMsg` — `<-` in a bare (non-`do`) block | `T-BIND-OUTSIDE-DO` |
| cyclic superinterface | `cyclic superinterface: …` | `T-CYCLIC-SUPERINTERFACE` |
| conflicting impl | `conflicting \`impl X\`: defined in … and …` | `T-CONFLICTING-IMPL` |
| incomplete impl | `'impl Iface Ty' is missing method 'm'. …` — an impl omits an interface method that has no default body (P0-17) | `T-INCOMPLETE-IMPL` |
| empty record update | `empty record update` | `T-EMPTY-RECORD-UPDATE` |
| unsupported (internal) | `typecheck: unsupported expression/pattern/operator …` | `T-UNSUPPORTED` |
| **non-exhaustive match** (warning) | `non-exhaustive match — some values may not be covered` (`:4644`) | `W-NONEXHAUSTIVE` |
| **unreachable match arm** (warning) | `unreachable match arm — this pattern is already covered by an earlier arm` | `W-UNREACHABLE-ARM` |

**Distinct-kind totals:** deliberately NOT written down — see the TL;DR bullet for the
one-line `grep` that derives them. The counts that stood here (and the divergent ones in
the TL;DR, which this note tried to reconcile) were both stale: the reconciliation was
itself evidence that a hand-maintained count in a doc is a liability, not a fact. The
table above is the inventory; the grep is the census.

---

## 2. Code taxonomy

Per-stage prefixes: **`L-`** lex, **`P-`** parse, **`R-`** resolve, **`T-`** type,
**`W-`** warning. `kind` (the JSON `kind` field) is **derived** from the prefix:
`L→lex`, `P→parse`, `R→resolve`, `T→type`, `W→warning`. Names are stable/greppable
kebab-case; never renumber (append only).

### Lex
| Code | Kind |
|---|---|
| `L-UNTERMINATED-STRING` | unterminated string literal |
| `L-UNTERMINATED-COMMENT` | unterminated block comment |
| `L-BAD-ESCAPE` | invalid escape sequence |
| `L-BAD-UNICODE-ESCAPE` | Any `\u{…}` escape the lexer must reject. Two families: **ill-formed** — the digit run is empty, is not closed by `}`, or contains a `_` (a digit separator in *integer* literals, deliberately not here — #592); and **well-formed but naming no character** — out of range (`> 10FFFF`), or a UTF-16 surrogate (`D800`–`DFFF`), which is never a scalar value. **The enumeration of causes lives in the guard clauses of `uniEscWellFormed`/`uniEscTermErr`/`uniEscErr` (`compiler/frontend/lexer.mdk`), not in this cell** — read them there. This row used to say "Covers **both**… the two messages", which #592 silently made wrong by adding four more; a list written down here has no derivation and no expiry, so it is stated as a rule instead: *every* `\u{…}` defect shares this one code (as `L-INT-OVERFLOW` does across its two stages) because they are one user-facing defect — "this escape is not a character" — and *every* message therefore opens with the `"unicode escape"` prefix that `parseErrCode` (`compiler/driver/diagnostics.mdk`) keys on, while still naming its specific cause in prose. Three checks are independently load-bearing and none is redundant: shape (an ill-formed run has no codepoint to check at all, and its terminator is not where the scanner assumed — the #592 S0), digit count (`parseRadix` accumulates in a wrapping 63-bit `Int`, so `\u{8000000000000041}` = 2^63+65 once wrapped to `65` and lexed as `A`, which no range check can see), and range (which no digit count can see — `\u{110000}` is 6 digits). Raised from all five `\u{…}` scan sites (char literal, plain/triple string, both interpolation continuations) |
| `L-BAD-CHAR-LITERAL` | A character literal that is not exactly one codepoint (#668). Three causes, one code because they are one user-facing defect — "a `Char` is exactly one codepoint": **empty** (`''`), **multi-codepoint** (`'ab'`), and **unterminated** (`'a`<EOF>, or a valid escape not immediately followed by a closing quote — `'\na'`, and equally a valid `\u{…}` escape not immediately closed, `'\u{41}z` / `'\u{41}ab'`). All three messages open with the `"character literal"` prefix that `parseErrCode` (`compiler/driver/diagnostics.mdk`) keys on; the enumeration lives in the guard clauses of `readChar`/`rawChar`/`escChar` (`compiler/frontend/lexer.mdk`), not this cell. A **bad escape** inside a char (`'\v'`) is NOT this code — it shares `L-BAD-ESCAPE` with the string path via the same `"invalid escape sequence '\x'"` message and the shared `commonEscDecode` table, because "this is not a valid escape" is the same defect in both literal kinds. A valid multi-BYTE single codepoint (`'é'`, `'😀'`) is one codepoint and is accepted — the check counts codepoints (source array elements), never bytes |
| `L-BAD-CHAR` | unexpected character |
| `L-HS-LAMBDA` | stray `\` (Haskell lambda `\x -> e`; suggest `x => e`) |
| `L-HS-DOLLAR` | stray `$` (Haskell low-precedence apply; suggest direct apply/parens/`\|>`) |
| `L-BLOCKCOMMENT` | `/* … */` C-style block comment (suggest `{- … -}` block / `--` line) |
| `L-SEMICOLON` | trailing `;` statement terminator (suggest newline/indentation separation) |
| `L-INT-OVERFLOW` | integer literal out of the 63-bit tagged-`Int` range `[-2^62, 2^62-1]`. Raised from **two** stages, deliberately under one code (#171): the **lexer** rejects magnitude `2^62+1` and above; the **parser** rejects exactly `2^62` in POSITIVE position, which the lexer must admit (it sees only unsigned digits — the `-` is a separate token) so that the writable minimum `-2^62` survives. Splitting these by catching stage would make a consumer key on two codes for one user-facing defect, so both messages share the `"integer literal too large"` prefix that `parseErrCode` (`compiler/driver/diagnostics.mdk`) keys on, and the parser-raised one keeps `kind: "lex"` for the same reason |
| `L-FLOAT-OVERFLOW` | float literal whose magnitude overflows the IEEE-754 double range (e.g. `2e308`) and would parse to `inf` — rejected at the source so it never reaches codegen as an invalid `store double inf` |
| `L-MALFORMED-FLOAT` | (#677) A `.` next to digits with no valid float on the other side. Three shapes, one code — each is "a float literal is malformed", not a separate defect: **leading** (`.5` — a `.` immediately followed by a digit is never valid Medaka; a member-access field name is an identifier, never a digit, so this can only be a float missing its integer part; caught in `singleOp`'s `.` case, skipped when the dot is glued to the end of another expression — `x.5`, `arr[0].5` — where `.5` is ambiguous enough that the pre-existing downstream diagnostic is left in place), **trailing** (`5.` — digits then `.` with nothing after it that could continue a legal-if-ill-typed postfix; caught in `numFinish`, so it only ever fires for a dot immediately following the digit run THAT CALL just scanned — never a dot after an older, already-tokenized literal, e.g. `5.0.toString` is untouched), and **exponent** (`5.e3` — digits, `.`, then something that reads as a decimal exponent; folded into the trailing shape because an `Int`/`Float` literal can never have a REAL field named `e3`, so reading it as the missing fractional digit is always correct). All three messages open with the `"malformed float literal"` prefix `parseErrCode` keys on and embed both the offending spelling and the suggested one in backticks (`` `5.e3` … `5.0e3` ``) so `parseErrHelpFix` can build a machine `fix` without re-deriving either from the diagnostic's single-point `Loc` |
| `L-MALFORMED-RADIX` | (#677) `0x`/`0b`/`0o` immediately followed by the digit separator `_` (`0x_FF`) — `_` is only legal BETWEEN digits (`0xD_EAD`), not right after the prefix. Caught in `scanNumber`, complementing `isRadixPrefix`'s existing "≥1 valid digit after the prefix" requirement. When the literal has digits after the bad `_` run, the message embeds both spellings in backticks (`` `0x_FF` … `0xFF` ``) for a machine `fix`; when it has none at all (`0x_`, `0x___`) there is no safe spelling to suggest, so the message carries only the one backtick pair and `fix` is `None` (`help` still is) |

### Parse
| Code | Kind |
|---|---|
| `P-PARSE` | general "expected …" parse failure (umbrella) |
| `P-UNEXPECTED-EOF` | unexpected end of input |
| `P-BAD-NEQ` | `/=` used for not-equal (suggest `!=`) |
| `P-HS-CASE` | Haskell `case … of` (suggest `match e` with `pattern => body` arms) |
| `P-HS-SIG` | Haskell `f :: T` type-signature syntax (`::` is cons; suggest `f : T`) |
| `P-BRACE-BLOCK` | C-style `{ … }` brace block on `if` (suggest `then`/`else` + indentation) |
| `P-FOR-WHILE` | foreign `for`/`while` loop (suggest recursion or list functions) |
| `P-DEF-KEYWORD` | foreign `def`/`function` header (suggest `f x = …`) |
| `P-RESERVED-KEYWORD` | a reserved keyword (`as`, `test`, `type`, …) used where a variable/pattern name is expected (machine-applicable `fix`: append `_`) |

### Resolve (one per `ResError` constructor)
| Code | Constructor |
|---|---|
| `R-UNBOUND` | `UnboundVariable` — also covers the sibling constructors `UnboundVariableExported` (the name is exported by an already-imported module; suggests the selective import) and `UnboundVariableIsModule` (#514: the name is itself an imported module's id, e.g. bare `import string` then a reference to `string`; a bare import binds no names, so this points at `import string.{…}`/`import string as M` instead of falling through to an unrelated edit-distance guess) |
| `R-UNKNOWN-CTOR` | `UnknownConstructor` |
| `R-UNKNOWN-TYPE` | `UnknownType` |
| `R-UNKNOWN-EFFECT` | `UnknownEffect` — special-cases the removed `Mut`/`Panic` labels with a migration hint (same code) |
| `R-UNKNOWN-FIELD` | `UnknownField` |
| `R-FIELD-NOT-IN-RECORD` | `FieldNotInRecord` |
| `R-DUPLICATE-DEF` | `DuplicateDefinition` |
| `R-UNKNOWN-INTERFACE` | `UnknownInterface` |
| `R-CANNOT-DERIVE` | a `deriving (…)` name no deriver claims (#421). Emitted by `checkDerives` (`compiler/frontend/desugar.mdk`), pushed by the driver, so it accumulates like every other diagnostic. Distinct from `R-UNKNOWN-INTERFACE` on purpose: `deriving (Num)` names a REAL interface that simply has no deriver, so the message reports what was observed ("cannot derive 'Num' for 'Dist'; supported: …") rather than concluding the name is unknown. The supported list is `map fst` of the same deriver table the lookup uses, and `data` and `newtype` have separate tables — a newtype cannot derive `Generic` here, so it is not advertised on one |
| `R-METHOD-NOT-IN-INTERFACE` | `MethodNotInInterface` |
| `R-EXTERN-WITH-BODY` | `ExternWithBody` |
| `R-PRIVATE-NAME` | `PrivateNameAccess` |
| `R-NO-EXPORTED-CTORS` | `NoExportedConstructors` |
| `R-ABSTRACT-FIELD` | `AbstractFieldAccess` |
| `R-UNKNOWN-MODULE` | `UnknownModule` |
| `R-AS-PATTERN-MISPLACED` | `AsPatternMisplaced` |
| `R-NONREC-VALUE-LET` | `NonRecursiveValueLet` |
| `R-DUPLICATE-BINDING` | `DuplicateBinding` |
| `R-DUP-BINDING` | `DuplicateValueBinding` |
| `R-DUPLICATE-SIGNATURE` | `DuplicateSignature` — a top-level name carries >=2 of its own type signatures (unambiguous: a legitimate multi-clause function has exactly one). S-2 fix (2026-07-13); for a name this check covers, it replaces `R-DUPLICATE-BINDING`'s "must be contiguous, merge them" advice — that advice is wrong when the two runs are genuinely unrelated definitions, not one function split by accident. |
| `R-DUP-BINDER` | `DuplicateBinder` (non-linear pattern / repeated parameter) |
| `R-AMBIGUOUS-OCCURRENCE` | `AmbiguousOccurrence` |
| `R-AMBIGUOUS-CTOR` | `AmbiguousConstructor` — a bare constructor USED (pattern or expression) that ≥2 explicitly-importing non-`core` modules bring into scope under the same name (#674). The constructor peer of `R-AMBIGUOUS-OCCURRENCE`. Fired at the USE site (importing both but never using the ctor stays legal). No qualified-ctor syntax exists, so the help points at a selective `import <mod>.{T(..)}` of ONE owning type, never "qualify". |
| `R-INTERNAL-EXTERN` | `InternalExternAccess` |
| `R-IMMUTABLE-ASSIGN` | `ReassignImmutable` — bare reassignment `x = e` of an existing binding (beta immutability model; use `Ref` + `:=`). Note: `let mut` is rejected earlier, at the parser (a `P-*` parse error), not here. |

### Type — see the §1 typecheck table (`T-TYPE-MISMATCH`, `T-NO-IMPL`,
`T-MISSING-CONSTRAINT`, `T-AMBIGUOUS-INSTANCE`, `T-INFINITE-TYPE`,
`T-UNKNOWN-FIELD`, `T-MISSING-FIELD`, …).

### Warnings
| Code | Source |
|---|---|
| `W-NONEXHAUSTIVE` | non-exhaustive `match` (typecheck `matchWarnings`) |
| `W-UNREACHABLE-ARM` | unreachable/redundant `match` arm — pattern already covered by an earlier unguarded arm (typecheck `matchWarnings`; `checkMatchRedundant`) |
| `W-GUARD-INEXHAUSTIVE` | guards may not be exhaustive (exhaust) |
| `W-NONEXHAUSTIVE-CLAUSES` | non-exhaustive clauses of a multi-clause function — a constructor is not covered by any clause (exhaust; the function-clause analog of `W-NONEXHAUSTIVE`) |

### Eval / runtime — `E-*` (`compiler/eval/eval.mdk`, `medaka run`)

Runtime errors surfaced by the tree-walking interpreter. Unlike the compile-time
stages these are reachable on a **well-typed** program (value-dependent). They are
formatted at the `runtimePanic` chokepoint (`eval.mdk`) into the located text
`file:L:C: runtime error [E-*]: <message>` and handed to the `noreturn` `panic`
extern (`kind` = `"error"`, `severity` = 1). See
`RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md`. Internal-invariant panics (compiler-bug
asserts) stay **bare** and carry no code.

| Code | Meaning |
|---|---|
| `E-DIV-ZERO` | integer division by zero |
| `E-MOD-ZERO` | integer modulo by zero |
| `E-INDEX-OOB` | list/array/string index out of bounds |
| `E-SLICE-OOB` | slice bounds out of range |
| `E-PANIC` | explicit user `panic` |
| `E-NONEXHAUSTIVE-MATCH` | `match` had no arm for the runtime value |
| `E-LET-REFUTE` | refutable `let` pattern failed |
| `E-NOT-A-FUNCTION` | applied a non-function value (borderline) |
| `E-MISSING-FIELD` | reserved — record-field miss (borderline; no live emit site on current tree, see design §5) |

---

## 3. Diag ADT + threading mechanism

### ADT change

Today (`diagnostics.mdk:61`):
```
data Diag = Diag Severity String (Option Loc)
```
Proposed:
```
data Diag = Diag Severity Code String (Option Loc)      -- Code = alias for String
```
`Code` is a kebab string (no separate `Kind` field stored). `kind` in the JSON is
**derived** at render time from the code's prefix (`codeKind : Code -> String`),
so authors supply exactly one token. This keeps the ADT one field wider and every
construction site's change mechanical.

**20 `Diag Sev…` construction sites** exist across the compiler
(`diagnostics.mdk`, `medaka_cli.mdk`, `playground_main.mdk`,
`entries/playground_main.mdk`). Each already knows which stage produced the diag
(they map `ResError`/`(msg,loc)`/`ParseError` into `Diag`), so each supplies the
code from the per-stage helper below — not 20 ad-hoc literals.

### Where the code actually attaches (per stage)

- **Resolve — ZERO call-site changes.** `ResError` is already an ADT. Add one
  pure function `resErrorCode : ResError -> Code` (19 arms, beside `ppResError`),
  and at the two `Diag SevError (ppResError e) …` sites
  (`diagnostics.mdk:168`, `:408`) pass `(resErrorCode e)`. Two edited lines,
  one new function.

- **Typecheck — ~55 authored sites.** The three push functions are the only
  entry points. Change their signatures to take the code **first**:
  ```
  pushTypeError       : Code -> String -> <Mut> Unit
  pushTypeErrorOnce   : Code -> String -> <Mut> Unit
  pushTypeErrorOnceAt : Code -> Option Loc -> String -> <Mut> Unit
  ```
  The `typeErrors` ref becomes `Ref (List (Code, String, Option Loc))` and
  `checkProgramDiags`/`checkModulesDiags` propagate the code out. **All ~55
  `pushTypeError*` call sites gain a code argument** — this is the bulk of the
  authoring work, but it is mechanical (each site's kind is obvious from its
  message; see §1 table). The two `setRef matchWarnings` sites similarly gain
  `W-NONEXHAUSTIVE`. *No chokepoint can infer these* — the message strings are
  built inline/by helpers, so the code must be authored at the push. (Signature
  variant considered and rejected: a single `pushTypeError code msg` wrapper that
  defaults the code — the language has no default args, so it saves nothing.)

- **Parse — ADT boundary.** Add a `Code` to `ParseError` (or derive at the single
  `ParseError → Diag` conversion by matching `"unexpected end of input"` /
  `/=`-message → `P-UNEXPECTED-EOF` / `P-BAD-NEQ`, else `P-PARSE`). Deriving at
  the boundary is 0 parser edits; adding the field is ~3 edits. Recommend
  **derive at the boundary** (parser messages stay untouched).

- **Lex — recover at the parse boundary.** `TLexError` surfaces as a
  `ParseError`; match the lexer messages there to emit `L-*` (else `P-PARSE`).
  Alternatively thread a code on `RawTok (TLexError …)`. Recommend the
  message-match at the boundary (contained). This is now **implemented** as
  `parseErrCode` (`compiler/driver/diagnostics.mdk`), so its `L-*` arms — not this
  bullet — are the pattern set; the TL;DR's grep enumerates them. The bullet said
  "the 4 lexer messages … (4 patterns)" long after there were more.

- **Guard warning (exhaust).** `checkGuardExhaustiveness : … -> List String`.
  Map its output to `W-GUARD-INEXHAUSTIVE` at the two conversion sites in
  `diagnostics.mdk` (`:176`, `:441`).

**Authored-code call sites that must change: ~55 (typecheck) + 2 (match-warning
setRefs) ≈ 57.** Everything else (resolve 19 kinds, parse, lex, guard) attaches
via one helper function / boundary match with **0–3** edits each. `kind` is never
authored (derived from prefix).

---

## 4. Warning-range fix (ERROR-QUALITY Open decision §5)

**Confirmed (M2):** the loc IS snapshotted. `matchWarningLocs`
(`typecheck.mdk:2125`) is pushed in lockstep with `matchWarnings`, and
`checkProgramDiags` (`:9832`) returns `zipL matchWarnings matchWarningLocs` —
each warning already carries `(msg, Option Loc)` on the single-file path.

**Where the `{0,0}` is actually produced:** not in the accumulator but in the
**renderer** — `cjDiagnostic`'s warning arm (`diagnostics.mdk:528-537`):
```
cjDiagnostic path src (Diag SevWarning msg (Some (Loc _ sl sc _ _))) = jObject
  [ ("message", JString "\{path}:\{sl}:\{sc}: Warning: \{msg}")   -- loc baked into text
  , ("range",   cjRange 0 0 0 0)                                  -- dummy {0,0}
  , … ]
```
This is a deliberate oracle-compat artifact. The fix:
1. **Renderer:** collapse the special warning arm into the general arm so a
   `SevWarning` with a `Some loc` emits `("range", cjRangeOfLoc src loc)` and a
   bare `message` (no `path:L:C: Warning:` prefix).
2. **Multi-module path:** `checkModulesDiags` currently returns `List String` for
   warns (drops the loc) and `foldModuleTc` (`:439`) wraps them with `None`.
   Widen the warn payload to `(String, Option Loc)` so multi-module warnings keep
   their span too.
3. **Guard warnings** (`checkGuardExhaustiveness : … -> List String`) have no loc
   today (`None` at `:176`/`:441`). To give them a real span, thread the guard
   node's `Loc` out of exhaust — a larger change; acceptable to leave guard
   warnings positionless in Stage 1 (they still get `W-GUARD-INEXHAUSTIVE` + the
   whole-doc fallback), and fix the span in a follow-up.

This changes `check_json` warning output (a golden recapture — see §5) and is the
one place a warning JSON currently diverges from an error JSON.

---

## 5. GOLDEN-CHURN CENSUS (measured on prototype, then reverted)

Method: injected `[PROTOCODE]` into the `ppDiagCliSrc` header **and** added
`("code",…)/("kind",…)` to `cjDiagnostic`, rebuilt `make medaka`, ran the gates in
CHECK mode, counted differing goldens, then `git reset --hard`.

| Option | Renderer touched | Goldens changed | Which corpora |
|---|---|---|---|
| **JSON-only** | `cjDiagnostic` | **9** | `check_json` (9/9; 8 diagnostic-bearing + clean). LSP JSON goldens add a few more. `error_quality`, `native_cli`, `diagnostics` **unchanged**. |
| **CLI-shows-code** | `ppDiagCliSrc` header | **~100** | `error_quality` **35** (measured) + `native_cli/check` **~57** + the 9 JSON. `diff_compiler_diagnostics` stays clean **iff** the code is kept out of `ppDiag` (the loc-free diff form). |

Notes from the measurement:
- **Only type errors with a loc flow through `ppDiagCliSrc`.** Resolve errors
  render via `ppResErrorLocated`/`ppDiag` and did **not** pick up the header
  prefix — so a full CLI-code rollout also touches those renderers, i.e. the ~100
  is a floor if we want codes on *every* CLI line.
- `native_cli` is documented stale-prone (`AGENTS.md`); its 72/106-fail run under
  the prototype conflated real churn with staleness. Treat "~57 check goldens" as
  the recapture estimate, not a correctness signal.

**Recommendation:** **Stage 1 = JSON-only.** It reaches ERROR-QUALITY §5's bar
("add `code` and `kind` to every diagnostic" for the agent audience) at ~9-golden
cost, with zero perturbation to the human-facing CLI corpora. CLI `[CODE]` in the
header (per the §4 exemplars in ERROR-QUALITY) is a **separate opt-in** costing a
one-time ~100-golden recapture; sequence it after Stage 1 if the human-CLI code is
wanted. Keeping the code out of `ppDiag` is a deliberate lever that spares
`diff_compiler_diagnostics` in both options.

---

## 6. Stage 2 — `help` / `fix` scope

Already-computed suggestions that just need structured surfacing:

| Category | Already computed? | Stage-2 surfacing |
|---|---|---|
| **did-you-mean** (misspelled name) | **Yes** — `UnboundVariable String (Option Loc) (Option String)` carries the suggestion (3rd field) and `ppResError` already appends it | `help` = "did you mean `x`?"; **machine `fix`** = the identifier's own range + replacement (the range is the unbound-var loc). *First `fix` to ship.* |
| `/=` → `!=` | **Yes** — hardcoded parser hint | `help` + `fix` = replace `/=` span with `!=`. |
| **missing constraint** | Partially — message already says "add `Eq a =>`" | `help` prose; a machine `fix` needs the signature's insertion point (deferred). |
| **missing case** (non-exhaustive) | **Yes** — exhaustiveness computes the witness ctor(s) internally | `help` = "missing case: `None`"; machine `fix` deferred (insertion point non-trivial). |

Proposed `fix` shape (mirrors the LSP edit + `medaka lint --fix`):
```
data Fix = Fix Loc String            -- replace `Loc`'s span with the String
-- JSON: "fix": { "range": {…}, "replacement": "…" }
```
Add optional `help : Option String` and `fix : Option Fix` to `Diag` (or a
side-table keyed by push). **v1 machine `fix`: did-you-mean + `/=`→`!=` only**
(both are exact, single-span, agent-applicable). Everything else ships `help`
prose in Stage 2 and earns a `fix` later. This also gates whether `medaka check
--fix` becomes a thing (parallel to `medaka lint --fix`) — recommend deferring
that CLI surface until ≥2 `fix` categories exist.

---

## 7. Staged plan

### Stage 1 (codes + kind + warning-range; **size M**)
1. `Diag` gains `Code` (`data Diag = Diag Severity Code String (Option Loc)`);
   add `codeKind : Code -> String` (prefix → `lex/parse/resolve/type/warning`).
2. Resolve: add `resErrorCode : ResError -> Code` (19 arms); pass at the 2
   `ResError→Diag` sites. (0 resolver call-site changes.)
3. Typecheck: add `Code` param to the 3 push funcs + widen `typeErrors` ref;
   author the code at **~55** push sites + 2 match-warning sites
   (`W-NONEXHAUSTIVE`).
4. Parse/lex: derive `P-*`/`L-*` at the `ParseError→Diag` boundary (message
   match); guard warning → `W-GUARD-INEXHAUSTIVE` at its 2 conversion sites.
5. Warning-range fix (§4): renderer arm + multi-module warn-loc threading.
6. Render: add `code`+`kind` to `cjDiagnostic` (**JSON-only**; leave `ppDiag`
   and `ppDiagCliSrc` unchanged for minimal churn).
7. Recapture goldens: `check_json` (+ LSP JSON). Run `selfcompile_fixpoint`
   (C3a/C3b) + `run_gates.sh`.

### Stage 2 (help/fix)
8. `help : Option String` + `fix : Option Fix` on `Diag`; render into JSON.
9. Surface did-you-mean `fix` (from `UnboundVariable`'s 3rd field) + `/=`→`!=`.
10. `help` prose for missing-constraint / missing-case (witness already computed).
11. (Optional) `medaka check --fix`.

### Risk flags
- **No re-mint:** diagnostics/typecheck are self-compiled but **not the emitter**,
  so the checked-in seed is untouched — but the change perturbs compiler IR, so
  **`selfcompile_fixpoint` (C3a/C3b) must be re-validated** and any recaptured
  goldens re-committed. (Per AGENTS.md: fixpoint is the decisive semantics-
  preserving gate here.)
- **~55 authored codes** is the labor centre of Stage 1 — each is mechanical but
  must be reviewed against the §1 table so codes stay accurate (a wrong code is
  worse than none for the agent audience).
- **Multi-module warn-loc threading** widens `checkModulesDiags`'s return type —
  audit every caller (`typecheckPass`, LSP `analyzeProject`) for the shape change.
- **Code stability contract:** once shipped, codes are append-only. Document that
  in this file's header when Stage 1 lands.
