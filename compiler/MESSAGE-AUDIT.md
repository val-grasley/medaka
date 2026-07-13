# MESSAGE-AUDIT.md

**Status:** PARTIAL — this is a read-only proposal, not a tracked plan ("proposes copy
only; it changes no source"). Its one concrete recommendation (don't centralize into a
`compiler/messages.mdk`) was followed — no such file exists. Whether the ~65 flagged
tone/consistency issues were individually fixed is unverified; treat this as a
still-actionable punch list, not a closed item.

A read-only audit of **every user-facing message string** Medaka emits through
`medaka check`/`run`/`build`/`fmt`/`lint`/`test`/CLI — graded for **tone**
("LLM-ish" persona, hedging, chattiness) and **cross-corpus consistency**
(punctuation, casing, identifier quoting, hint-joining). Companion to
`ERROR-QUALITY.md` (the copy standard / grading rubric) and
`DIAGNOSTIC-CODES-DESIGN.md` (the `L-/P-/R-/T-/W-/E-*` code taxonomy). This doc
proposes copy only; it changes no source.

Verbatim messages keep their `\{…}` interpolation placeholders. "STATIC" = a
fixed constant; "DYNAMIC" = interpolates a name/type/loc. Flags: **clean** ·
**tone** (persona/hedge/chatty/emoji/marketing) · **inconsistent** (diverges
from the corpus on casing/punctuation/quoting/join).

---

## 1. Summary

**Message-site totals** (distinct user-facing strings, excluding internal-invariant
panics — see Appendix):

| Stage | Count | Flagged |
|---|---:|---:|
| Lex | 6 | 0 |
| Parse | ~42 | 5 |
| Resolve | 22 | 12 |
| Typecheck | ~46 | 17 |
| Exhaust | 1 | 1 |
| Runtime / Eval / native / stdlib | ~24 | 10 |
| CLI / Driver / tools | ~60 | 12 |
| Lint (+ check_policy) | 25 | 8 |
| **Total** | **~226** | **~65** |

**Roughly 29% of user-facing strings carry a tone or consistency flag.** Almost
all flags are *consistency* (casing / trailing-period / identifier-quoting /
hint-join drift) rather than genuine persona. Genuine "LLM tone" is rare — one
first-person message, two emoji lines, one marketing tagline, a handful of
hedges and over-explanations. The corpus is fundamentally in good shape; it
needs a **style pass**, not a rewrite.

### Top ~10 worst offenders (verbatim)

1. **`ambiguousFieldMsg`** (typecheck.mdk:4075) — *first person*, the only true
   persona leak in the compiler:
   `Ambiguous field access: '.\{fname}' is declared by \{owners}. I can't tell which record this value is — add a type annotation on it (e.g. '(r : \{head}).\{fname}').`
2. **check_policy accept/reject** (check_policy.mdk:496,500) — **emoji**:
   `✅ accepted — \{fnName} requires only \{effStr}` / `❌ rejected — …`
   (documented as an OCaml-oracle byte-port, so a fix perturbs a golden.)
3. **CLI tagline** (medaka_cli.mdk:164) — marketing persona:
   `medaka — language for thinking out loud`
4. **`guardWarning`** (exhaust.mdk:519) — hedging + no location/witness, weaker
   than its typecheck sibling: `Warning: guards may not be exhaustive`
5. **generic non-exhaustive fallback** (typecheck.mdk:5209) — hedging:
   `Warning: non-exhaustive match — some values may not be covered`
6. **`doRequiresMonadMsg`** (typecheck.mdk:2419) — over-explanation:
   `` `do` requires a monad (e.g. `Option` or `Result`). For imperative IO sequencing, use a bare indented block instead of `do` (IO is not a monad in Medaka).``
7. **`NonRecursiveValueLet`** (resolve.mdk:1284) — two-sentence over-explanation:
   `'\{n}' is not in scope on the right-hand side of its own binding. Non-function `let` bindings are not recursive — write `let rec \{n} = ...` to opt in to recursion (the RHS must be a lambda).`
8. **`DuplicateBinding`** (resolve.mdk:1285) — lowercase start + two sentences:
   `the clauses of '\{n}' must be contiguous: a same-named top-level binding already appears earlier, separated by an intervening declaration. Move all clauses of '\{n}' (and its type signature) together, or rename one.`
9. **lint "consider" trio** (lint.mdk:777,1056,3530) — hedge verbs that break the
   rule-corpus's dominant imperative `— rewrite as …` form:
   `… — consider a multi-clause function definition` /
   `… — consider `deriving (\{iface})` instead` /
   `… — consider consolidating into a shared module`
10. **native `mdk_oob`** (runtime/medaka_rt.c:193) — the one runtime trap with no
    code, no `runtime error [...]:` prefix, no location, and divergent wording:
    `array index out of bounds` (vs eval's `index \{n} out of bounds` under
    `E-INDEX-OOB`).

Honorable mentions: parser `/=` hint uses a `?`-question + parens where every
other foreign-syntax hint uses `—` (parser.mdk:3769); resolve did-you-mean arms
append a trailing `?` that no other arm uses; the record-field message family
leaves identifiers unquoted while the rest of the corpus quotes them.

---

## 2. Per-stage tables

Only flagged rows carry a suggested rewrite. Rows marked **clean** are listed
compactly (grouped) to keep this scannable.

### 2.1 Lex — `compiler/frontend/lexer.mdk`

| Code | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| L-UNTERMINATED-COMMENT | `unterminated block comment` | lexer.mdk:458 | clean | — |
| L-UNTERMINATED-STRING | `unterminated string literal` | lexer.mdk:610, 615 | clean | — |
| L-BAD-ESCAPE | `invalid escape sequence '\{charToStr e}'` | lexer.mdk:629 | clean | — |
| L-HS-LAMBDA | `unexpected '\' — Medaka lambdas are written 'x => e' (not '\x -> e')` | lexer.mdk:936 | clean | — |
| L-HS-DOLLAR | `Medaka has no '$' — apply directly 'f x', parenthesize '(f x)', or pipe with '\|>'` | lexer.mdk:943 | clean | — |
| L-BAD-CHAR | `unexpected character '\{charToStr c}'` | lexer.mdk:945 | clean | — |

Lex copy is uniformly terse and factual. No changes.

### 2.2 Parse — `compiler/frontend/parser.mdk`

The ~37 `failP "expected …"` messages all funnel to the umbrella `P-PARSE`
code, are STATIC, lowercase, `expected <thing>` form, and are **consistent and
clean** as a family. Flagged rows only:

| Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|
| `unexpected token` | parser.mdk:194 | inconsistent (names neither found nor expected token; the workhorse `expectTok` failure) | thread the tokens: `unexpected \{describeToken x}; expected \{describeToken t}` |
| `expected : or =` | parser.mdk:1959 | inconsistent (siblings at :1223/:2345 append `in let`/`in interface member`; this one bare) | `expected : or = in definition` |
| `\{base} — this line's indentation doesn't line up with the block above (indented to column \{col}); check that it's indented to match the surrounding statements` | parser.mdk:3504 | tone (chatty; "check that…" filler) | `\{base} — indentation (column \{col}) doesn't match the enclosing block` |
| `inline 'let' requires 'in' (e.g. 'else let x = e in body'); for a multi-statement body, put 'else' on its own line and indent the block` | parser.mdk:3557 | inconsistent (lowercase; parens-for-example vs em-dash used by peers) | `inline 'let' requires 'in' — e.g. 'else let x = e in body'; for a multi-statement body put 'else' on its own line and indent` |
| `In Medaka '::' is cons (list prepend); a type signature uses a single colon: 'f : T'` | parser.mdk:3622 | inconsistent (`;`/`:` clause joins + "In Medaka" sentence-case vs the `—` "Medaka has no…" family) | `Medaka spells cons '::' — a type signature uses a single colon: 'f : T'` |
| `unexpected '/=' (did you mean '!=' for not-equal?)` | parser.mdk:3769 | inconsistent (`?`-question + parens; every other foreign hint uses `— …` with no `?`) | `unexpected '/=' — not-equal is spelled '!='` |

Clean foreign-syntax hints (consistent `Medaka has no 'X' — …` form):
`case … of` (:3591), `/* … */` (:3656), `{` brace blocks (:3692), `def`
(:3731), `while` (:3733), `for` (:3735), `;` terminator (:3742), unexpected-EOF
(:179). The ~6 `failP` strings that are pure `orElse`/`choice` backtracking
sentinels (`no alternative` :215, `expected backtick operator` :517,
`numeric head: tight minus stays subtraction` :534, `not a tight negative
literal argument` :549, `expected interpolation open` :855, `expected -` :934)
are internal control-flow, not intended to reach a user — worth *suppressing*
rather than rewording.

### 2.3 Resolve — `compiler/frontend/resolve.mdk` (all in `ppResError`, 1254–1289)

| Code | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| R-UNBOUND | `Unbound variable: \{n} — did you mean '\{sug}'?` | :1256 | inconsistent (trailing `?`; only did-you-mean arms use it) | drop `?`: `… — did you mean '\{sug}'` |
| R-UNBOUND | `Unbound variable: \{n}` | :1258 | clean | — |
| R-UNBOUND | `Unbound variable: \{n} — '\{n}' is exported by '\{m}'; import it with 'import \{m}.{\{n}}'` | :1259 | **clean (the tone exemplar)** | — |
| R-UNKNOWN-CTOR | `Unknown constructor: \{n} — did you mean '\{sug}'?` | :1261 | inconsistent (trailing `?`) | drop `?` |
| R-UNKNOWN-TYPE | `Unknown type: \{n} — did you mean '\{sug}'?` | :1265 | inconsistent (trailing `?`) | drop `?` |
| R-FIELD-NOT-IN-RECORD | `Field \{f} does not belong to record \{r}` | :1270 | inconsistent (unquoted names; prose form vs `Unknown field:` colon form) | `Unknown field: \{f} — record '\{r}' has no field '\{f}'` |
| R-METHOD-NOT-IN-INTERFACE | `Method '\{m}' is not part of interface \{i}` | :1274 | inconsistent (`\{m}` quoted, `\{i}` not) | quote `\{i}` |
| R-EXTERN-WITH-BODY | `extern '\{n}' must not have a definition body` | :1275 | inconsistent (lowercase start) | `Extern '\{n}' must not have a definition body` |
| R-PRIVATE-NAME | `module '\{m}' has no exported name '\{n}'` | :1278 | inconsistent (lowercase start) | `Module '\{m}' has no exported name '\{n}'` |
| R-NO-EXPORTED-CTORS | `'\{n}' exports no constructors from module \{m} (it is exported abstractly); remove the `(..)` or export it with `public export`.` | :1280 | inconsistent (unquoted `\{m}`; trailing period; parens+`;` join) | `'\{n}' exports no constructors from module '\{m}' (exported abstractly) — remove `(..)` or export with `public export`` |
| R-ABSTRACT-FIELD | `'\{t}' is exported abstractly; its field '\{f}' is not accessible (declare it `public export` to expose its fields).` | :1281 | inconsistent (trailing period; parens join) | `'\{t}' is exported abstractly — field '\{f}' is not accessible; declare it `public export` to expose its fields` |
| R-AS-PATTERN-MISPLACED | `` `@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern).`` | :1283 | inconsistent (trailing period) | drop period |
| R-NONREC-VALUE-LET | (see offender #7) | :1284 | tone (over-explanation) + period | `'\{n}' is not in scope in its own binding — non-function `let` is not recursive; write `let rec \{n} = ...` (RHS must be a lambda)` |
| R-DUPLICATE-BINDING | (see offender #8) | :1285 | inconsistent (lowercase) + over-explanation | `Clauses of '\{n}' must be contiguous — an earlier same-named binding is separated by another declaration; group all clauses (and the signature) together, or rename one` |
| R-AMBIGUOUS-OCCURRENCE | `ambiguous occurrence: `\{n}` is exported by \{ambigModPhrase mods} — qualify or select per-name with `import <mod>.{\{n}}` / import only one.` | :1286 | inconsistent (lowercase; trailing period) | `Ambiguous occurrence: '\{n}' is exported by \{…} — qualify, or select with `import <mod>.{\{n}}`` |
| R-INTERNAL-EXTERN | `'\{n}' is an internal-only primitive and cannot be used outside the standard library (pass --allow-internal to override)` | :1287 | inconsistent (no period while parens-peers have one) | `'\{n}' is an internal-only primitive — cannot be used outside the standard library (pass --allow-internal to override)` |

Clean: `Unbound variable: \{n}` (:1258), `Unknown constructor/type/effect/field/
interface/module: \{n}` colon-forms (:1263,1266,1267,1268,1272,1282),
`Duplicate \{k}: \{n}` (:1271), the Haskell-alias note `('\{bad}' is Haskell;
Medaka uses '\{sug}')` (:535).

### 2.4 Typecheck — `compiler/types/typecheck.mdk`

| Code | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| T-AMBIGUOUS-FIELD | `Ambiguous field access: '.\{fname}' is declared by \{owners}. I can't tell which record this value is — add a type annotation on it (e.g. '(r : \{head}).\{fname}').` | :4075 | **tone (first person "I")** | `Ambiguous field access: '.\{fname}' is declared by \{owners}; the record type is undetermined — add a type annotation (e.g. '(r : \{head}).\{fname}')` |
| T-DO-NOT-MONAD | (offender #6) | :2419 | tone (over-explanation) | `` `do` requires a monad (e.g. `Option`/`Result`) — for IO sequencing use a bare indented block, not `do` `` |
| T-UNKNOWN-FIELD | `Field \{fname} does not belong to record \{rname}` | :4061 | inconsistent (unquoted identifiers) | quote: `Field '\{fname}' does not belong to record '\{rname}'` |
| T-MISSING-FIELD | `Missing field \{fname} in construction of record \{rname}` | :4071 | inconsistent (unquoted identifiers) | quote both |
| T-ABSTRACT-FIELD | `'\{tname}' is exported abstractly; its field '\{fname}' is not accessible (declare it `public export` to expose its fields).` | :4067 | inconsistent (trailing period) | drop period; align to resolve R-ABSTRACT-FIELD |
| T-MUT-LET (do-block) | `'let mut \{x}' is not allowed inside a `do` block; do blocks are for monadic composition. Use a bare sequential block instead.` | :1016 | inconsistent (two sentences + period vs sibling `mutLetRequiresBlockMsg`) | `'let mut \{x}' is not allowed inside a `do` block — use a bare sequential block` |
| T-TYPE-MISMATCH (swap) | `arguments to '\{name}' look swapped — try '\{swappedCall}'.` | :4727 | inconsistent (lowercase + period + "look" hedge) | `Arguments to '\{name}' are in the wrong order — try '\{swappedCall}'` |
| T-CONFLICTING-IMPL | `conflicting `impl \{iface}`: defined in \{mid2} and \{mid1}` | :6994 | inconsistent (lowercase; peers say "Overlapping"/"Multiple") | `Conflicting `impl \{iface}` — defined in \{mid2} and \{mid1}` |
| T-MISSING-SUPER-IMPL | `impl \{iface} \{tys} requires a superinterface impl 'impl \{superName} \{tys}', which is missing` | :7177 | inconsistent (lowercase) | capitalize |
| T-CYCLIC-SUPERINTERFACE | `cyclic superinterface: \{joinWith " requires " path}` | :7138 | inconsistent (lowercase) | capitalize |
| T-AMBIGUOUS-INSTANCE | `ambiguous instance for '\{iface} a': cannot determine which impl; annotate the type` | :7771 | inconsistent (lowercase; literal ` a` reads oddly) | `Ambiguous instance for `\{iface}` — cannot determine which impl; add a type annotation` |
| T-EFFECT-PARAM | `Host pattern "\{pat}" must end in '*' …` | :997 | inconsistent (near-dup of :969 `pattern "…"` but capitalized) | share one builder with :969 |
| T-TYPE-MISMATCH (numlit if) | `if branches have different types: Int vs \{args}` | :9024 | inconsistent (lowercase vs generic `Type mismatch:` fallback) | `If branches have different types: Int vs \{args}` |
| T-TYPE-MISMATCH (numlit list) | `list elements have different types: Int vs \{args}` | :9026 | inconsistent (lowercase) | capitalize |
| T-TYPE-MISMATCH (numlit cons) | `cons (::) type mismatch: head is Int but the list holds \{args}` | :9027 | inconsistent (lowercase) | capitalize |
| W-NONEXHAUSTIVE (generic) | `Warning: non-exhaustive match — some values may not be covered` | :5209 | inconsistent + hedge (the witness form :5271 is assertive) | prefer the witness form; fallback `Warning: non-exhaustive match — not all cases are covered` |
| T-NONREC-VALUE-LET (rec) | `'\{name}' is bound by 'let rec' but its right-hand side is not a function. Recursive value bindings must have a lambda right-hand side; cyclic data structures are not supported.` | :5540 | tone (two sentences + period) | trim to one clause |

Clean (representative): `Type mismatch: \{a} vs \{b}` (:2394 etc.),
`Method '\{mname}': expected type \{a} but got \{b}` (:2391),
`Cannot construct infinite type involving \{...}` (:2336),
`No impl of \{iface} for \{args}` + `— add 'deriving \{iface}'…` hint (:8962/8972),
`No impl named '\{name}' found for \{iface} \{args}` (:7780),
`Recursive type alias `\{name}` — …` (:2785),
`Type alias `\{n}` expects \{expected} argument(s), got \{got}` (:2917),
`This expression has type \{tyName}, which is not a function, …` (:4913),
`'\{name}' takes \{takes} argument(s) but is applied to \{applied}.` (:4924),
`Could not deduce '\{iface} \{varName}' … add '\{iface} \{varName} =>' …` (:10351),
the witness non-exhaustive warning (:5271), `W-UNREACHABLE-ARM` (:5233),
`T-PHANTOM-METHOD` (:7071), the numlit hint clauses (:9036–9038).

### 2.5 Exhaust — `compiler/frontend/exhaust.mdk`

| Code | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| W-GUARD-INEXHAUSTIVE | `Warning: guards may not be exhaustive` | exhaust.mdk:519 | tone (hedge "may") + weaker than typecheck's located witness warning | `Warning: guards are not exhaustive — some values are not covered` (and thread a loc when available) |

### 2.6 Runtime / Eval / native / stdlib

House format (the standard): eval `runtimePanic` renders
`\{file}:\{l}:\{c}: runtime error [\{code}]: \{msg}` — located + coded. Flags
below are mostly *cross-backend divergence*, not persona.

| Code | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| E-INDEX-OOB / E-SLICE-OOB / E-DIV-ZERO / E-MOD-ZERO / E-NONEXHAUSTIVE-MATCH / E-NOT-A-FUNCTION / E-PANIC | `index \{n} out of bounds`, `slice [\{lo}..\{hi}] out of bounds`, `division by zero`, `modulo by zero`, `non-exhaustive match`, `applied non-function: \{ppValue}`, user's `panic` arg | eval.mdk:164,1084,1094,1112,1288,1367,1370,703,1687 | clean | — |
| E-LET-REFUTE | `let pattern match failure` | eval.mdk:1244 | inconsistent (siblings :1213/:1226 say `… in block`) | unify to one wording |
| (none) | `non-exhaustive match` (bare `panic`, no code/loc) | eval.mdk:693 | inconsistent | route through `runtimePanic "E-NONEXHAUSTIVE-MATCH"` like :1288 |
| (none) | `program has no 'main' binding` | eval.mdk:2204/2238/2448 | inconsistent (bare `panic`, uncoded/unlocated) | route through the diagnostic channel |
| (none) | `main : Async _ requires `runAsync` in scope — add `import async`` | eval.mdk:2452 | inconsistent (bare `panic`) — copy is otherwise good | give a code + located form |
| E-DIV-ZERO / E-MOD-ZERO / E-NONEXHAUSTIVE-MATCH | `runtime error [E-*]: …` | medaka_rt.c:346,350,361 | inconsistent (coded but **unlocated** — Core IR carries no loc) | known gap; keep coded, add loc when Core IR carries one |
| (none) | `array index out of bounds` | medaka_rt.c:193 (`mdk_oob`) | inconsistent (offender #10 — no code, no prefix, no loc, divergent wording) | `runtime error [E-INDEX-OOB]: index out of bounds` |
| (none) | `Array.set: index out of bounds`, `Array.blit: negative length/srcOff/dstOff`, `… source/destination out of bounds`, `MutArray.set: index out of bounds` | array.mdk:268,290–298; mut_array.mdk:144 | inconsistent (raw `panic`, no code/`runtime error` prefix/loc) | route through the coded OOB path |

**Wasm divergence (flag, no per-row rewrite):** the WasmGC backend lowers every
trap — OOB, div-zero, nonexhaustive, `panic` — to a bare `unreachable` and
**drops the `panic` message argument** (wasm_emit.mdk:4814). On Wasm the user
sees a silent engine trap with **no message at all**. This is the single
largest *behavioral* copy gap (a message that exists on two backends vanishes on
the third).

### 2.7 CLI / Driver / tools

| Context | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| tagline | `medaka — language for thinking out loud` | medaka_cli.mdk:164 | tone (marketing persona) | `medaka — a functional language compiler` (or drop) |
| usage body | each command line ends with `.` | medaka_cli.mdk:165–179 | inconsistent (periods here; flat status lines have none) + `medaka bench` advertised but unimplemented (falls to `notYet`) | drop trailing periods; remove or implement `bench` |
| check/build/run/test/doc/check-policy/manifest usage | `usage: …` | :264,803,829,932,952,983,1032 | inconsistent (lowercase `usage:` vs `Usage:` in fmt/new/top-level) | standardize on one casing |
| wasm-tools missing | `error: wasm-tools not found on PATH — install wasm-tools (…) for --target wasm.` | build_cmd.mdk:225 | inconsistent (trailing period; peer `error:` lines have none) | drop period |
| libgc missing | `error: libgc (bdw-gc) not found — install bdw-gc (…) or set GC_PREFIX/pkg-config.` | build_cmd.mdk:272 | inconsistent (trailing period) | drop period |
| repl :reset | `Session reset.` | repl.mdk:345 | inconsistent (period vs sibling status lines) | `Session reset` |
| repl unknown-cmd / banner | `Unknown command: \{cmd}  (try …)` / `medaka repl  (:quit …)` | repl.mdk:371,377 | inconsistent (double space before paren) | single space |
| new scaffold main.mdk | `main = println "Hello, Medaka!"` | new_cmd.mdk:30 | tone (exclamation — but generated template content, not CLI output) | optional: drop `!` |

Clean (representative): `notYet` (:185), `medaka fmt: …` family, `\{file}: not
formatted` (:642), all `build_cmd.mdk` `error: …` relays (:177,178,181,183,227,
233,286,289), `built \{in} -> \{out}` (:251,287), `medaka new: …` errors,
`Created \{name}/` (:63), the `ppDiagCliSrc` caret renderer and `did you mean
'\{sug}'?` help (diagnostics.mdk:94), the two main-shape warnings (:395,398 —
long but factual/actionable), `IO error` relays that pass the OS `msg` through.

### 2.8 Lint — `compiler/tools/lint.mdk` (+ `check_policy.mdk`)

The rule corpus is structurally consistent (lowercase, em-dash `—` before the
fix, backticked code spans, no trailing period) but its **remediation verb
drifts**: 11 rules use `— rewrite as '…'`; the outliers are flagged.

| Rule | Message (verbatim) | file:line | Flag | Rewrite |
|---|---|---|---|---|
| rule-match-on-param | `function '\{name}' matches on parameter '\{p}' — consider a multi-clause function definition` | :777 | tone (hedge "consider") | `— use a multi-clause function definition` |
| rule-hand-rolled-derivable | `hand-written `impl \{iface}` for '\{tyName}' — consider `deriving (\{iface})` instead` | :1056 | tone (hedge) | `— use `deriving (\{iface})`` |
| rule-duplicate-body | `function '\{occName}' has a body structurally identical to a definition in \{others} — consider consolidating into a shared module` | :3530 | tone (hedge) | `— consolidate into a shared module` |
| rule-stdlib-reimpl | `top-level '\{name}' shadows a stdlib function — prefer the stdlib version` | :1142 | inconsistent (verb "prefer") | `— use the stdlib version` |
| rule-bool-simplify | `redundant boolean expression — simplify to '\{rewritten}'` | :2784 | inconsistent (verb "simplify to") | `— rewrite as '\{rewritten}'` |
| rule-dead-code | `private top-level '\{name}' is unreachable from exports/main/doctests — dead code (remove it)` | :3242 | inconsistent (fix in parenthetical, not em-dash imperative) | `— remove it (dead code)` |
| rule-andthen-pure-map | `monadic bind wraps a pure transformation of its result — rewrite as '\{rewritten}' (functor law: m >>= (pure . f) ≡ fmap f m)` | :2141 | tone (theory parenthetical is chatty) | drop the law; keep it in the rule `descr` |
| rule-match-to-map | `2-arm match maps over an Option/Result — rewrite as '\{rewritten}' (functor map)` | :3059 | tone-minor (trailing "(functor map)") | drop the parenthetical |
| check-policy accept | `✅ accepted — \{fnName} requires only \{effStr}` | check_policy.mdk:496 | tone (emoji) — **but OCaml-oracle byte-port; fixing perturbs a golden** | `accepted — \{fnName} requires only \{effStr}` |
| check-policy reject | `❌ rejected — \{fnName} requires <\{…}> — not permitted by policy {\{…}}` | check_policy.mdk:500 | tone (emoji) — same golden caveat | `rejected — …` |

Clean rules (dominant form): rule-destructure-in-param, rule-missing-signature,
rule-bind-then-destructure, rule-lambda-section, rule-if-max-min,
rule-concat-to-interp, rule-not-eq, rule-rem-parity, rule-double-reverse,
rule-when-unless, rule-complement-predicate, rule-bind-chain-to-do, and the
check-policy trace/no-binding lines.

---

## 3. Consistency findings — rules to standardize on

A single short style addendum to `ERROR-QUALITY.md` would resolve the bulk of
the flags. Proposed rules:

1. **Capitalization.** Diagnostics start with a **Capital**. Offenders (all
   lowercase today, mostly OCaml-oracle-era wording): resolve `extern`/`module`/
   `the clauses`/`ambiguous occurrence`; typecheck `conflicting impl`/`cyclic
   superinterface`/`ambiguous instance`/`missing super impl`/the numlit-context
   `if`/`list`/`cons` messages/`arguments … look swapped`; parser `inline 'let'`.
   *(Lint findings are deliberately lowercase as a family — keep them; the rule
   is for diagnostics.)*
2. **No trailing period.** Terse diagnostics carry none today; the long
   explanatory ones do (resolve R-NO-EXPORTED-CTORS/-ABSTRACT-FIELD/
   -NONREC-VALUE-LET/-DUPLICATE-BINDING/-AS-PATTERN; typecheck T-ABSTRACT-FIELD/
   T-NONREC/swap; two `build_cmd` `error:` lines; `Session reset.`). Drop them
   all — one message, no sentence-terminating period.
3. **Quote identifiers in `'…'`.** The record-field family
   (`unknownFieldMsg`/`missingFieldMsg`, resolve `Field … record …`) leaves
   `\{fname}`/`\{rname}` bare while the rest of the corpus quotes program names.
   Quote them.
4. **One hint-join: em-dash.** The fix/suggestion clause is introduced with
   ` — ` (space-em-dash-space). Retire the competing joins: trailing `?`
   (did-you-mean arms), parenthetical `(…)` (abstract/no-ctors/swap), leading
   `;` (`::` cons hint), and `: ` (lint `swap the arguments: …`). Keep `(…)` only
   for genuinely parenthetical *asides* (e.g. `(pass --allow-internal to
   override)`), never as the primary fix clause.
5. **did-you-mean phrasing.** Standardize on `— did you mean '\{sug}'` (no
   trailing `?`, single-quoted candidate) everywhere (resolve arms, T-UNKNOWN-FIELD
   field suggestion, parser `/=`).
6. **No hedging in definitive diagnostics.** Replace "may not be covered" /
   "guards may not be exhaustive" / "look swapped" / "might" with assertive
   phrasing. The exhaustiveness checker already computes a witness — prefer the
   assertive witness form and demote the hedged fallback.
7. **No persona / over-explanation.** No first person (`I can't tell…` → state
   the fact), no marketing tagline, no emoji, and cap at one clause + one
   `— <fix>`; move rationale/theory into rule `descr`/docs, not the diagnostic
   line.
8. **Runtime traps: one format across backends.** Adopt eval's `runtime error
   [E-*]: <msg>` on native (`mdk_oob` and stdlib `panic`s especially) and stop
   dropping the Wasm `panic` message; align `mdk_oob` wording to eval's
   `index \{n} out of bounds`.
9. **Lint remediation verb.** Standardize on the imperative `— rewrite as
   '\{x}'` (or `— use …` where there's no single rewritten expression). Retire
   `consider`/`prefer`/`simplify to` and the parenthetical-fix form.
10. **CLI: `Usage:` casing + no per-line periods**, and either implement or drop
    the advertised `bench` subcommand.

---

## 4. Centralization assessment

**The design question: move messages to a common `compiler/messages.mdk`?**

### What the corpus actually looks like

- **Static vs dynamic.** The overwhelming majority are **DYNAMIC templates** that
  interpolate values computed *at the emit site*: inferred types (`ppMono a`),
  Maranget witnesses (`renderWitness w`), rewritten expressions
  (`exprToString rewritten`), source locs, module ids. The only substantial
  *static* blocks are the parser `expected …` family and the CLI usage text —
  and those are the ones least in need of centralizing. Concretely: resolve ≈ all
  dynamic; typecheck ≈ all dynamic; lint ≈ all dynamic; parse ≈ all static; CLI
  usage static, CLI errors dynamic relays.
- **Already-factored fraction.** Roughly **half the diagnostic corpus is already
  named constants/helpers**, not inline literals. Resolve is *fully* centralized
  in one chokepoint (`ppResError`, 19 arms) — the model to emulate. Typecheck has
  ~20 named `*Msg` builders (`unknownFieldMsg`, `effectLeakMsg`,
  `missingConstraintMsg`, `doRequiresMonadMsg`, `nonExhaustiveMatchWarning`, …).
  Inline literals dominate only in parser `failP`, lint findings, and CLI.

### Cost / downside of a global `messages.mdk`

- **Refactor size.** Moving *every* string to one file touches **~226 sites** and
  — worse — forces each dynamic template to receive all its interpolation inputs
  as parameters across a module boundary (a message that today reads
  `"Type mismatch: \{ppMono a} vs \{ppMono b}"` inline becomes a call
  `typeMismatchMsg (ppMono a) (ppMono b)` plus a def elsewhere). That's a large,
  mechanical, low-value churn that also perturbs compiler IR → triggers
  `selfcompile_fixpoint` re-validation and golden recapture.
- **Indirection downside is real here.** These messages are *not reused* across
  sites (each is emitted once), so centralizing buys none of the usual dedup
  win — it only *separates the message from the context that explains why it's
  phrased that way* (the `-- note the em-dash` comment at typecheck.mdk:5202 is
  exactly the kind of local rationale that a central file loses). For a
  one-author project, "grep the stage file" already finds every string.
- **What centralizing *would* help** is narrow: enforcing the §3 style rules
  uniformly, and giving translators/tools one table. Neither is a current need.

### Recommendation

**Do not build a global `messages.mdk`. Instead: (a) standardize in place against
a tightened `ERROR-QUALITY.md` §3 style rule, and (b) finish the per-stage
chokepoint pattern that resolve already exemplifies.** Specifically:

- Adopt the §3 rules as a short "Copy style" section in `ERROR-QUALITY.md` and do
  a **single mechanical pass** fixing the ~65 flagged sites. The high-value
  subset — the one first-person message, two emoji lines, tagline, the four
  hedges/over-explanations, and the capitalization batch — is **~30 sites** and
  can land in one commit.
- Where a stage still has inline literals (parser `failP`, lint findings), leave
  them inline but keep them *co-located and greppable*; don't cross a module
  boundary. Typecheck's remaining inline `pushTypeError "…" "literal"` sites can
  optionally be hoisted into a `-- messages` section **within typecheck.mdk**
  (mirroring resolve's `ppResError`) so each stage has one place — a per-file,
  not global, chokepoint. This is the sweet spot: single-place-per-stage without
  cross-module indirection.
- The one genuinely *cross-cutting* item worth a shared helper is the **runtime
  trap format** (eval / native C / stdlib / wasm currently diverge four ways) —
  unify those on one `runtime error [E-*]: <msg>` renderer, but that's a
  backend-parity fix (§2.6), not a message-copy relocation.

Rationale in one line: the strings are dynamic, single-use, and already
half-chokepointed per stage; a global file would cost ~226 edits + a fixpoint
re-mint to *lose* local context and gain nothing but a table nobody queries.

---

## 5. Appendix — excluded internal-invariant panics (confirm not user-facing)

These fire only on a **compiler bug** (type-lost value, unsupported node,
malformed tree) — terse, uncoded, and not part of the copy audit. Listed so the
author can confirm none is user-reachable.

- **eval.mdk (~the bulk of ~265 `panic` sites):**
  - *Primitive type-guard asserts (~90+)* — `expected a String`, `unInt: not an
    Int`, `sqrt: not a Float`, `bitAnd: not Ints`, `charToStr: not a Char`,
    `arrayLength: not an Array`, … (fire only if dispatch hands a primitive the
    wrong runtime rep).
  - *Unsupported-node / unreachable* — `eval: unsupported node (slice 2)` (1044),
    `eval: unsupported block statement` (1209), `index on non-array/list/string`
    (1088), `if condition is not a Bool` (1310), the unop/`&&`/`||`/`::`/`++`
    type asserts (1315–1360).
  - *Structural/dispatch invariants* — `EVarAt: slot/name mismatch …` (488),
    `applied closure with no parameters` (918/929), `no matching impl for
    dispatch` (942), `record update on non-record` (1143), `field access on
    non-record` (1186).
- **typecheck.mdk (8):** `typecheck: unsupported pattern (slice 1)` (3068),
  `typecheck: unsupported expression (slice 1)` (3253), `unbound method: …`
  (3319), `unbound constrained fn: …` (3490), `typecheck: unsupported block
  statement` (3782), `empty record update` (4104), `typecheck: unsupported
  operator …` (4210), `typecheck: unsupported unary op …` (4472).
- **parser.mdk (3):** `parse error` (3348/3373/3376) — hard panics on
  unparseable input, not surfaced as located diagnostics; the `panic msg` at 3392
  re-raises an already-user-facing `TLexError` string.
- **stdlib internal invariants (~15):** `map.mdk`/`set.mdk` balance-tree asserts
  (`Map.rotateL: empty right subtree`, `Set.doubleR: malformed left subtree`, …),
  `async: forceVal on an unfinished computation` (async.mdk:77),
  `from_rep: not implemented …` (core.mdk:1279), the `base64:`/`hex:` internal
  lookups (base64.mdk:32,37; hex.mdk:29,34).
- **runtime/medaka_rt.c (3):** `medaka: pthread_attr_init failed` (1659),
  `medaka: pthread_attr_setstacksize failed` (1664), `medaka: GC_pthread_create
  failed` (1672) — thread bootstrap, not user-program runtime.
- **backend emitter gaps:** `wasm_emit.mdk`/`llvm_emit.mdk` `gap`/`gapL` panics
  (e.g. wasm 4198/4261/4816/7916) — compile-time "emitter can't lower this"
  asserts; never reach a running program.

Two borderline cases worth an explicit author call (currently bare `panic`, but
they *are* reachable by well-formed user programs → arguably should join the
coded `E-*` runtime family, see §2.6): `program has no 'main' binding`
(eval.mdk:2204/2238/2448) and `main : Async _ requires `runAsync` in scope — add
`import async`` (eval.mdk:2452).
