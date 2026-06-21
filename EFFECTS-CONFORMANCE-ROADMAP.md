# Effect-and-Capability Conformance Roadmap

**Status:** roadmap (forward plan). **Target spec:**
[`EFFECTS-SEMANTICS.md`](EFFECTS-SEMANTICS.md). **Findings:**
[`EFFECTS-CONFORMANCE-AUDIT.md`](EFFECTS-CONFORMANCE-AUDIT.md) (`HEAD = bb0bf8d`).

> **WS-1 — Capability manifest realization: ✅ DONE (2026-06-21, `main = 41509f6`).**
> The headline gap E1/E6 (a verified row nothing consumes on the canonical binary)
> is closed. All three sub-items landed native-canonical, fixpoint-gated (C3a/C3b
> YES), differential-gated, and independently re-verified before merge:
> - **WS-1a** (`f9abda9`) — `medaka check-policy` ported from the OCaml oracle to the
>   native CLI (`selfhost/tools/check_policy.mdk` + `runCheckPolicyCmd`). Bare-label
>   compare, byte-identical to the oracle on the demos. Gate
>   `test/diff_selfhost_check_policy.sh` (4/0).
> - **WS-1b** (`a5b057a`) — parameter-level policy: `--allow 'Net=host/*'` compared
>   via the domain `dsub` (`inferred ⊑ policy`); effect read widened `String → Atom`
>   to carry the param. **Native-only** (the frozen oracle stays bare-label, so the
>   diff gate's bare cases stay byte-identical); 3 native param fixtures.
> - **WS-1c** (`41509f6`) — `medaka manifest <file>` emits the security half of the
>   verified entry row as TOML `[package.capabilities]` (internal `Mut`/`Panic`
>   dropped per §7), round-trips through `check-policy`. Gate `test/manifest_emit.sh`
>   (6/0). **Deferred seam:** the Wasm custom-section half (touches `wasm_emit.mdk`).
>
> **Remaining:** WS-2 (α scope-seeding, cheap/independent), WS-3 (`Set` domain) →
> WS-3b (param Env/Exec) → WS-4 (`Product`/structured Net), WS-5 (standing).

> **WS-2 — α scope-seeding: ✅ DONE (2026-06-21, `98bf22b`).** E3 common case closed.
> α's known-prefix analysis was invoked with an empty `lets` at the hole-fill site, so
> an outer-body `let dest = "<literal>"; fetch dest` collapsed to ⊤ and over-rejected.
> Now the enclosing function body's `let` scope is threaded into α's initial `lets`
> (an `alphaLets`/`alpha_lets` field on the inference env, accumulated in the let-arms,
> read at `fillHolesInRow`). **Landed in BOTH compilers in lockstep** (it changes
> inferred rows on existing syntax). Intraprocedural only — helper-laundered literals
> stay ⊤ by design (spec §5 non-goal). Gates: `diff_selfhost_effect_hole` (incl.
> `reject_outer_computed` soundness guard), `diff_selfhost_typecheck` 12/0, fixpoint
> C3a/C3b YES. A4/outer flips reject→accept; A3/computed stays reject (verified).
>
> **WS-3 — `Set` refinement domain: ✅ DONE (2026-06-21, `5a1d215`, NATIVE-ONLY).** E2
> closed for set-shaped authority. Added a `PSet (Option (List String))` `Param` arm
> (`None`=⊤), its `RefinementDomain` instance (`⊑`=⊆, `⊔`=∪ saturating to ⊤ past a
> cardinality cap of 16, `drender`→`{"a","b"}`), and a parser clause for the `<L
> {"a","b"}>` literal. **Decided native-only** (new syntax; the frozen OCaml oracle is
> slated for removal — extending menhir/lexer for doomed code isn't worth it; mirrors
> the WS-1b native-only precedent). **Abstraction sealed:** `unify_row`, the escape
> check, and the WS-1c manifest extractor were NOT touched — the escape machinery
> rejects set over-reach purely through `dsub`/`djoin`. Carrier kept as `Option String`
> (parser sentinel-encodes the set, `atomOfWritten` decodes) → only 2 source files
> touched (`parser.mdk` + `typecheck.mdk`). Gates: new `test/effect_set_domain.sh` 5/0,
> all canaries byte-identical (parse 27/0, typecheck 12/0, check_policy 4/0+7/0,
> manifest 6/0), fixpoint C3a/C3b YES.
>
> **Remaining:** WS-3b (parameterize Env(Set)/Exec(Prefix) — now unblocked by WS-3),
> WS-4 (`Product`/structured Net — largest), WS-5 (extern-row assurance — standing).
>
> **WS-3b — Env/Exec domain-directed hole-fill: ✅ native machinery DONE (2026-06-21,
> `2188e6a`); shared-runtime extern flip DEFERRED.** Landed (native-only): `Env`=`PSet`
> / `Exec`=`PPrefix` in `seedEffectDomains`; **domain-directed inferred-hole fill** —
> `holeFillParam`/`fillHoleAtom` now build `PSet (Some [s])` for a Set label vs
> `PPrefix (Some s)` for a Prefix label (unrecovered → `dtopFor label`, the domain ⊤);
> `atomOfWritten` special-cases the universal hole `_` before domain dispatch so `<Env
> _>` stays a recognized hole. Exercised via per-program `effect Env Set`/`effect Exec
> Prefix` + local externs. Gate `test/effect_param_domain.sh` 6/0 (Env hole-fill + ∪
> djoin, Exec hole-fill, accept/reject); all canaries byte-identical; fixpoint C3a/C3b
> YES; `unify_row`/escape/manifest untouched.
> **DEFERRED — the `getEnv`/`runCommand` re-annotation in `stdlib/runtime.mdk`** (so the
> *builtin* externs carry `<Env _>`/`<Exec _>`): the FROZEN OCaml oracle registers BOTH
> `Env` AND `Exec` as **atomic** (`PUnit`, `lib/typecheck.ml:333-339`) and reads the
> **embedded** `runtime.mdk` (`lib/stdlib_content.ml`), so the param annotation makes
> the oracle reject runtime.mdk (`label 'Exec' is atomic and takes no parameter`) →
> breaks the oracle-gated `diff_selfhost_check_policy`. The flip lands with **zero
> further native work** once the Set/Prefix-Env/Exec domains reach OCaml `lib/` OR
> `lib/` is removed (soak tail) — the domain-directed fill is already in place and
> fixpoint-proven. (Footgun: editing `runtime.mdk` stale-bakes the oracle until `dune
> build bin/main.exe` regenerates the embed.)

> **Remaining:** WS-4 (`Product`/structured Net — largest), WS-5 (extern-row
> assurance — standing). WS-3b's shared-runtime flip rides the `lib/`-removal soak tail.

> **WS-4 — `Product` refinement domain (structure-aware Net): ✅ DONE (2026-06-21,
> `b948ff3`, NATIVE-ONLY).** E2 closed in full. `Net = Host(Prefix) × Method(Set)`,
> confining host AND method **independently**. Design banked in `WS-4-DESIGN.md`.
> Landed exactly as designed, blast radius 3 files (`typecheck.mdk`, `parser.mdk`,
> `check_policy.mdk`):
> - `PProduct (List (String, Param))` arm over named axes (Product-⊤ = `PProduct []`),
>   carrier kept `Option String` (sentinel-encoded, no AST widen).
> - Pointwise `dsubN`/`djoinN`/`drenderN`. **Soundness-critical axis-defaulting:** a
>   bound axis absent from the inferred param is treated as ⊤-on-that-axis (via the
>   sub-domain ⊤), so a silent inferred axis is NOT ⊑ a constrained bound — proven by
>   `prod_soundness.mdk` (a buggy axis-skipping `dsubN` would accept it). No `dmeet`/⊥
>   (unreachable — escape+policy call only `dsub`/`djoin`).
> - **Opt-in via `effect Net Product`** — builtin `Net` stays `PPrefix None`, so the
>   ENTIRE existing corpus is byte-identical (canary holds); bare `<Net "a/*">` under a
>   product Net lifts to Host-only. The delimiter-lint is retired only for opt-in code.
> - **Literal:** `<Net Host="idp.example.com/*" Method={"GET","POST"}>` (keyword-axes,
>   capitalized). **`check-policy --allow`:** `Net=Host="…";Method={…}` (`;`-separated
>   axes; brace-depth-aware split). **Manifest:** TOML inline table `Net = { host = "…",
>   method = ["GET","POST"] }` (only `drenderN`/`atomToToml` arms added — extractor
>   untouched).
> - Gates: new `test/effect_product_domain.sh` 8/0; all canaries byte-identical
>   (typecheck 12/0, check_policy 4/0+7/0, set 5/0, param 6/0, manifest 6/0, parse 27/0,
>   llvm 181/0); fixpoint C3a/C3b YES. `unify_row`/escape/manifest-extractor/AST sealed.

> ## ✅ Workstream status (2026-06-21) — E1·E2·E3 CLOSED; E4 native-done; E5 standing
>
> The effect-and-capability conformance workstream is **substantially complete**:
> - **E1/E6 (capability manifest)** — ✅ WS-1a/1b/1c (`check-policy` native + parameter-
>   level + `medaka manifest`).
> - **E3 (α precision)** — ✅ WS-2 (scope-seeding, both compilers).
> - **E2 (domain expressiveness)** — ✅ WS-3 (`Set`) + WS-4 (`Product`/structured Net).
> - **E4 (parameterize Env/Exec)** — ✅ native machinery (WS-3b); the **builtin-extern
>   flip in `stdlib/runtime.mdk` is the one deferred item**, blocked on the frozen OCaml
>   oracle (registers Env/Exec atomic + reads embedded runtime) → rides the `lib/`-removal
>   soak tail; lands with zero further native work.
> - **E5 (extern-row assurance)** — a **standing discipline** (the extern catalog is the
>   trusted base), not a closeable code task.
>
> **Open:** only the WS-3b shared-runtime flip (soak-tail) + WS-5 (standing). No further
> domain/precision/manifest work outstanding.

The audit's verdict: the effect **typing core is sound and conformant**; the gaps
are the **unrealized capability manifest** (E1 — the one that matters), **deferred
parameter expressiveness** (E2/E4), a **sound precision shortfall** in `α` (E3), and
an **inherent trust boundary** (E5). This roadmap sequences E1–E4; E5 is a standing
discipline, not a closeable item.

## 0. Principles

- **Target the canonical binary.** Both typecheckers move in lockstep
  (selfhost `types/typecheck.mdk` canonical + OCaml `lib/typecheck.ml` frozen
  oracle), every change fixpoint-gated (`selfcompile_fixpoint`) and differential-
  gated (`diff_selfhost_typecheck`/`_error`/`_golden`). This is the v2 working
  invariant; keep it.
- **The manifest is the deliverable.** The typing exists to produce a verified
  capability manifest a host can enforce. E1 is therefore first priority despite
  the typing being conformant — a sound row nobody can consume is a feature that
  does not ship.
- **Soundness is free; precision is a dial.** `α`'s ⊤-fallback means every
  precision improvement (E3) is *additive* — it only turns current over-rejections
  into acceptances, never the reverse. Land them whenever; they cannot regress
  soundness.
- **Build domains generally, instantiate narrowly** (the Stage-1 ethos, already
  honored). `Set`/`Product` (E2) must add as new `RefinementDomain` instances +
  parser clauses with **zero** change to `unify_row`, the escape check, or the
  manifest extractor. If a domain addition touches those, the abstraction leaked —
  fix the abstraction, not the call sites.
- **Verify on the binary, differentially.** Every change keeps `diff_selfhost_*`
  green and adds a fixture failing-before / passing-after. The frozen oracle is a
  second opinion during the soak (the effect typing is currently byte-identical;
  keep it so until `lib/` is removed).

## 1. Priority and dependency order

```
   E1   ┌───────────────────────────────────────────────────────────┐
   E6   │ WS-1  Capability manifest realization on the canonical CLI │  CAPABILITY — do first
        │   1a  port param-aware check-policy → native medaka         │  (the headline feature)
        │   1b  parameter-level policy check (host/path sets, not    │
        │        bare labels)                                         │
        │   1c  manifest emission (TOML [package.capabilities]        │
        │        + optional Wasm custom section)                      │
        └───────────────────────────────────────────────────────────┘
   E3   WS-2  α scope-seeding (feed the enclosing body's lets)          COMPLETENESS — cheap, independent
   E2   ┌───────────────────────────────────────────────────────────┐
        │ WS-3  Set domain  (PSet instance + `<L {…}>` parser clause) │  EXPRESSIVENESS
        └───────────────────────────┬───────────────────────────────┘
                                    │ unblocks
   E4   WS-3b  parameterize Env (Set) / Exec (Prefix)                    EXPRESSIVENESS
   E2   WS-4  Product domain + structure-aware Net (Host×Method)         EXPRESSIVENESS — largest, last
   E5   WS-5  Extern-row assurance (lint + host re-check)                ASSURANCE — standing discipline
```

**Do-now, independent, low-risk:** WS-1a/1b (Prefix is already param-aware in the
*type system*; only the *consumer* is missing), WS-2. **Sequenced:** WS-3 before
WS-3b/WS-4. **Standing:** WS-5.

## 2. Workstreams

### WS-1 — Capability manifest realization (closes E1, E6) — **highest priority**

The verified, parameter-rich row already exists in the typechecker; nothing
consumes it on the canonical binary. Three sub-items, landable independently but
naturally in order.

**1a — Port `check-policy` to the native CLI.** Today `medaka check-policy` is
OCaml-oracle-only (`bin/main.ml:413-660`); the native CLI stubs it
(`selfhost/driver/medaka_cli.mdk`). Port the call-graph + entry-row read + policy
compare into the canonical toolchain. *Gate:* `./medaka check-policy` on the demos
matches the oracle's accept/reject; differential fixture.

**1b — Parameter-level policy.** The current compare is bare-label
(`List.mem l policy`, `bin/main.ml:591`) — `--allow Net` permits *any* host. Extend
the policy surface and the check to **parameters**: `--allow 'Net=idp.example.com/*'`
and verify `inferred(Net) ⊑ policy(Net)` via the domain `⊑` already implemented
(`dsub`). This is where the parameterized-effect investment finally reaches the
decision. *Gate:* a plugin inferring `<Net "evil.com/*">` is **rejected** under
`--allow 'Net=idp.example.com/*'`; one inferring `<Net "idp.example.com/api/*">` is
**accepted**. (Builds directly on probes A2/A3.)

**1c — Manifest emission.** Add a path that *emits* `M(module)` as an artifact: the
research doc's dual layer — TOML `[package.capabilities]` (human/tooling) +
optional Wasm custom section (host). Filter to **security** labels (drop
`Mut`/`Panic`, §7), render each parameter via `drender`. *Gate:* `medaka build`/a
new `medaka manifest` produces a manifest whose entries equal the inferred security
row; round-trips through `check-policy`.

**Why first:** every other clause is conformant; this is the unshipped half of v2
Stage 3 (fork (i)) and the spec's entire reason to exist. It needs **no** new
type-system work for the `Prefix` case — only the consumer.

### WS-2 — `α` scope-seeding (closes E3 common case) — cheap, independent

`α` is invoked `alpha [] e` at the determining-argument position
(`typecheck.mdk:516`), so only `let`s *nested inside the argument* propagate; an
outer-body `let dest = "a.com/page"` then `fetch dest` collapses to `⊤` and
over-rejects (audit probe A4/outer). Thread the enclosing binding group's
`(name, rhs)` pairs into `α`'s initial `lets` so same-body literal bindings
propagate. *Gate:* the A4/outer fixture flips reject→accept; A3 (computed) stays
reject; fixpoint + diff goldens.

*Non-goal within WS-2:* interprocedural recovery (a literal through a helper) — that
needs value-singleton typing (spec §4 ceiling, §5 non-goal). Scope WS-2 to the
intraprocedural seed; document the helper-boundary `⊤` as intended.

### WS-3 — `Set` domain (closes E2 for set-shaped authority) — **EXPRESSIVENESS**

Add `PSet of string list` as a third `param` arm + a `RefinementDomain` instance
(`⊑ = ⊆`, `⊔ = ∪` saturating to `⊤` past a cardinality cap, `⊓ = ∩`) + a parser
clause for the literal `<L {"a","b"}>` (today a parse error — audit probe P4). By
the abstraction discipline this must **not** touch `unify_row`/escape/manifest. This
realizes the disjunctive allow-list the v1 §6a sketch wanted (`<Net {"a.com/*",
"b.com/*"}>`). *Gate:* P4 flips parse-error→accept; `<L {a,b}>` admits `a` and `b`,
rejects `c`; the abstraction-leak check (diff of the three core paths) stays empty.

**WS-3b — parameterize `Env`/`Exec` (closes E4).** With `Set` available, give `Env`
a `Set` domain (which env vars) and `Exec` a `Prefix` domain (argv0) in the builtin
registry (`typecheck.mdk:151-153`). One registry edit each + re-annotate the
relevant externs. *Gate:* `<Env {"HOME","PATH"}>` confines `getEnv`; `<Exec
"/usr/bin/*">` confines `runCommand`.

### WS-4 — `Product` domain + structure-aware `Net` (closes E2 fully) — last

The largest item: `PProduct` over named axes, with `Net = Host(Prefix) ×
Method(Set)` (and eventually scheme/port), giving structure-aware matching that
retires the `Prefix` delimiter-lint approximation (spec §2.3/§2.5). Pointwise
`⊑/⊔/⊓`. New literal surface for product params. *Gate:* `Net` confines host *and*
method independently; the delimiter footgun is closed structurally, not by lint.

### WS-5 — Extern-row assurance (mitigates E5) — standing discipline

E5 is not closeable in the type system (the extern catalog is the trusted base).
Two mitigations, ongoing:
1. **Extern-row review gate** — a checklist/lint that every `stdlib/runtime.mdk`
   extern's declared row and label class match what the native primitive in
   `eval.ml`/the runtime actually does. (No mechanized link; review-enforced.)
2. **Host re-check is the backstop** — the §7 host, as grantor, re-enforces the
   manifest at the boundary, so a lying extern is caught by the runtime even when
   the type system trusted it. Document the manifest's guarantee as "sound *relative
   to* a faithful extern catalog + an enforcing host."

## 3. Summary table

| WS | Closes | Grade | Size | Depends on | Type-system work? |
|----|--------|-------|------|------------|-------------------|
| **1a** port check-policy → native | E1 | Capability | M | — | no (consumer only) |
| **1b** parameter-level policy | E1 | Capability | M | 1a | no (reuses `dsub`) |
| **1c** manifest emission (TOML/Wasm) | E1, E6 | Capability | M–L | 1b | no |
| **2** α scope-seeding | E3 | Completeness | S | — | small (α seed) |
| **3** `Set` domain | E2 | Expressiveness | M | — | yes (new domain) |
| **3b** parameterize Env/Exec | E4 | Expressiveness | S | 3 | small (registry) |
| **4** `Product` + structured Net | E2 | Expressiveness | L | 3 | yes (new domain) |
| **5** extern-row assurance | E5 (mitigate) | Assurance | ongoing | — | no |

## 4. Verification strategy

- **Differential, both binaries, fixpoint-gated** — unchanged from v2. Type-system
  changes (WS-3/3b/4, WS-2) land in *both* typecheckers in lockstep and must keep
  `selfcompile_fixpoint` and `diff_selfhost_typecheck`/`_error`/`_golden` green.
- **Fixture-per-finding** — each audit probe becomes a regression fixture: the
  reject-cases (A2/A3/C1/C2b/P9) guard soundness; the accept-cases (A1/B1/B2/P7/P8)
  guard precision; the gap-cases (P4, A4/outer, P11) flip on the WS that closes them.
- **Manifest round-trip (WS-1)** — emit `M`, feed it back to `check-policy`, assert
  the module passes its own manifest; assert a tightened manifest rejects.
- **Abstraction-leak canary (WS-3/4)** — adding a domain must not diff
  `unify_row`/escape/manifest behavior on existing (`Unit`/`Prefix`) programs;
  the whole existing corpus stays byte-identical (all atoms unchanged).
- **No-exfiltration adversarial set** — keep a small adversarial corpus (computed
  URL, helper-laundered URL, sibling-host prefix, point-free leak) that must stay
  rejected across every WS.

## 5. Non-goals (deliberate divergences — do **not** "fix")

- **Algebraic-effect handlers / `resume` / delimited continuations** — out
  permanently (spec §0). The host is the handler.
- **Typed-error effects (`Throws E`)** — out. `Result` + uncatchable `panic` are
  canonical; the param representation stays data-shaped, never a type-parameter
  domain.
- **A language-internal upper-bound gate on `main`** — *not* a fix. `main` is the
  grant root (§7); bounding is the host's job. Probe P10 (over-broad `main` accepted)
  is **conformant**, not a defect.
- **Interprocedural / value-singleton α precision** — out of WS-2's scope (and
  likely out of scope entirely until value-level refinement typing is on the table).
  The helper-boundary `⊤` collapse is intended; WS-2 closes only the intraprocedural
  seed.
- **General globs / regex in `Prefix`** — out (decidability of `⊑`). Trailing-`*`
  only; richer structure goes through `Product` (WS-4), not glob syntax.
- **Mechanized soundness proof** — not on this roadmap; the probe corpus + the
  differential oracle are the assurance during the soak. E5 stays a documented trust
  boundary, not a closed item.
