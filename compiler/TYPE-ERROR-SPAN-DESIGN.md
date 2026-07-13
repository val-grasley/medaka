# Type-error span precision — design

**Status:** IMPLEMENTED — Bite 1 `893d9f20` (string-literal span), Bites 2+3 `01f4ee9e`
(whole-binop span, wrong-arg-type argument span), 2026-07-07. All four staged bites this
doc names are verifiably implemented, with in-source comments echoing this doc's own
"Bite N" terminology verbatim. Header below never flipped to SHIPPED despite the fix
landing.

Original header (predates the fix): Status: DESIGN (2026-07-07, read-only scoping over `90d775fd`, reproduced on the
built binary). Playground-filed deferred item. Improves CM6 inline squiggles (the
0.1.0 front door): type errors currently squiggle ~1 char instead of the offending
expression.

## 1. Two independent defects (not one)

Non-string leaf operands (`True`, `1.5`, int literals, method names) ALREADY report
their full atom span — so it is NOT a universal "1-char snapshot." Two separate bugs:

- **Defect A (filed):** `currentLoc` (`typecheck.mdk:2126`, set at the `ELoc` arm
  `:3277`) holds the innermost/last `ELoc` entered. The parser only `ELoc`-wraps
  **atoms/leaves + let/if/match/function/do**, NOT binop/app/unary/postfix levels
  (`parser.mdk:628-634`, deliberate). So inferring a binop runs `infer l` then
  `infer r`, leaving `currentLoc` = the **last operand atom**; then the error fires
  on that. The unification path (`unify`/`typeMismatch` `:2340-2395`) is span-blind —
  it has no `Expr`, only `Mono`, and relies entirely on `currentLoc`.
- **Defect B (NEW, the bigger visual culprit):** string literals collapse to their
  closing quote. `lexer.mdk:610-613` `scanStr` emits `RTok (TString acc) p (p+1)`
  where `p` = the **closing** quote position; the opening-quote start is never
  threaded in → a 1-char loc. (Ints/`True`/`1.5` record their real `(start,end)`,
  which is why only strings collapse.) Triple/multiline strings similarly `(p,p)`.

`pendingBinopSites` (`:1373`) does NOT carry operand spans (tuple is
`(method, Ref Route, Mono, Bool, String)`) — the filed hope that it already threads
spans is **stale**; it would need widening. Where a full operand span IS wanted, the
operand `Expr` is in scope and `exprLoc` (`:4630`) extracts it — the pattern used by
`swapArgFix` (`:4714/:4765`). Downstream (`diagnostics.mdk:cjRangeOfLoc:702`) is a
faithful passthrough — the bad span originates upstream.

## 2. Reproduction matrix (current `check --json`, 0-based)

| Program | Error | range | points at | should be |
|---|---|---|---|---|
| `putStrLn ("a" + 1)` | Num for String | 23-24 | the `1` | `"a"` / whole binop |
| `1 + "x"` | Num for String | 13-14 | closing `"` (Defect B) | `"x"` / binop |
| `putStrLn (f "hello")` (f:Num) | Num for String | 17-18 | callee `f` | arg `"hello"` |
| `x:Int; x="hi"` | Int vs String | 7-8 | closing `"` (B) | `"hi"` |
| `x:Int; x=True` | Int vs Bool | 4-8 | full `True` ✓ | — (already good) |

## 3. Recommended mechanism
Per-error-site loc capture threaded forward (NOT a post-hoc pass — post-HM the type
is known but the offending `Expr` is gone). Three complementary moves:
1. **Fix B first (cheap, isolated, highest visible payoff, no typecheck change):**
   thread the opening-quote offset through `scanStr`/`scanStrEsc` so `TString`
   carries `(startQuote, p+1)`. Fixes every string-operand span project-wide.
2. **Binop operand span:** in `inferBinopE` (`:4183`), after inferring operands and
   before `inferBinop`/`recordNumObligation` (`:4326`), `setRef currentLoc` to the
   synthesized binop span (`exprLoc l` start … `exprLoc r` end). ~3 lines; fixes BOTH
   the Num-obligation and the comparison/Eq/Ord `typeMismatch` binop errors (both
   read `currentLoc`). Operand-precise instead of whole-binop → option (b): pass
   operand locs into `recordNumObligation`.
3. **Wrong-arg-type span:** in `inferApp`/`inferAppExpr` (`:5000+`), the arg `Expr` is
   in scope; capture `exprLoc x` around the `unify ft (TFun xt eff r)` so a wrong-arg
   mismatch squiggles the argument, not the callee. Poly-`Num`-through-a-call needs
   threading the call-site arg loc into `pendingCallObligations` (`:3630/:4553`) — a
   follow-up.

Rejected: ELoc-wrapping binop/app in the parser — `infer` still overwrites
`currentLoc` with the leaf during operand recursion, and it risks changing
resolve/exhaust/desugar/IR (many but not all sites `stripLoc`) → codegen-golden churn.

## 4. Blast radius / re-mint
Display-only for user programs (loc records don't feed codegen) → `llvm_fixtures`,
`eval_fixtures`, `build_diff`, `core_ir_sexp` UNAFFECTED. But `lexer.mdk`/`typecheck.mdk`
are in the self-compile graph → C3a seed byte-identity fails → **`make seed` re-mint
owed** (routine, not special). MUST verify token-stream identity after the lexer fix
(`tokenizeWithOffsetPairs` `map fst` byte-identical to `tokenize` — the fix only
changes the `start` offset field, not the token). Goldens to recapture (small):
`check_json_fixtures/{type_mismatch,sig_mismatch,no_impl}`, `lsp_goldens/{check_err,
check_project}`, `analyze_project_fixtures/basic/oracle.json`, plus any string-literal
range in `positions_fixtures`/`lsp` (Defect B). No live OCaml oracle — pure recapture.

## 5. Staging
- **Bite 1 — Defect B (lexer string offset).** Isolated, highest payoff, no typecheck
  logic. Verify token-stream identity + recapture string-range goldens. **Sonnet.**
- **Bite 2 — binop operand span (`inferBinopE`).** Fixes Num + comparison binop errors
  together. **Opus** (constraint-adjacent; needs fork 1). 
- **Bite 3 — wrong-arg-type span (`inferApp`).** **Opus.**
- **Bite 4 (optional) — poly-Num-through-call + if-branch wording.** **Opus.**

## 6. Design forks
1. **Binop span extent:** whole `"a" + 1` (cheap `exprLoc l..r`, option a) vs just the
   offending operand `"a"` (needs operand-loc threading, option b). REC: whole binop
   for v0.1.0.
2. **Mismatch primary side:** the actual (wrong-typed) operand vs the expected-driving
   site; optional LSP `relatedInformation` secondary span. REC: primary = actual
   operand, optional related = constraint source.
3. **Wrong-arg attribution:** the argument vs the callee/param. REC: the argument.
4. **if-branch mismatch:** else vs then branch as primary. Pick one, be consistent.

Critical files: `compiler/types/typecheck.mdk` (`currentLoc` :2126/:3277,
`inferBinopE` :4183, `recordNumObligation` :4326, `typeMismatch` :2384, `inferApp`
:5000+, `pendingBinopSites` :1373); `compiler/frontend/lexer.mdk` (`scanStr`
:609-613, offset-pair plumbing :1413); `compiler/frontend/parser.mdk` (`located`
:159-173, atom-only wrap :628-634); `compiler/driver/diagnostics.mdk`
(`cjRangeOfLoc` :702).
