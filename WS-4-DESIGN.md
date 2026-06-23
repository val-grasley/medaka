# WS-4 Design — `Product` refinement domain (structure-aware `Net = Host(Prefix) × Method(Set)`)

**Status:** IMPLEMENTED (verified done 2026-06-22 — `PProduct` arm in `selfhost/types/typecheck.mdk:116`, `encodeProductParam` in `selfhost/frontend/parser.mdk:1699`, `test/effect_product_domain.sh` gate exists). The design-pass recommendation to DEFER was superseded. **Roadmap item:**
[`EFFECTS-CONFORMANCE-ROADMAP.md`](EFFECTS-CONFORMANCE-ROADMAP.md) §WS-4 (E2, "largest, last").
**Spec:** [`EFFECTS-SEMANTICS.md`](EFFECTS-SEMANTICS.md) §2.1 domain interface, §2.3
delimiter discipline, §2.5 row order, domain table (line 145). **Precedent:** WS-3
(`Set`), WS-3b (Env/Exec hole-fill) — both **native-only**.

> **Scope: NATIVE-ONLY.** The frozen OCaml oracle (`lib/typecheck.ml`) has no
> Set/Product domain and is slated for removal (soak tail). This design adds a new
> `RefinementDomain` instance + parser clause + literal syntax to the **canonical**
> selfhost compiler only. It must NOT require any OCaml `lib/` edit, and must keep
> every existing `diff_selfhost_*` gate byte-identical (the abstraction-leak canary).

---

## 0. Grounding (verified against current source, not the roadmap prose)

Read at HEAD; line numbers as observed:

- **`Param` type** (`selfhost/types/typecheck.mdk:108`):
  `data Param = PUnit | PPrefix (Option String) | PSet (Option (List String))`.
  `None` = ⊤ in each parameterized arm. (Spec/roadmap's "tuple of sub-domains" is
  not yet an arm — WS-4 adds it.)
- **Lattice ops are NOT typeclass instances** — they are flat pattern-matched
  functions over `Param`: `dsubN` (:214), `djoinN` (:233), `drenderN` (:266). Each
  has a per-arm-pair clause and a final catch-all (`dsubN _ _ = False`,
  `djoinN p _ = p`, "domain mismatch — never happens"). **There is no `dmeetN`
  today.** So "the RefinementDomain interface" in the spec is realized as a
  convention, not a Medaka `interface`/`impl`. WS-4 extends the same flat functions.
- **`normHole`** (:126) only normalizes `PPrefix (Some "_")` → `PPrefix None`. A
  product hole needs handling here (see §2).
- **Carrier is `Option String`** in the AST: `TyEffect (List (String, Option String))
  (Option String) Ty` (`ast.mdk:33`). WS-3 deliberately did NOT widen it — the
  parser sentinel-encodes a set as the string `"{a,b}"` (`parser.mdk:1624`
  `encodeSetParam`) and `decodeSetParam` (:373) decodes it in `atomOfWritten` (:357).
- **`atomOfWritten`** (:357) is the written-annotation → `Atom` bridge; it branches
  on `dtopFor l` (the label's registered domain). The universal hole `_` is
  special-cased *before* domain dispatch (:363).
- **Domain registry** `effectDomains` (:147) maps label → ⊤-param. Seeded (:150)
  with `Net=PPrefix None`, `FileRead/FileWrite=PPrefix None`, `Env=PSet None`,
  `Exec=PPrefix None`. `domainParam` (:166) maps a `effect L Prefix`/`Set` decl's
  domain string to the ⊤-param; `dtopFor` (:195) reads it back.
- **Hole-fill** (WS-3b): `holeFillParam` (:586) builds the domain-correct param from
  α of the call's first arg — `PSet (Some [s])` for a Set label, `PPrefix (Some s)`
  for Prefix, `dtopFor label` (the domain ⊤) on no-recovery.
- **`checkOneEffectParam`** (:730) validates a written param against the label's
  domain (Prefix ⇒ `prefixPatternOk`; Set ⇒ always ok; atomic ⇒ reject).
- **Escape check** uses `atomsDiff` (:310) → `dsub` per same-label atom; `atomsEscape`
  (:350) widens bound `IO`. **It calls only `dsub` on params** — never `dmeet`.
- **Carrier-string passthrough consumers** (render the `Option String` opaquely, so a
  sentinel survives unchanged): `sexp.mdk:106` `effAtomSexp`, `lsp.mdk:585`
  `renderEffRow`, `doc.mdk:72` `ppTyP`. `resolve.mdk:140` `checkType` reads only
  `map fst labels` (label names) — param string irrelevant.
- **`Param`-shape consumers** (pattern-match on `PPrefix`/`PSet`/`PUnit` arms — these
  are the REAL touchpoints a new arm forces): `check_policy.mdk` (`parsePolicyTok`
  :110, `atomPermitted`/`dsub`, TOML manifest emit `:490`, allow-string emit `:563`),
  and within `typecheck.mdk` the ops above + `atomOfWritten`/`holeFillParam`/`drenderN`.

**Key finding:** the carrier-string consumers (sexp/lsp/doc/resolve) are
sentinel-transparent — they need **zero** change if WS-4 reuses the `Option String`
carrier like WS-3 did. The bounded blast radius is `typecheck.mdk` + `parser.mdk` +
`check_policy.mdk`. This makes the carrier decision (§1) the pivotal one.

---

## 1. `Param` representation for Product

### Recommendation: a `PProduct` arm over **named axes**, carrier kept as `Option String`

```medaka
data Param = PUnit
           | PPrefix (Option String)
           | PSet (Option (List String))
           | PProduct (List (String, Param))   -- NEW: axis name → sub-param
```

- **An axis whose entry is absent (or maps to its sub-domain ⊤) is ⊤ on that axis.**
  Canonical form: a sorted assoc-list keyed by axis name, each value a non-⊤
  sub-param; **all axes ⊤ ⇒ the empty list `PProduct []`**, which IS the product ⊤.
  (Defining product-⊤ as `PProduct []` rather than a separate `None` keeps `djoin`'s
  pointwise recursion uniform and avoids a second ⊤ representation.)
- **⊥ ("disjoint")** is needed only by `⊓`; since the escape check never calls `⊓`
  today (§2), ⊥ does **not** need a runtime representation now. If `dmeetN` is added
  later, model ⊥ as `Option Param` returning `None`, NOT a `PBottom` arm (a `PBottom`
  arm would leak into every other op's catch-all and into the carrier).
- **Sub-domains are the existing arms** (`PPrefix`, `PSet`), reused verbatim — `Host`
  is `PPrefix`, `Method` is `PSet`. The product is heterogeneous-by-axis but each
  axis is an existing domain, so the pointwise ops just recurse into `dsubN`/`djoinN`.

#### Carrier: KEEP `Option String`, sentinel-encode (do NOT widen)

WS-3 proved the pattern: encode the product into the `Option String` carrier as a
structured string the parser builds and `atomOfWritten` decodes. Proposed wire form
(internal, not user syntax — that's §4):

```
"⟨host=a.com/*;method={GET,POST}⟩"      -- angle-sentinel + ';'-separated axes
```

`atomOfWritten` gains a `PProduct`-domain branch (when `dtopFor l = PProduct …`)
that calls a `decodeProductParam` mirroring `decodeSetParam`. **Why keep the carrier:**

- The four sentinel-transparent consumers (sexp/lsp/doc/resolve) stay byte-identical
  — the canary corpus does not move. Widening the carrier touches **all** of them
  plus `ast.mdk`, `eval.mdk`, `core_ir_lower.mdk`, and forces a fixpoint re-mint of
  the AST shape.
- The ripple of widening (named for the record): `ast.mdk` `TyEffect` field type →
  `parser.mdk` `mkEffect`/`effAtomP` → `resolve.mdk` `checkType` → `sexp.mdk`
  `effAtomSexp` → `doc.mdk` `ppTyP` → `lsp.mdk` `renderEffRow`/`leadingEffOf` →
  `core_ir_lower.mdk` (8 `TyEffect` peels) → `eval.mdk` (5 `TyEffect` peels) →
  `typecheck.mdk` (`atomsOfWritten`/`checkEffectParamsTy`/`declaredEffects`/
  `effLabelsOf`). That is a large, fixpoint-gated change for **no expressive gain**
  over sentinel encoding. **Reject widening for WS-4.**

> Honest caveat: the sentinel string accretes — `Set` is `{a,b}`, `Product` is
> `⟨host=…;method={…}⟩`. A *third* nested level would make the encoding/decoding
> fiddly. WS-4 is the natural stopping point for the carrier hack; if a `Scheme×Host×
> Port×Path×Method` 5-axis product or nested products ever arrive, widen the carrier
> THEN (one principled migration), not piecemeal. Document the sentinel grammar in a
> comment block next to `decodeProductParam`.

---

## 2. Lattice ops (pointwise) + ⊥ handling

All three extend the existing flat functions with a `PProduct`/`PProduct` clause
*before* the catch-all. ⊤-on-an-axis = axis absent (or sub-⊤).

### `dsubN` (⊑, pointwise — every axis of `a` is ⊑ the matching axis of `b`)

```
dsubN _ (PProduct []) = True                     -- anything ⊑ product-⊤
dsubN (PProduct ax) (PProduct bx) =
  -- for EACH axis present in b, a's value on that axis ⊑ b's value;
  -- an axis absent in a defaults to its sub-domain ⊤, which is NOT ⊑ a
  -- constrained b-axis  ⇒  must look it up against the axis's domain ⊤.
  allList (\(name, bp) -> dsubN (lookupAxisOrTop name ax bp) bp) bx
```

`lookupAxisOrTop name ax bp` returns `a`'s value for `name`, or the ⊤ of `bp`'s
sub-domain (`prefixOrSetTop bp`) when `a` is silent on that axis. **Subtlety
(get this right):** "a-axis absent" means a is *unconstrained* on that axis = ⊤ on
that axis, which is ⊑ `bp` only when `bp` is itself ⊤. So an `a` silent on `method`
is NOT ⊑ a `b` that constrains `method` — correct (a says "any method", b says
"GET only" → a is broader → not subsumed → escapes). The default-to-sub-⊤ encodes
exactly this.

### `djoinN` (⊔, pointwise, saturating)

```
djoinN (PProduct ax) (PProduct bx) =
  productNorm (map (\name -> (name, djoinN (axisOrTop name ax) (axisOrTop name bx)))
                   (axisUnion ax bx))
```

— for every axis present in *either*, join the two sub-params (missing side = sub-⊤,
which makes the join ⊤ on that axis — correct over-approximation). `productNorm`
drops axes that joined to sub-⊤, re-sorts, and collapses all-⊤ → `PProduct []`. The
component saturation (Prefix→longest-common-prefix-to-⊤, Set→cardinality-cap-to-⊤)
is inherited free from the recursive `djoinN` calls. Lattice height stays bounded
(each axis bounded, axis count fixed by the label's declaration).

### `drenderN` (manifest/error text)

```
drenderN (PProduct []) = ""                       -- product-⊤ ⇒ empty, like other ⊤s
drenderN (PProduct ax) = " " ++ renderProductLit ax
```

`renderProductLit` produces the **chosen user surface** (§4) so error/manifest text
round-trips back through the parser. (Whatever §4 picks, `drenderN` must emit it.)

### `dmeetN` (⊓) — NOT NEEDED NOW

**Finding: ⊓/⊥ is unreachable in the current escape-only use.** The escape check
(`atomsDiff`/`atomsEscape`) and the policy compare (`atomPermitted`) call **only
`dsub` and `djoin`** — never `⊓`. The spec defines `⊓ : … → P ∪ {⊥}` for completeness
of the lattice interface, but no consumer exercises it. **Do not implement `dmeetN`
or any `⊥` representation in WS-4.** If a future consumer needs meet (e.g. a
*policy-intersection* feature in `check-policy`), add `dmeetN : Param -> Param ->
Option Param` returning `None` for the disjoint case — at that point the spec's
`P ∪ {⊥}` maps cleanly to `Option Param` with no new data arm. Note this as a
deliberate omission in the code comment so a reader doesn't think it was forgotten.

### `normHole`

Extend so a product whose recovered-hole axis is unfilled degrades correctly. In
practice the hole marker stays at the `Param` level (`_` is whole-atom, not
per-axis), so `normHole (PProduct …)` is the identity in WS-4 — but add the explicit
clause to keep the function total and document that per-axis holes are out of scope.

---

## 3. Backward compatibility — the key migration question

**Question:** today `Net` is registered `PPrefix None`; `<Net "a.com/*">` parses to
`PPrefix (Some "a.com/*")`; α host-recovery (WS-2/3b) builds `PPrefix (Some host)`;
the policy `--allow Net=a.com/*` builds `PPrefix (Some "a.com/*")`; WS-1c manifest
emits `Net = "a.com/*"`. If `Net` flips to `PProduct`, all of those break unless
handled. The **canary invariant** (roadmap §4 / spec §2.1): the *entire existing
corpus stays byte-identical*; a domain addition must not diff escape/manifest on any
`Unit`/`Prefix`/`Set` program.

### Resolution: `Net` stays Prefix-registered; Product is OPT-IN per program

**Do NOT flip the builtin `Net` registration to `PProduct` in `seedEffectDomains`.**
Doing so would re-interpret every existing `<Net "…">` and break the canary. Instead:

1. **Builtin `Net` remains `PPrefix None`.** Every existing `<Net "a.com/*">`,
   `getEnv`/`runCommand` row, WS-1/2/3 fixture, and policy token is **unchanged,
   byte-identical**. Zero corpus movement. The canary holds trivially.
2. **A program opts into structured Net** via a domain declaration:
   `effect Net Product` (or `effect MyNet Product`). `domainParam` gains a
   `(Some "Product") False => PProduct []` clause; `registerEffectDomain` then
   registers that label as a product domain *for that program*. This mirrors exactly
   how WS-3b parameterizes Env/Exec per-program without touching builtins.
3. **A bare `<Net "a.com/*">` under a `Product`-registered `Net`** must still mean
   "host = a.com/*, method = ⊤". `atomOfWritten`'s `PProduct …` branch, when handed a
   *plain string* (no `⟨…⟩` sentinel), interprets it as **Host-only**:
   `PProduct [("host", PPrefix (Some "a.com/*"))]` (method axis absent = ⊤). This is
   the lift the roadmap §3 anticipates and keeps single-axis annotations ergonomic.
4. **α host-recovery** under a product `Net`: `holeFillParam`'s `PProduct` branch
   builds `PProduct [("host", PPrefix (Some s))]` from the recovered literal (method
   stays ⊤ — α has no method information; sound over-approximation). For builtin
   Prefix `Net` it is unchanged.

### Migration checklist — gates/fixtures that MUST stay green (byte-identical)

| Gate / fixture | Why it stays green |
|---|---|
| `diff_selfhost_typecheck` (12/0), `_error`, `_golden` | builtin `Net`=Prefix untouched; no inferred-row change on existing syntax |
| `diff_selfhost_check_policy` (4/0 + 7/0) | policy compare reaches `dsub`; `PPrefix`-vs-`PPrefix` path unchanged; oracle reads only Prefix |
| `manifest_emit.sh` (6/0) | manifest emits Prefix params via the existing `PPrefix (Some s)` arm; product programs are new fixtures only |
| `effect_set_domain.sh` (5/0), `effect_param_domain.sh` (6/0) | Set/Env/Exec arms untouched |
| `diff_selfhost_parse` (27/0) | `<Net "x">`/`<Net {a,b}>`/`<Net _>` parse paths unchanged; product syntax is a new clause reached only by the new token shape |
| `selfcompile_fixpoint` C3a/C3b | no AST/carrier shape change (sentinel reuse); ops are additive arms |
| no-exfiltration adversarial corpus | product strictly *refines* — adds a method axis; host confinement is at-least as tight |

**Net effect:** WS-4 is purely *additive*. No existing program changes meaning; the
delimiter-lint approximation is *retired only for programs that opt into
`effect Net Product`*. The spec's framing ("Product retires the Prefix approximation")
is achieved by making Product available, not by reinterpreting the default — which is
the only way to satisfy the canary.

> Note: this means the *builtin* `Net` keeps the Prefix delimiter-lint until/unless
> the builtin is re-registered as Product in a future, separately-gated step (with a
> full corpus re-capture). WS-4 ships the *domain*; flipping the *builtin default* is
> a deliberate follow-on, not part of WS-4.

---

## 4. Literal surface syntax — THE design fork (needs a human decision)

Three concrete options for writing a product param. The parser is the hand-written
combinator `effParamFor` (`parser.mdk:1604`), dispatching on the first token after
the label. Existing clauses: `TString` → `<Net "x">`; `TUnderscore` → `<Net _>`;
`TLBrace` → `<Net {…}>` (the WS-3 Set literal). **A product literal must NOT collide
with those.** Record syntax `{ field = v }` and set syntax `{a, b}` both already own
`TLBrace`.

### Option A — keyword-axes, no outer brace: `<Net Host="…" Method={…}>`

```medaka
fetch : String -> <Net Host="idp.example.com/*" Method={"GET","POST"}> String
```

- **Parse:** after the label, peek an **upper-name** axis token (`Host`, `Method`,
  `Scheme`, `Port`). New `effParamFor (TUpperName _)` clause parses
  `sepBy1 (axisName `=` axisLit)` where `axisLit` is `stringLitP` (Prefix axis) or
  the existing brace-set parser (Set axis). Loops until the next token is not an
  upper-name.
- **Collision:** **clean.** No existing `effParamFor` clause starts with an
  upper-name token (string/underscore/brace). Distinct from record (`{`) and set
  (`{`). The only ambiguity is the *closing* `>` of the effect row vs. continued
  axes — resolved by "axis continues only while peek is `UpperName =`".
- **Policy side:** `--allow 'Net Host=idp.example.com/*;Method=GET,POST'` — needs a
  product-aware `parsePolicyTok` branch (semicolon-separated axes). Manifest TOML:
  `Net = { host = "idp.example.com/*", method = ["GET", "POST"] }` (TOML inline
  table — clean, idiomatic).
- **Pro:** reads like the spec (`Host(Prefix) × Method(Set)`); self-documenting axes;
  extends to scheme/port with zero syntax change. **Con:** most parser work (new
  axis-loop); axis keywords (`Host`/`Method`) are context-sensitive identifiers, not
  reserved (acceptable — they're only special right after a product-label).

### Option B — record-style brace: `<Net {host="…", method={…}}>`

```medaka
fetch : String -> <Net {host="idp.example.com/*", method={"GET","POST"}}> String
```

- **Parse:** the `TLBrace` clause must **disambiguate** product-record from Set. Set
  is `{ stringLit, … }`; product-record is `{ lowerName = …, … }`. Peek the token
  after `{`: a `TString` ⇒ Set (existing path); a `TLowerName` ⇒ product. Doable but
  **overloads `TLBrace`** and makes the Set/Product split a lookahead inside one
  clause.
- **Collision:** **risky.** Shares `TLBrace` with both Set literals AND record
  expressions. A future "set of one record"? Already murky. The lookahead is fragile
  (one-token peek decides Set-vs-Product).
- **Policy:** `--allow 'Net={host=…,method=GET|POST}'` — nested braces in a CLI
  string are awkward to quote.
- **Pro:** visually grouped, "looks like a record." **Con:** the `TLBrace` overload
  is exactly the kind of brace-syntax collision the prompt warns about; brittle.

### Option C — positional juxtaposition: `<Net "…" {GET,POST}>`

```medaka
fetch : String -> <Net "idp.example.com/*" {"GET","POST"}> String
```

- **Parse:** after the label, `TString` (host) is the *existing* Prefix clause; a
  product is "Prefix-string **immediately followed by** a brace-set." So `effParamFor
  (TString s)` must peek *again*: if the next token is `TLBrace`, consume it as the
  method axis and build a product; else stay single-axis Prefix (existing behavior).
- **Collision:** **subtle but real.** `<Net "x">` (host only) and `<Net "x" {…}>`
  (host + method) differ only by trailing tokens — the Prefix clause becomes
  *maximal-munch*. Workable, but axes are positional (must memorize "string =
  host, brace = method"), and it does not extend to scheme/port without more
  positional slots (ambiguous past two).
- **Policy:** `--allow 'Net=idp.example.com/* {GET,POST}'` — positional, space inside
  a token, awkward.
- **Pro:** terse; the host-only case is *literally* the existing syntax (great
  backward-compat optics). **Con:** positional axes do not scale; the spec explicitly
  wants scheme/port later (§2.3/§2.5), which Option C cannot name.

### Recommendation: **Option A** (keyword-axes)

- It is the only option that **extends to scheme/port/path** (the spec's stated
  direction) with no further syntax design.
- It has **zero token-collision** with Set/record/string/hole clauses — the cleanest
  parser story in the hand-written combinator.
- Axis names round-trip transparently into the manifest as a TOML **inline table**
  (`Net = { host = …, method = [...] }`), which is the idiomatic capability-manifest
  shape and trivially `drenderN`-able.
- The host-only ergonomic case (`<Net "a.com/*">`) is preserved by §3's "plain
  string = host axis" lift — so Option A does not *force* the keyword form for the
  common single-axis case; it adds it for when you need method.

**Open sub-decision for the human:** axis-keyword **casing/spelling** — `Host`/`Method`
(capitalized, matches spec's `Host(Prefix)`) vs `host`/`method` (lowercase, matches
record-field convention). Recommend **lowercase** (`host`/`method`) for manifest-TOML
consistency (TOML keys are conventionally lowercase) and to avoid colliding with the
upper-name *label* lexical class — but this is a taste call worth surfacing.

---

## 5. Pipeline touchpoints + staging

### Ordered edit list (all native-only; sealed items in **bold**)

1. **`Param`** (`typecheck.mdk:108`) — add `PProduct (List (String, Param))` arm.
2. **registry** — `domainParam` (:166) `+ (Some "Product") False => PProduct []`;
   `dtopFor` (:195) `+ PProduct _ => PProduct []` passthrough. (Builtins in
   `seedEffectDomains` UNCHANGED — §3.)
3. **lattice ops** — `dsubN`/`djoinN`/`drenderN` `PProduct` clauses (§2) + helpers
   (`axisUnion`, `axisOrTop`, `productNorm`, `lookupAxisOrTop`). `normHole` identity
   clause. **No `dmeetN`** (§2).
4. **carrier decode/encode** — `decodeProductParam` (mirror `decodeSetParam` :373) in
   `typecheck.mdk`; `encodeProductParam` in `parser.mdk` (mirror `encodeSetParam`
   :1624). `atomOfWritten` (:357) `PProduct`-domain branch (incl. "plain string =
   host axis" lift, §3).
5. **parser** — `effParamFor` (:1604) new clause for the chosen syntax (Option A:
   `TUpperName`/`TLowerName` axis-loop). Sentinel-encode into `Option String`.
6. **validation** — `checkOneEffectParam` (:730) `PProduct None =>` branch: validate
   each axis against its sub-domain (host axis ⇒ `prefixPatternOk`; method axis ⇒ ok);
   reject unknown axis names.
7. **hole-fill** — `holeFillParam` (:586) `PProduct` branch builds
   `PProduct [("host", PPrefix (Some s))]` from α (§3).
8. **policy/manifest** (`check_policy.mdk`) — `parsePolicyTok` (:110) product branch;
   TOML emit (:490) inline-table; allow-string emit (:563). These reach `dsub` for
   the compare — pointwise subsumption is inherited.
9. **fixtures + gate** — new `test/effect_product_domain.sh`: host+method confinement
   (accept narrow, reject host-sibling, reject method-not-in-set), a failing-before /
   passing-after probe, manifest round-trip. Add product cases ONLY as new fixtures
   (existing corpus untouched, §3).

### What stays SEALED (the abstraction-leak invariant — roadmap §0)

- **`unify_row`** — unification is on labels + tails, never params. Untouched.
- **escape check** (`atomsDiff`/`atomsEscape`/`expandIoInBound`, :310/:350/:343) —
  calls only `dsub`/`djoin` polymorphically over `Param`; the new arm plugs in with
  **no edit** to these functions. (Verified: `atomsDiff` matches `findAtom` on label
  then `dsub` on param — domain-agnostic.)
- **manifest extractor** (`declaredEffects` :1042, `effLabelsOf` :2088) — operate on
  labels / `atomsOfWritten`; the param arm flows through transparently.
- **AST carrier** `TyEffect` (`ast.mdk:33`) + its 4 sentinel-transparent consumers
  (`sexp`/`doc`/`lsp`/`resolve`) — **no edit** (sentinel reuse, §1). This is the
  payoff of not widening the carrier.

**Invariant confirmed:** WS-4 touches `Param`, the flat ops, the registry, the
parser clause, `atomOfWritten`/`holeFillParam`/validation, and `check_policy.mdk`. It
does **not** touch `unify_row`, the escape machinery, the manifest extractor, or the
AST shape. The abstraction holds.

### Staging — split into two landings

- **WS-4a (representation + ops + registry, no surface):** arms 1–4, 6–7 above, but
  drive product params only via the **internal sentinel** + a test that constructs
  them programmatically (or via a temporary minimal `<Net ⟨…⟩>` raw form). Land
  with the full canary suite green + a product-via-sentinel unit fixture. This proves
  the lattice/escape integration in isolation — the riskiest part.
- **WS-4b (surface syntax + policy/manifest):** the chosen Option-A parser clause
  (arm 5), `check_policy.mdk` (arm 8), full fixtures (arm 9). This is where the §4
  human decision lands.

Splitting keeps the fixpoint-gated representation change separable from the
syntax-design change, and lets the human's §4 decision arrive between landings.

---

## 6. Is WS-4 worth it now? — candid recommendation

### Recommendation: **DEFER** (build WS-4a representation only if/when a concrete consumer appears; defer WS-4b surface syntax). **[NOTE 2026-06-22: This recommendation was not followed — WS-4 was implemented. See Status header.]**

**The case for deferring (stronger):**

- **Host-level Net confinement already works** (Prefix domain, WS-1/2/3). The
  security-critical axis — "which hosts can this code reach" — is already soundly
  confined with delimiter discipline. WS-4 adds the **method** axis (GET vs POST),
  which is a *finer* authority distinction with materially lower security payoff:
  host confinement stops exfiltration to `evil.com`; method confinement stops a
  POST when only GET was intended — useful, but second-order.
- **No consumer demands it.** WS-1 (manifest) ships on Prefix. `check-policy` works
  on Prefix. There is no fixture, demo, or host integration that needs method-level
  granularity *today*. Building the largest domain item ahead of a consumer violates
  the roadmap's own "the manifest is the deliverable / build domains generally,
  instantiate narrowly" — instantiate when there's a thing to instantiate *for*.
- **It rides the `lib/`-removal soak tail.** Per the project's current focus (soak
  toward `lib/` removal), the discipline is a *clean bug-free stretch of native-only
  dev*. WS-4 is the largest type-system change on the list; landing it mid-soak adds
  the most surface area for a soak-breaking regression for the least-urgent feature.
  Better soak material is bug-fixing and tooling exercise, not the heaviest new
  domain.
- **The carrier-sentinel debt.** WS-4 pushes the `Option String` sentinel hack to its
  natural limit (nested `⟨host=…;method={…}⟩`). Doing it speculatively banks
  complexity that a future principled carrier-widening would have to unwind.

**The case for building now (weaker, but real):**

- The machinery is *cheap and additive* — WS-3/3b already laid every rail (registry,
  hole-fill, sentinel carrier, flat-op pattern). WS-4 is "more of the same," and the
  abstraction-leak invariant is already proven to hold for new domains. The marginal
  *engineering* cost is moderate, not the "largest" the roadmap implies (the roadmap's
  "largest" reflected an assumed carrier-widen, which §1 shows is avoidable).
- It would *complete* the domain family (Unit/Prefix/Set/Product) and let the spec's
  §2.5 structured-Net story be real rather than aspirational — tidiness value during
  a spec-conformance push.

**Net:** the *cost* is lower than the roadmap assumed (no carrier widen, no
unify/escape/manifest edits, ~3 files), but the *value* is also low (method-axis is
second-order; no consumer needs it; soak prefers stability). Lower cost does not
make a low-value, soak-risky feature worth pulling forward. **Concretely:**

1. **Now:** do nothing on WS-4. Keep this design doc as the decision-ready record.
2. **Trigger to build WS-4a:** the first real consumer of method/structured
   confinement (a host integration, a playground capability demo, or a manifest user
   asking for method scoping). Then land WS-4a (representation) first — it's the
   low-risk, high-confidence half — behind the canary suite.
3. **WS-4b (surface syntax):** only after the §4 human decision, and only once a
   consumer exists to validate the chosen syntax against a real use.

This matches "soundness is free; precision is a dial" — WS-4 is a precision dial with
no one currently turning it. Leave the design banked; spend soak budget on stability.

---

## Appendix — syntax-fork quick reference (for the human decision)

| | A: keyword-axes | B: record-brace | C: positional |
|---|---|---|---|
| Example | `<Net Host="…" Method={…}>` | `<Net {host="…", method={…}}>` | `<Net "…" {…}>` |
| Parser collision | none | overloads `TLBrace` (Set/record) | maximal-munch on `TString` |
| Scales to scheme/port | yes (add axis name) | yes | no (positional ambiguity) |
| Policy/manifest fit | TOML inline table (clean) | nested-brace CLI (awkward) | positional CLI (awkward) |
| Host-only ergonomics | via §3 lift | via §3 lift | literally existing syntax |
| **Verdict** | **recommended** | brittle | terse but non-scaling |

Sub-decision if A: axis keyword casing — `host`/`method` (lowercase, recommended,
TOML-consistent) vs `Host`/`Method` (matches spec prose).
