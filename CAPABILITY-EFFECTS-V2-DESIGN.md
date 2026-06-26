# Capability-Effects v2 — design doc (parameterized effects + IO decomposition)

Status: **IMPLEMENTED (2026-06-21, verified done 2026-06-22).** See `EFFECTS-CONFORMANCE-ROADMAP.md`
for the authoritative completion record (WS-1 through WS-4 done; WS-5 standing; WS-3b
shared-runtime flip deferred to `lib/`-removal soak tail). Companion to
[`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) (the v1 atomic-effect feature, shipped),
[`CAPABILITY-EFFECTS-RESEARCH.md`](./CAPABILITY-EFFECTS-RESEARCH.md) (manifest/host research),
and [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) (the runtime that consumes this).

This doc supersedes **§6a of `CAPABILITY-EFFECTS.md`** (the finite-set-lattice sketch of
parameterized effects). The settled v2 shape is **a general refinement-DOMAIN representation**
with the **Prefix domain** as the v2 implementation target; the v1 §6a finite-set lattice
becomes one domain (`Set`) added later with no rewrite.

The design below is **settled** (shaped with the user). This doc grounds it in the current
implementation, works out the mechanics, and surfaces the remaining forks (§7).

---

## 0. LOCKED DECISIONS (2026-06-15 — fork sign-off; supersede §7 leans)

All §7 forks are resolved as follows (authoritative for implementation):

- **Atom cardinality (overrides the §2 ≤1-atom recommendation): a row carries a SET of atoms per label**, deduped by domain `⊑`. `<Net "a.com/*", Net "b.com/*">` is preserved as two atoms — NOT joined to `Net ⊤`. Rationale: joining same-label params loses the disjunctive multi-host/multi-path allow-list, which is the core capability grant. Unification = set-union of atoms then `⊑`-dedup (drop an atom subsumed by another of the same label).
- **(b) Prefix footgun:** patterns must carry a delimiter / trailing-`*`; raw-string prefix only with the boundary explicit in v2. Structure-aware (URL/path) matching deferred to a later `Product` domain.
- **(e) v2 parameterized labels:** `Net`, `FileRead`, `FileWrite` only (the real enforcement points). All other labels atomic in v2; more can be added later with no rewrite.
- **(g) Declaration syntax:** `effect Net Prefix` — space-separated, mirrors data-constructor fields ("the Net effect carries a Prefix"); NOT `effect Net : Prefix` (the `:` misreads as type ascription). Atomic security capability: `effect Log`. Internal/purity class: `internal effect Mut`. Security-capability is the default; `internal` is the explicit opt-out (not manifest-emitted, never granted, never parameterized).
- **Domain representation:** general `RefinementDomain` interface (`dtop/dsub/djoin/dmeet/drender`); implement only the **`Prefix`** domain in v2 (`PPrefix of string option`, ⊤ = `None`). `Set`/`Product` are later instances with no `unify_row`/escape/manifest rewrite. Known-prefix analysis is **intraprocedural** (literal / `lit ++ x` / interpolation / let-propagation; fn-call result ⇒ Unknown ⇒ widen to ⊤).
- **IO decomposition:** narrow leaf labels (Stdout/Stderr/Stdin/FileRead/FileWrite/Env/Exec/Clock/Net), `IO` retained as a **widening union alias** → re-annotate ~21 leaf externs only; zero forced changes to existing `<IO>` annotations.
- **(i) `check-policy`/manifest → native CLI:** port to the canonical native toolchain (the headline feature must run on the canonical binary), in the Stage-3 manifest work.
- **NON-GOAL (firm):** `Throws`/typed-error effects. `Result` is the canonical error representation; `panic` is the sole uncatchable/unrecoverable escape hatch (honors `no-catchable-panics-isolation`). Param representation stays DATA-shaped — no type-parameter domain.

**Both typecheckers (compiler `typecheck.mdk` + OCaml `lib/typecheck.ml`) must change in lockstep; every stage is fixpoint-gated.**

---

## 1. Current-state grounding (probed, not assumed)

### 1.1 The parse/typecheck probe — ground truth

Probed against the built native `./medaka check` (commit `fd81944`,
`MEDAKA_EMITTER=$PWD/medaka_emitter MEDAKA_ROOT=$PWD`):

| Probe | Source | Result |
|---|---|---|
| Bare `effect Cache` + `extern cacheGet : String -> <Cache> String` | P1 | **exit 0 (works)** |
| `extern fetch : … -> <Fetch "idp.example.com"> String` | P2 | **parse error** |
| `verify : String -> <Fetch "idp.example.com"> String` | P3 | **parse error** |
| `effect Fetch (Str)` (domain-declaring form) | P4 | **parse error** |
| `<Fetch _>` (wildcard / ⊤ param) | P5 | **parse error** |
| `<Fetch {"a.com","b.com"}>` (set param) | P6 | **parse error** |
| Bounded `transform : … -> <Log> …` whose body calls `fetch` | LEAK | **exit 1**, `TYPE ERROR: Effectful value used where <Log> is allowed, but it performs <Fetch>` + `Function 'transform' declared with <Log> but also performs <Fetch>` |
| Undeclared label `<Bogus>` | UNK | **exit 1**, `(UnknownEffect "Bogus")` |

**Conclusion — establish the line between real and aspirational:**

- **REAL today:** bare atomic `effect Foo` decls; atomic rows `<Foo>`, `<Foo, Bar>`,
  `<Foo | e>`; cross-module `export effect`; sound transitive propagation; laundering
  rejection (the malicious-plugin pattern is caught by atomic labels *alone* — the bound
  forbids the label, the buried call introduces it, the row check rejects it).
- **ASPIRATIONAL (parse error today):** **every** parameterized form. The
  `<Fetch "idp.example.com">` in `demo/plugin_good.mdk` / `demo/plugin_malicious.mdk` and in
  `CAPABILITY-EFFECTS.md` §6a / `CAPABILITY-PLATFORM.md` §7a is **illustrative only** — it
  does not parse. The demos as committed *declare* `effect Fetch` (atomic) with **no
  parameter and no bound**, so they typecheck clean; the malicious one is caught only when a
  bound annotation excludes `Fetch`, not by any domain check.

So v2's job is to make the parameterized surface real, on a general domain representation.

### 1.2 Effect representation today (both typecheckers, file:line)

**OCaml oracle — `lib/typecheck.ml`:**

- `type effect_set = string list` — sorted, deduped set of **bare-string** labels (line 24).
- `and effrow = { labels : effect_set; tail : effvar option }` (line 44). `tail=None` ⇒ closed
  row `[labels]`; `tail=Some ρ` ⇒ open `<labels | ρ>`.
- `and effvar_info = EUnbound of int * level | ELink of effrow` (lines 45–48) — union-find
  cell, exactly mirroring `tvar`.
- Attached to the arrow: `TFun of mono * effrow * mono` (line 34) — *every* arrow carries a row.
- Row unification: `unify_row r1 r2` (lines 375–399). Pure set logic over strings: `diff a b =
  List.filter (not ∘ mem)`; four tail cases (open/open shares a fresh tail carrying the symmetric
  diffs; open/closed enforces **subset** — `escaping = diff r1.labels r2.labels; if escaping<>[]
  then fail (EffectLeak …)`; closed/closed is a no-op `()`).
- Inference accumulator: `cur_effect : effrow ref` (line 218) — the ambient row of the
  expression under check; lambdas save/reopen it.
- Binding-boundary escape: at a signed binding, `inferred_eff` is gathered via
  `effrow_labels row` (line 2626), and `extras = inferred \ declared` → `fail (EffectEscape …)`
  if non-empty (lines 2691–2692). Errors: `EffectEscape of ident * effect_set * effect_set`
  (line 138), `EffectLeak of effect_set * effect_set` (line 139).
- Annotation → row: `ast_effrow etbl (Ast.TyEffect (es, tl, _))` (lines 324–331) — labels
  sorted/deduped; the named tail var is interned in a per-signature table `etbl` (so two `<… | e>`
  in one signature share the effvar — this is how higher-order `<e>` threads).
- Covariant re-open on instantiation: `instantiate_raw` reopens a closed-with-labels row to
  `<labels | ρ>` **only at covariant positions** (lines 475–514, `reopen pos r` /
  `TFun (a,r,b) -> TFun (walk (not pos) a, reopen pos r, walk pos b)`) — closes closed-closed
  point-free laundering.

**Selfhost canonical — `compiler/types/typecheck.mdk` (byte-identical mirror):**

- `data EffRow = EffRow (List String) (Option (Ref Effvar))` (line 91).
- `data Effvar = EUnbound Int Int | ELink EffRow` (line 92).
- `TFun Mono EffRow Mono` (line 79); `pureRow`/`closedRow`/`openRow` (124–139);
  `effrowNorm` (143–151); `effrowLabels` (154–156); `curEffect : Ref EffRow` (178–179);
  `performEffect` (199–203). Same algorithm, same shape.

**A "label" today = a bare uppercase string.** There is no parameter slot anywhere in the
representation. The parser (`lib/parser.mly`):
- `eff_row: separated_nonempty_list(COMMA, UPPER) [PIPE IDENT] | IDENT` (lines 508–511) — a row
  is uppercase labels + optional lowercase tail.
- `<…> ty`: `LT eff_row GT ty_app { TyEffect (labels, tail, $4) }` (lines 495–496).
- `inner_effect_decl: EFFECT UPPER newlines { DEffect (is_pub, $2) }` (lines 366–368) — bare
  label only; no domain clause.
- AST: `TyEffect of ident list * ident option * ty` (`lib/ast.ml` line 26);
  `DEffect of bool * ident` (line 276).

### 1.3 Current effect vocabulary (probed `stdlib/runtime.mdk`)

The **builtin label vocabulary** is 6: `["IO"; "Mut"; "Async"; "Panic"; "Rand"; "Time"]`
(`lib/resolve.ml` ~94 / `compiler/frontend/resolve.mdk` ~143 — membership = builtins ∪
user-declared; an undeclared label in a row is `UnknownEffect`). Of these, only **4 are actually
carried by stdlib externs** (`Async`/`Time` are reserved, no extern uses them). 79 externs total;
32 annotated, 47 pure:

| Label | # externs | Externs (by category) |
|---|---|---|
| `IO` | 21 | **Stdout**: `putStr putStrLn flushStdout`; **Stderr**: `ePutStr ePutStrLn`; **Stdin**: `readLine readLineOpt readAll readExactly`; **FileRead**: `readFile`; **FileWrite**: `writeFile appendFile`; **FileSystem**: `fileExists listDir makeDir`; **Exec**: `runCommand`; **Env**: `args getEnv`; **Clock**: `wallTimeSec`; **(misc)**: `allocBytes assert_snapshot` |
| `Mut` | 5 | `set_ref arraySetUnsafe arrayBlit arrayFill arraySortInPlaceBy` |
| `Rand` | 5 | `randomInt randomBool randomFloat randomChar setSeed` |
| `Panic` | 1 | `exit` |
| (pure) | 47 | `Ref panic hashInt pi charToStr` … string/char/array kernels, conversions |

No `Net`/`Fetch` extern exists in the stdlib — `Fetch` lives only in the demos. The only
network-shaped primitive is `runCommand` (Exec). So the security-network label **Net** is a
*platform-supplied* extern, not a stdlib one — consistent with "the handler is the host."

### 1.4 String-form lowering (load-bearing for the prefix analysis)

The known-prefix analysis (§2.4) reads **core** string-producing forms; desugar runs first
(AGENTS.md), so by typecheck time:
- literal = `ELit (LString s)` (`lib/ast.ml` line 14, 147);
- concat = `EBinOp "++"` left-folded (`lib/desugar.ml` lines 10–16);
- interpolation `"a\{x}b"` (`EStringInterp [InterpStr|InterpExpr]`, `ast.ml` 120–122, 187)
  lowers via `interp_to_core` to a `++` chain of `ELit (LString …)` and `display e`
  (`desugar.ml` 662, 1010). So the analysis sees only `++`, `ELit LString`, and applications —
  no special interp node. Like `Exhaust.check_match`, the analysis runs **from inside
  typecheck** at each parameterized-primitive call site (it needs the desugared tree).

### 1.5 `check-policy` and the manifest path

`medaka check-policy <file> [--allow L1,L2] [--fn name]` exists in `bin/main.ml` (lines
413–540): parse → build a conservative `EVar` call graph (`collect_evars`) → read the entry
fn's inferred row → check `inferred ⊆ allow` → accept (run on a sample) or reject with the
introducing call chain. **As of WS-1a/1b/1c (2026-06-21) this is FULLY PORTED to the native
CLI** (`compiler/driver/medaka_cli.mdk` + `compiler/tools/check_policy.mdk`) with parameter-level
policy comparison, and `medaka manifest` emits the security row as TOML `[package.capabilities]`.
(Historical note: this section originally recorded it as OCaml-oracle-only; that was closed
by WS-1a/1b/1c.) v2's manifest emission extended this path;
the parameterized atoms are the per-label parameter the manifest carries.

### 1.6 Decided invariants honored by this design

Lazy top-level nullary; **no catchable panics / no try-catch** (panics are the sole
unrecoverable escape); `Result` is the canonical error type; retirement≠removal (both
typecheckers stay in lockstep, fixpoint-gated). v2 introduces **no** control-flow or runtime
mechanism — it is purely a richer row representation + a local static analysis, erased before
codegen.

---

## 2. The parameterized-effect representation

### 2.1 Atoms over a refinement domain

An effect row becomes a **set of parameterized atoms**. An atom is a Label applied to a
**parameter** drawn from that label's declared **refinement DOMAIN**:

```
atom    ::=  Label · param
row     ::=  { atom* }  [ | tail ]          -- ≤ one atom per Label head (same-Label merge by join)
```

A **domain** is a small lattice of *data-shaped* parameters with a top `⊤` (unconstrained):

| Domain | Param values | `⊑` (sub) | join `⊔` | meet `⊓` | v2? |
|---|---|---|---|---|---|
| `Unit` | `()` only | trivial | `()` | `()` | yes (= today's atomic label) |
| `Prefix` | a string prefix pattern, or `⊤` | prefix-containment (§2.3) | longest common prefix, saturating to `⊤` | the more-specific, or ⊥ if disjoint | **v2 target** |
| `Set` | finite set of strings, or `⊤` | `⊆` | `∪` (saturate to `⊤` at a size cap) | `∩` | later (= §6a) |
| `Product` | tuple of sub-domains, e.g. `Net = Prefix × Set` (host-prefix × method-set) | pointwise | pointwise | pointwise | later |

**Key design property — domain-parametricity.** The row machinery (representation,
unification, subsumption, escape) is written **against a domain interface**, not against any
one domain:

```
-- the interface every domain implements
interface RefinementDomain p where
  dtop    : p                 -- ⊤ (unconstrained)
  dsub    : p -> p -> Bool     -- p1 ⊑ p2
  djoin   : p -> p -> p        -- least upper bound (over-approx)
  dmeet   : p -> p -> Option p -- greatest lower bound (None = ⊥ / disjoint)
  drender : p -> String        -- manifest text
```

Adding `Set`/`Product` later is *only* a new instance + a parser clause for its literal
syntax — **no change to `unify_row`, the escape check, or the manifest extractor**. This is the
whole point of doing the representation work up front (the v2 ask's "additive later with no
rewrite").

### 2.2 Concrete representation change (both typecheckers)

`effect_set = string list` becomes a list of atoms, each carrying a label *and* a domain-tagged
parameter. The minimal, fixpoint-safe shape:

```
-- OCaml (lib/typecheck.ml)
type param =
  | PUnit
  | PPrefix of string option        (* None = ⊤; Some p = the prefix pattern *)
  (* PSet / PProduct added later — same variant, new arms *)
type atom        = { label : string; param : param }
type effect_set  = atom list        (* ≤ one atom per label; sorted by label *)
(* effrow / effvar / TFun unchanged in shape *)
```

```
-- compiler (compiler/types/typecheck.mdk) — mirror
data Param = PUnit | PPrefix (Option String)
data Atom  = Atom String Param
-- EffRow (List Atom) (Option (Ref Effvar))
```

The **label's domain** is fixed by its declaration (§4.5), so a row never mixes a label with
the wrong param shape; the typechecker looks up the label's domain from the resolver vocabulary
when it builds/merges an atom. Backward compatibility: a v1 atomic label `Foo` is exactly
`{ label="Foo"; param=PUnit }`; `<Foo>` parses to that. **No existing program changes.**

### 2.3 Unification, subsumption, escape — generalized

The existing four-case `unify_row` keeps its tail logic; the set operations become
**atom-wise + per-domain**:

- **same label, different param ⇒ NOT distinct members.** At most one atom per label head;
  unifying two rows that both mention `Net` **joins** the params (`djoin`). (This differs from
  the v2 prompt's "same label different param = distinct members" phrasing: distinctness holds
  *across* labels; *within* a label the canonical form merges by join — otherwise subsumption is
  ill-defined. Flagged as a settled clarification, not a relitigation.)
- **`diff` / subset** (the open/closed soundness check) generalizes to per-domain `⊑`:
  `r1 ⊑ r2` iff every atom `Net·p₁ ∈ r1` has `Net·p₂ ∈ r2` with `dsub p₁ p₂`. The `EffectLeak`
  fires when r1 has a label absent from r2 **or** present with `not (dsub p₁ p₂)` —
  i.e. `<Net "a.com/foo">` is fine under `<Net "a.com/*">` but `<Net "a.com/*">` is **not**
  fine under `<Net "a.com/foo">` (the ⊤-vs-specific direction the security manifest needs).
- **open/open shared tail** carries the per-label *join* of the symmetric diffs.
- **`EffectLeak` payload** widens to carry the offending atom (`label + p₁ + p₂`) so the
  diagnostic can say "performs `<Net "evil.com">` where only `<Net "a.com/*">` is allowed".
- **covariant re-open** (`instantiate_raw`) is unchanged in structure — it reopens the row
  regardless of params.

Prefix `⊑` (the v2 domain, §3 fork (b) decided): `p₁ ⊑ p₂` iff `p₂ = ⊤`, or `p₂` is a literal
prefix-pattern and `p₁`'s pattern **starts with** `p₂`'s concrete part (trailing-`*` only). So
`Net "a.com/api/v1" ⊑ Net "a.com/api/*" ⊑ Net "a.com/*" ⊑ Net ⊤`.

### 2.4 The known-literal-prefix abstract analysis (Prefix domain)

A parameterized primitive (e.g. platform extern `fetch : Url -> Body -> <Net p> Resp`) emits an
atom whose param is computed by a **local, intraprocedural** abstract analysis of the
URL-argument expression. The abstract value:

```
KP  ::=  Known String      -- a fully-known literal prefix (may be the whole string)
     |   Unknown            -- nothing known ⇒ widen to ⊤
```

Sound abstraction `α` over **every** string-producing core form (default to `Unknown`):

| Core form | `α` rule |
|---|---|
| `ELit (LString s)` | `Known s` |
| `EBinOp "++" a b` | if `α a = Known pa` then `Known pa` (left prefix is fixed regardless of `b`); else `Unknown` |
| `EStringInterp …` (post-desugar = `++` chain) | reduces to the `++` rule: the leading `InterpStr` literal is the known prefix; first `InterpExpr` ⇒ stop |
| `EVar x` where `x` is `let`-bound to `e` in scope | propagate `α e` (intraprocedural let-binding only) |
| `ELet`/`ELetGroup` binding then use | propagate through the binding |
| `EIf (_, t, f)` | `Known (longest-common-prefix (α t) (α f))` if both Known; else `Unknown` |
| `EMatch` over arms | longest-common-prefix of arm results if all Known; else `Unknown` |
| function-call result `EApp …`, parameter `EVar` (a fn arg), field access, anything else | **`Unknown`** |

Lift to a param: `Known s ⇒ PPrefix (Some s)`; `Unknown ⇒ PPrefix None` (= ⊤). Then
`fetch e` emits `<Net (α e)>`.

**Soundness invariant:** the emitted param is always an **over-approximation** of the real
authority — a longer/unknown URL than analyzed only ever widens the param (toward ⊤), never
narrows it. A function-call-derived or runtime URL ⇒ ⊤ ⇒ a plugin pinned to `<Net "idp.../*">`
**cannot** satisfy its bound with a computed URL → rejected. "No exfiltration to an
attacker-chosen destination" is literal-lifting doing its job, not a separate check. **The
analysis is intraprocedural by decision (fork (c))** — a URL threaded through a helper collapses
to ⊤ at the helper boundary; recovering precision needs value-level singleton typing, an
explicit non-goal (§5).

### 2.5 The delimiter footgun (fork (b), decided)

Raw string-prefix matching makes `Net "a.com"` admit `a.com.evil.com` (a prefix!). **v2 decision:
require the pattern to carry a path/host delimiter and match structurally at the v1 boundary** —
the recommended minimum is: a `Prefix` pattern must end at a delimiter (`/` for paths, or the
full host for hosts) or carry an explicit trailing `*`; `Net "a.com/*"` matches `a.com/...` but
not `a.com.evil.com/...`. Full URL/host-structure-aware matching (scheme/host/port/path split) is
the `Product` domain later (§7 fork b). For v2, document the rule and reject a pattern that would
admit a sibling-host prefix (a lint, not silent acceptance).

---

## 3. IO decomposition + migration

### 3.1 Proposed narrow label taxonomy (from the current externs)

Security-capability labels (host-granted, parameterizable, in the manifest):

| Label | Domain | Replaces (current `IO` externs) |
|---|---|---|
| `Stdout` | `Unit` | `putStr putStrLn flushStdout` |
| `Stderr` | `Unit` | `ePutStr ePutStrLn` |
| `Stdin` | `Unit` | `readLine readLineOpt readAll readExactly` |
| `FileRead` | `Prefix` (path) | `readFile fileExists listDir` |
| `FileWrite` | `Prefix` (path) | `writeFile appendFile makeDir` |
| `Env` | `Set`→`Prefix` (var name) | `args getEnv` |
| `Exec` | `Prefix` (argv0) | `runCommand` |
| `Clock` | `Unit` | `wallTimeSec` |
| `Net` | `Prefix` (host/path) | (platform extern — `fetch`; no stdlib extern today) |
| `Rand` | `Unit` | `randomInt randomBool randomFloat randomChar setSeed` (already its own label) |

Internal-only (§4): `Mut`, `Panic` — never decomposed, never parameterized, never in the manifest.

`allocBytes`/`assert_snapshot` are dev/test instrumentation — keep them under a coarse `IO`
(or a dedicated internal `Debug` label) rather than minting a security label for them.

**v2 ships:** `Prefix` domain + the labels whose security value is real and whose param maps to a
host enforcement point — recommend **`Net`, `FileRead`, `FileWrite`** parameterized (`Prefix`);
`Stdout/Stderr/Stdin/Clock/Exec/Env/Rand` as **atomic** (`Unit`) in v2, parameterized later
(fork (e)). This keeps v2's surface small while proving the domain machinery on the labels that
matter (Net domain-pinning, file-path confinement — exactly the §7a/§7b platform proxies).

### 3.2 `IO` as a widening union alias

`IO` stays valid: it is a **union alias** over the security-capability labels. An inferred narrow
row is `⊑ <IO>`; an existing `<IO>` annotation still typechecks (it widens). Mechanically: `IO`
resolves to the join of `{Stdout, Stderr, Stdin, FileRead ⊤, FileWrite ⊤, Env ⊤, Exec ⊤, Clock,
Net ⊤}` (the security labels, each at ⊤). The open/closed subset check then accepts any narrow
row against an `<IO>` bound. `IO` **excludes** the internal labels (`Mut`/`Panic`) — those are
tracked separately and were never part of `IO` semantically.

### 3.3 Migration steps + cost

1. **Define the labels** as builtins with domains (resolver vocabulary + the `IO` alias
   expansion). One edit each in `lib/resolve.ml` builtins + `compiler/.../resolve.mdk`.
2. **Re-annotate the 21 `IO` leaf externs** in `stdlib/runtime.mdk` to their narrow labels
   (table §3.1) — 21 single-line edits. `Mut`/`Rand`/`Panic` externs unchanged.
3. **Let inference propagate upward.** The ~7 stdlib wrappers (`println`/`print` in `core.mdk`;
   `eprint`/`eprintln`/`inspect`/`readLines`/`getEnvOr` in `io.mdk`) carry **explicit `<IO>`
   signatures today** — those stay valid as the widening alias, so **zero forced changes**.
   (Optionally tighten them to narrow rows for a better manifest, but not required.)
4. **`IO` alias** so any other `<IO>` annotation in user code / tests keeps working.

**Estimated cost:** ~21 extern edits + ~2 resolver edits per typechecker; **no existing
annotation must change** (the alias absorbs them). The §6a/`@thorough`/diff-golden suites should
stay byte-identical *except* the few fixtures that print an inferred row (they'd now print the
narrow row) — those goldens re-capture. This is the cheapest possible decomposition because the
boundary annotations are all `<IO>` and `IO` is preserved as the widening alias.

---

## 4. Taxonomy axis (security vs internal)

Every label is classified on one axis; the classification is **declared at the label's
declaration** and stored in the resolver vocabulary:

- **security-capability** — host-granted; the platform supplies the extern that performs it;
  parameterizable (carries a domain); **emitted to the manifest**; read by `check-policy` /
  the host. Examples: `Net, FileRead, FileWrite, Env, Exec, Stdout, Stderr, Stdin, Clock, Rand`,
  and every user `effect Foo` (default security).
- **internal** — purity/discipline tracking only; **never granted, never in the manifest, never
  parameterized** (domain fixed to `Unit`). Examples: `Mut` (mutable state), `Panic` (divergence).

Manifest emission filters the verified row to the security labels: `Mut`/`Panic` are dropped from
the emitted manifest (they are not host capabilities — confirmed by the research doc §3 item 3,
"`Mut` and `Panic` have no WASI counterpart"). The classification is a single field on the
builtin/`effect`-decl record; internal labels reject a domain clause at parse/resolve time.

---

## 5. Explicit non-goals (with rationale)

- **Typed-error effects / `Throws E`** — REJECTED. `Result` is the canonical error type and
  `panic` is the sole uncatchable escape (memory `no-catchable-panics-isolation`). Therefore the
  **param representation is DATA-shaped only — no type-parameter domain.** A domain's params are
  values from a small lattice, never types.
- **General globs / suffix / infix wildcards** — REJECTED in the Prefix domain (breaks
  decidability of `⊑`). **Trailing-`*` only.**
- **Interprocedural prefix tracking** — out. The analysis is intraprocedural; a URL through a
  wrapper collapses to ⊤. (Recovering it needs value-level singleton/refinement typing — a real
  escalation, out of scope.)
- **Runtime value-capabilities (handles / ocap tokens)** — out. v2 is ambient-tracking +
  host-as-grantor, not capability-passing. (The hybrid attenuation story stays a future open
  question, as in v1 §8.)
- **Algebraic-effect handlers / resumptions** — out, permanently, as in v1 §4.
- **Runtime cost** — none. Params are erased with the rest of the row before codegen; only the
  *verified* params reach the compile-time manifest.

---

## 6. Staged implementation plan

Each stage touches **both typecheckers** (compiler canonical + OCaml frozen oracle — must stay
byte-identical) and is **fixpoint-gated** (`selfcompile_fixpoint`) and differential-gated
(`diff_compiler_typecheck` / `_error` / `_golden` and `eval_dict`). The representation work
(domain abstraction + taxonomy axis) is done up front; the domain *content* is narrow.

**Stage 1 — row repr = parameterized atoms + domain abstraction (no new surface yet).**
- `effect_set : string list → atom list`; add `param` + the `RefinementDomain` interface with
  only `Unit` instantiated. Rewrite `diff`/`mem`/subset in `unify_row` to atom-wise + per-domain
  (with `Unit` everything reduces to today's behavior). Widen `EffectLeak`/`EffectEscape`
  payloads to carry atoms. Mirror in `compiler`.
- **Gate:** every existing program is unchanged (all atoms are `PUnit`); goldens byte-identical;
  fixpoint holds. This is the riskiest stage (touches the delicate core unify path) but has the
  cleanest oracle: *no behavior change*.

**Stage 2 — Prefix domain + known-prefix analysis + parameterized surface syntax.**
- Add the `PPrefix` param + `Prefix` `RefinementDomain` instance (`⊑` = delimiter-aware prefix
  containment, §2.3/§2.5).
- Parser: extend `eff_row` to `Label [param]` where `param ::= STRING | UNDERSCORE`
  (`<Net "a.com/*">`, `<Net _>`); extend `inner_effect_decl` to `EFFECT UPPER [domain-clause]`
  (§4.5 fork g). Mind the existing zero-conflict property — a bare `UPPER` stays the `Unit` case.
- The known-prefix analysis (§2.4) runs from typecheck at each parameterized-primitive call site
  (like `Exhaust.check_match`), over the **desugared** tree.
- Mirror in `compiler`. **Gate:** new accept/reject fixtures (`<Net "a/*">` admits `"a/x"`,
  rejects computed-URL and sibling-host); the demos' `<Fetch "...">` now actually parse + check;
  fixpoint + diff goldens.

**Stage 3 — IO decomposition labels + `IO`-as-alias + extern re-annotation + manifest.**
- Mint the narrow labels with domains + classification axis (§3.1, §4); `IO` widening alias (§3.2).
- Re-annotate the 21 leaf externs (§3.3); inference propagates; existing `<IO>` annotations widen.
- Extend `check-policy` + manifest emission to carry per-label params (`Net "idp.../*"` →
  `allowed_outbound_hosts`), and port `check-policy` to the native CLI (done WS-1a/1b/1c —
  see §1.5 update). Filter internal labels out of the manifest (§4).
- **Gate:** re-capture the few inferred-row goldens; `check-policy` accept/reject on the demos
  with parameterized bounds; fixpoint.

**Cross-cutting note (the v1 §6a hazard):** parameterized atoms thread through HM inference +
typeclass method signatures + dict-passing — the part v1 §6a flagged as "most likely to bite."
Keep atoms label-keyed and param-as-data so the dict machinery (which keys on label/method names)
is unaffected; params ride along as inert data on the row, joined at unification, never routed.

---

## 7. Forks table (for sign-off)

| # | Fork | Options | Recommendation |
|---|---|---|---|
| **a** | Prefix-only vs richer globs | (1) trailing-`*` prefix only; (2) general glob/regex | **(1) prefix-only** — preserves decidable `⊑`; globs break the lattice. |
| **b** | Raw-string-prefix vs delimiter/structure-aware (the `a.com` ⊃ `a.com.evil.com` footgun) | (1) raw prefix; (2) require a delimiter in the pattern for v2, full URL/host-structure (`Product`) later; (3) full structure-aware now | **(2)** — require delimiter/trailing-`*` in v2 (lint-reject sibling-host prefixes); structure-aware via `Product` domain later. |
| **c** | Prefix-analysis locality | (1) intraprocedural-only; (2) interprocedural | **(1) intraprocedural** — sound (collapses to ⊤ across calls); interproc needs value singletons (non-goal). |
| **d** | Pattern-vs-literal surface + escaping a literal `*` | (1) `"…*"` trailing-`*` = wildcard, `"\*"` = literal star; (2) separate pattern syntax `<Net p"a/*">` | **(1)** — overload string literal; trailing `*` is the wildcard, `\*` escapes to a literal star (rare; document it). |
| **e** | v2 narrow-label taxonomy + which are parameterized | (1) parameterize only `Net/FileRead/FileWrite`, rest atomic; (2) parameterize all; (3) `Net` only | **(1)** — parameterize the three labels with real host enforcement points (§7a/§7b proxies); rest atomic in v2, upgradeable. |
| **f** | `IO`-alias membership + whether `IO` stays user-writable | (1) `IO` = union of all security labels (excl. internal), stays user-writable; (2) deprecate `IO` as sugar | **(1)** — keep `IO` writable as the widening alias (zero-migration); revisit deprecation post-v2. |
| **g** | How a label declares its domain + security/internal class | (1) `effect Net : Prefix` (domain after `:`), security default, `internal effect Mut` keyword for internal; (2) attribute syntax `effect Net @prefix`; (3) infer domain from first use | **(1)** — `effect Net : Prefix` reads naturally, slots into the existing decl grammar; `internal effect Foo` marks internal; default = security/`Unit`. |
| **h** | (surfaced) Same-label-different-param semantics | (1) merge by join (≤1 atom/label); (2) distinct members | **(1) merge by join** — required for a well-defined `⊑`; the v2 prompt's "distinct members" holds *across* labels only. |
| **i** | (surfaced) `check-policy`/manifest port to native CLI | (1) port in Stage 3 (it's OCaml-only today); (2) keep OCaml-only through soak | **(1) DONE (WS-1a/1b/1c, 2026-06-21)** — `check-policy` + parameter-level policy + `medaka manifest` all native. |

---

## 8. Summary (historical design summary — fully implemented 2026-06-21)

v2 made the parameterized-effect surface (which was entirely parse-error and illustrative-only
before v2) **real**, on a **general refinement-domain representation** that first implemented
`Prefix` (WS-2/WS-3), then added `Set` (WS-3, `<L {…}>` literals), `Product` (WS-4,
`<Net Host=… Method=…>`), and `Env`/`Exec` domains (WS-3b). It decomposes the coarse `IO` into
narrow security labels while keeping `<IO>` valid as a widening alias (zero-migration), and splits
all labels on a security/internal axis that drives the manifest. The mechanics extend the existing
sound, laundering-closed row system (`unify_row`, covariant re-open, binding-boundary escape) from
bare-string sets to per-domain atom sets — the same algorithm, generalized — and add a sound,
intraprocedural known-prefix analysis whose ⊤-fallback *is* the no-exfiltration guarantee. No new
runtime machinery; erased before codegen as today.
