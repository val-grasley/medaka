# Effect-and-Capability Conformance Audit

> **📦 ARCHIVED — historical record (moved 2026-06-22).** This conformance doc is CLOSED; all tracked items are resolved. Any open residual is now tracked in [`PLAN.md`](../PLAN.md). Kept for provenance; not a living roadmap.

> **⚠️ STATUS UPDATE (2026-06-21, `main = 9cc7c9f`): the gaps this audit found have been
> substantially CLOSED.** This document is the original point-in-time findings snapshot
> (`HEAD = bb0bf8d`) — kept as the historical record; it is NOT rewritten. Current state:
> **E1** (capability manifest unrealized — `check-policy` OCaml-only + label-granularity,
> probe P11) → **CLOSED** by WS-1a/1b/1c (`medaka check-policy` native + parameter-level +
> `medaka manifest` TOML). **E2** (only Unit+Prefix domains) → **CLOSED** by WS-3 (`Set`) +
> WS-4 (`Product`/structured Net). **E3** (α over-rejects outer-body lets) → **CLOSED** by
> WS-2 (scope-seeding, both compilers). **E4** (only Net/FileRead/FileWrite parameterized) →
> native machinery DONE (WS-3b); the builtin-extern flip rides the `lib/`-removal soak tail.
> **E5** (extern-row trust boundary) → standing discipline, not closeable. See
> [`EFFECTS-CONFORMANCE-ROADMAP.md`](../EFFECTS-CONFORMANCE-ROADMAP.md) §"Workstream status"
> for the authoritative current state. The probe results below describe the binary *as it
> was at the audit*, not as it is now.

**Status:** audit (findings). **Target spec:**
[`EFFECTS-SEMANTICS.md`](../EFFECTS-SEMANTICS.md) (theory-first, *idealized*, written
without conforming to the implementation). **Audited tree:** `HEAD = bb0bf8d`.
**Canonical binary:** native `./medaka` (built 2026-06-21 12:42), with the OCaml
`lib/*.ml` oracle (`_build/default/bin/main.exe`) used as the differential second
opinion. Every probe below was run on **both** and reported identical unless noted.

## 0. Method

The spec is idealized: it defines the full refinement-domain *family*
(`Unit/Prefix/Set/Product`), the complete abstraction `α` (with let/`if`/`match`
propagation and an interprocedural ceiling), principal-effect inference, and the
capability-manifest semantics — *independently of what shipped*. This audit
measures the current binary against that ideal. Findings are graded:

- **Soundness** — the binary accepts a program the spec forbids (a real hole).
- **Capability** — the spec's headline deliverable (the verified manifest) is
  not realized on the canonical toolchain.
- **Expressiveness** — a spec surface (domain / label) the binary cannot express
  (parse error or atomic-only); sound but inexpressive.
- **Completeness** — the binary *rejects* a program the spec accepts (α over-
  rejection); sound, costs precision only.
- **Assurance** — an inherent trust boundary the type system cannot close.

Each finding was reproduced on the binary first (the §4 probe log). The effects-v2
work landed in stages — `255d186` (Stage 1, atoms over a `RefinementDomain`),
`e7e26f3` (Stage 2a, `Prefix` + parameterized surface), `56e1b13` (Stage 2b, the
`<Net _>` hole + `α`), `4e4e5ce` (Stage 3a, IO decomposition) — so the parameterized
surface the older design docs call "aspirational / parse-error" **is now real**;
this audit re-establishes the line empirically.

## 1. Executive verdict

**The effect *typing core* is sound and substantially conformant; the
capability *deliverable* is not yet on the canonical binary.** The discipline the
spec exists to guarantee is enforced and empirically verified, native == oracle:

- effects are row-typed over **parameterized atoms** with a real refinement domain
  (`Prefix`), not bare labels (§2);
- the **escape** and **no-laundering** checks fire (`EffectEscape`/`EffectLeak`,
  even point-free — §5);
- **no-exfiltration** holds: a literal destination outside a pinned bound is
  rejected, and a *computed* destination widens to `⊤` and is rejected (§4 `α`
  ⊤-fallback) — the security guarantee works on real input;
- **IO decomposition** + the `<IO>` widening alias work, and `IO` correctly
  **excludes** internal `Mut`/`Panic` (§7);
- **effect polymorphism** threads through HOFs (`map` pure callback ⇒ pure; effectful
  callback ⇒ escapes a pure bound) and through effect-poly **data** (`Async e a`) (§6).

The divergences cluster off to the side of the typing core:

| # | Divergence | Spec | Grade | Bites canonical? |
|---|---|---|---|---|
| **E1** | **Capability manifest is unrealized on the canonical binary** — `check-policy` is OCaml-oracle-only and **label-granularity** (ignores parameters); no TOML/Wasm manifest emitter exists | §7 `M`, §9 confinement | **Capability** | **Yes** (headline feature unreachable) |
| **E2** | **Parameter domains = `Unit + Prefix` only** — no `Set`, no `Product`; `<Net {…}>` is a parse error | §2.1 domain family | **Expressiveness** | Yes (deliberate deferral) |
| **E3** | **`α` is seeded empty at the call site + intraprocedural** — outer-body `let`-bound and cross-call literal authority collapse to `⊤` ⇒ over-rejection | §4 `α` precision table | **Completeness** | Yes (sound; costs precision) |
| **E4** | **Only `Net`/`FileRead`/`FileWrite` are parameterized** — `Env`/`Exec`/… are atomic though §3.1 gives them domains | §2.1, §7 | **Expressiveness** | Yes (deferred) |
| **E5** | **Extern catalog rows are trusted; no mechanized subject-reduction** — soundness rests on hand-annotated extern rows + label classes | §8, §9 | **Assurance** | Inherent (FFI boundary) |
| **E6** | **`main`'s manifest is not extracted** — no canonical path turns `M(main)` into an artifact (folds into E1; the *typing* of `main` as grant root is correct) | §7 | **Capability** | Folds into E1 |

**No active soundness hole was found.** Unlike the dictionary audit (where `D1`
was a live soundness gap), the effect *acceptance* discipline matches the spec on
every probe; the gaps are the **unrealized manifest** (E1, the important one) and
**deferred expressiveness** (E2/E4), plus a sound **precision** shortfall (E3).

## 2. Conformance matrix (per spec clause)

| Clause | Verdict | Evidence (canonical unless noted) |
|---|---|---|
| §1 effect on every arrow; schemes quantify effect vars | **CONFORMS** | `TFun of mono * effrow * mono` `typecheck.ml:67`; `Forall of int list * int list * mono` (tyvars **and** effvars) `:92`; selfhost `TFun Mono EffRow Mono` `typecheck.mdk:81` |
| §2.1 domain family `Unit/Prefix/Set/Product` | **PARTIAL (E2)** | only `PUnit \| PPrefix` `typecheck.ml:53-54`; `<Net {..}>` ⇒ parse error (probe P4) |
| §2.1 domain-generic machinery (`RefinementDomain`) | **CONFORMS** | abstraction in place (`dtop_for`/`dsub`/`djoin`); Stage-1 commit `255d186` "atoms over a RefinementDomain"; selfhost `dsubN/djoinN` `typecheck.mdk:208-220` |
| §2.3 `Prefix` + delimiter discipline | **CONFORMS** | `prefix_pattern_ok` `typecheck.ml:529`; probe **P2** rejects bare `<Net "a.com">` with the sibling-host lint |
| §2.4 sub-effecting order `≤` (specific ⊑ general) | **CONFORMS** | `atoms_escape` `typecheck.ml:516` + `dsub`; probe **A2** (`evil.com/x ⋢ a.com/*` ⇒ reject), **P8** (`Stdout ≤ IO` ⇒ accept) |
| §3 `var/app/lam/let/sub` effect flow | **CONFORMS** | `cur_effect` accumulator; union at application; probe **C3** (body unions `<Rand>` ⇒ escape) |
| §3 `prim` mints parameterized atom | **CONFORMS** | hole + `α` at call site (`56e1b13`); probe **A1/A2/A3** |
| §3 principal / least row | **CONFORMS (substantially)** | inference yields tight narrow rows (probe **P7**: `putStrLn`⇒`<Stdout>`, not `<IO>`) |
| §4 `α` soundness (⊤-fallback ⇒ no exfiltration) | **CONFORMS** | `alpha`→`Unknown`→⊤ `typecheck.ml:593-619`; probe **A3** (computed URL ⇒ reject) |
| §4 `α` full precision table (let / interproc) | **PARTIAL (E3)** | arms exist but seeded `alpha [] e` `typecheck.mdk:516`; probe **A4/outer** reject vs **nested** accept |
| §5 binding-boundary escape | **CONFORMS** | `EffectEscape` `typecheck.ml:178,3366`; probe **P9/C1/C3** |
| §5 no-laundering (covariant re-open) | **CONFORMS** | `reopen` `typecheck.ml:974-987`; `EffectLeak` `:179,856-861`; probe **C2b** (point-free effectful ⇒ leak) |
| §5 decidability (no general globs) | **CONFORMS** | trailing-`*` only; `prefix_pattern_ok` rejects others |
| §6 effect-var generalization (HM for effects) | **CONFORMS** | effvars in `Forall`; `free_effvars` `typecheck.ml:908`; probe **C2a/C2b** (`map` effect-poly) |
| §6 value restriction | **CONFORMS** | covariant-only re-open `reopen pos` `typecheck.ml:974` |
| §6 effect-poly data (`TEff`, row kind) | **CONFORMS** | `TEff of effrow` `typecheck.ml:69`; `stdlib/async.mdk` `data Async e a` |
| §6 orthogonality to dictionaries | **CONFORMS** | params ride inert; v2 §6 "label-keyed, param-as-data, never routed" |
| §7 label classes security/internal; `IO` excludes internal | **CONFORMS** | probe **C1** (`<IO>` rejects `<Mut>` body) |
| §7 `IO` widening alias | **CONFORMS** | probe **P8** (`<Stdout>` body under `<IO>` bound ⇒ accept) |
| §7 manifest extraction `M` on canonical | **DIVERGES (E1)** | `medaka check-policy` ⇒ "not yet in native CLI"; OCaml-only `bin/main.ml:413-660` |
| §7 manifest carries **parameters** | **DIVERGES (E1)** | `check-policy` compares **labels** only (`List.mem l policy` `bin/main.ml:591`) — no per-label param check |
| §7 `main` = grant root (no language gate) | **CONFORMS** | probe **P10** (over-broad declared row accepted; no gate) |
| §7 capability confinement (as typing) | **CONFORMS** | probe **A2/A3**; (as a *delivered manifest* ⇒ E1) |
| §8 erasure / single-meaning law | **CONFORMS** | effects erased pre-codegen (STAGE2-DESIGN); `run == build` parity gates |
| §8 trusted externs | **INHERENT (E5)** | extern rows in `stdlib/runtime.mdk` are the trusted base |
| §9 soundness proofs | **TARGETS (not mechanized)** | empirically holds on every probe; no formal proof |

## 3. Divergence ledger

### E1 — Capability manifest unrealized on the canonical binary — **CAPABILITY**

**Spec:** §7 makes the verified effect row a **capability manifest** `M(module) =
filter_security(verified row of the entry point)`, with each security label's
**parameter** rendered (`Net "idp.../*"` → an allowed-outbound-host entry), read by
the host/toolchain to grant or deny at the module boundary. §9 capability
confinement is *delivered* only when that manifest exists and is checked.

**Finding (canonical):** the only manifest-adjacent tool is `medaka check-policy`,
and on the canonical native binary it is **absent**:

```
$ ./medaka check-policy plugin.mdk
medaka: subcommand 'check-policy' not yet in native CLI
```

It exists **only** on the frozen OCaml oracle (`bin/main.ml:413-660`): parse → build
a conservative `EVar` call graph → read the entry fn's inferred row → check
`inferred ⊆ policy` → accept/reject. Two coupled gaps:

1. **Oracle-only.** The headline capability feature runs on the *being-retired*
   differential oracle, not the canonical toolchain (`selfhost/driver/medaka_cli.mdk`
   stubs it). The verified row is *computed* by both binaries but *consumable* only
   by the wrong one.
2. **Label-granularity, not parameter-aware.** Even on the oracle, the policy check
   compares **bare labels** (`bin/main.ml:591`, `not (List.mem l policy)`) — it does
   **not** check a label's *parameter* against an allowed-authority set. So
   `check-policy --allow Net` permits **any** `Net` authority; the entire
   parameterized-effect investment (which host? which path?) does not reach the
   policy decision.
3. **No manifest *emitter*.** There is no path that *emits* `M` as an artifact (the
   research doc's dual-layer TOML `[package.capabilities]` + Wasm custom section).
   `check-policy` is an interactive accept/reject, not a manifest producer.

**Empirical confirmation:** probe **P11** (`./medaka check-policy` ⇒ stub message);
`bin/main.ml:591` reads labels only. The *typing* underneath is correct (probes
A2/A3 confirm the row is verified and parameter-sound) — the gap is purely that the
verified parameters are not extracted, emitted, or policy-checked on the canonical
binary.

**Root cause:** effects-v2 Stage 3 was split; **Stage 3a** (IO decomposition,
`4e4e5ce`) landed, but the **Stage 3 manifest half** (param-aware `check-policy` +
manifest emission + native-CLI port — V2 fork (i)) did not. This is the single
divergence that matters: every other clause is conformant, but the spec's *reason
for existing* is one unshipped stage away.

---

### E2 — Parameter domains limited to `Unit + Prefix` — **EXPRESSIVENESS**

**Spec:** §2.1 defines the domain *family* `Unit / Prefix / Set / Product`, written
against one `RefinementDomain` interface so new domains are "a new instance + a
parser clause — no change to unification, escape, or the manifest extractor."

**Finding:** the implemented `param` type is `PUnit | PPrefix of string option`
(`typecheck.ml:53-54`; selfhost `data Param = PUnit | PPrefix (Option String)`
`typecheck.mdk:108`). `Set` and `Product` are absent. The set-literal surface
`<Net {"a.com","b.com"}>` is a **parse error** (probe **P4**, native and oracle),
so a disjunctive multi-host allow-list — exactly the capability grant the v1 §6a
sketch wanted — is inexpressible; one must over-widen to `Net ⊤` or pick a single
common prefix.

**Assessment:** *deliberate deferral, not a defect.* The Stage-1 abstraction was
explicitly built so `Set`/`Product` add with no rewrite; the v2 fork decisions
ship `Prefix` only. It is a spec gap (the spec is the full family) but a planned
one. Severity is expressiveness: nothing unsound, but the manifest cannot describe
set- or structure-shaped authority.

**Root cause:** v2 forks (a)/(e)/(h) scoped v2 to the `Prefix` domain; `Set`/
`Product` are "later instances."

---

### E3 — `α` seeded empty at the call site; intraprocedural-only — **COMPLETENESS**

**Spec:** §4 gives the idealized abstraction including `let x = e₁ in …x… ⇒
propagate α(e₁)`, `if`/`match` ⇒ join of branch authorities, with an explicit
interprocedural *ceiling*. Soundness rests only on the ⊤-fallback; precision is a
dial.

**Finding:** the `α` propagation arms **exist** in both trees — literal, `++`
leading-prefix, string-interp, `let`-expression, `if`/`match` longest-common-prefix
(`typecheck.ml:593-619`; `typecheck.mdk:352-386`). But `α` is **invoked with an
empty let-context** at the determining-argument position
(`holeFillParam (Some e) = paramOfKp (alpha [] e)` `typecheck.mdk:516`). Consequence:
only `let`s **syntactically nested inside the argument expression** propagate; a
`let` earlier in the *same function body* is looked up in an empty association list
⇒ `Unknown` ⇒ `⊤`. And by decision the analysis is **intraprocedural**, so a
literal threaded through a helper collapses to `⊤` at the call boundary.

**Empirical confirmation (probe pair):**
- `fetch (let d = "a.com/page" in d)` (nested in arg) → **accept** (α walks the
  `ELet`).
- ```
  useIt u =
    let d = "a.com/page"
    fetch d
  ```
  (outer-body `let`) → **reject**: `performs <Net>` (i.e. `α(d) = ⊤`).

Both directions reproduce native == oracle.

**Assessment:** **sound** (`⊤` over-approximates), purely an over-rejection: a
program the spec's α accepts is refused because its authority needlessly widened.
The fix is to *seed* α with the enclosing body's `let`-bindings (closes the
common case cheaply); full interprocedural recovery needs value-singleton typing
(the spec's ceiling, a real escalation).

**Root cause:** the call-site seeds `alpha []`; the propagation machinery is built
but not fed the surrounding scope.

---

### E4 — Only `Net`/`FileRead`/`FileWrite` parameterized — **EXPRESSIVENESS**

**Spec:** §2.1/§3.1/§7 — a label's domain is fixed at its declaration; the spec's
taxonomy gives `Env`, `Exec` (and structurally `Net`'s method axis) domains too.

**Finding:** the builtin domain registry assigns a non-`Unit` domain to exactly
`Net`, `FileRead`, `FileWrite` (`typecheck.mdk:151-153`; OCaml `seed_effect_domains`
`typecheck.ml:360-364`). `Env`/`Exec`/`Stdout`/`Stderr`/`Stdin`/`Clock`/`Rand` are
atomic (`Unit`). So a manifest can confine *which hosts/paths* but not *which env
vars* or *which argv0* — even though those are real host enforcement points.

**Assessment:** deferred (v2 fork (e): "parameterize the three labels with real
host enforcement points; rest atomic, upgradeable"). Adding one is a registry edit
+ a domain choice once `Set`/`Prefix` exist (couples with E2 for `Env`'s natural
`Set` shape).

---

### E5 — Trusted extern rows; soundness not mechanized — **ASSURANCE**

**Spec:** §8 — erasure means the type system is the *only* place authority is
checked, so the externs' declared rows and label classes are part of the **trusted
base**; §9's theorems are stated as targets, not proven.

**Finding:** the effect of every primitive is whatever `stdlib/runtime.mdk` (and the
builtin label-class table) *declares*. A mis-annotated extern (claiming a narrower
row than it performs, or mis-classifying an internal label as security) is a
soundness bug the type system cannot detect — exactly the FFI trust boundary. No
mechanized subject-reduction proof exists; conformance is by an extensive probe
corpus + the differential oracle, not a metatheory.

**Assessment:** **inherent**, not a defect to "fix." Document it as the trusted
surface; mitigations are review + (eventually) host-side enforcement (the host
re-checks at the boundary, so a lying extern is caught by the grantor even if the
type system trusted it). Worth stating so the manifest's guarantee is not
over-claimed: it is "sound *relative to* a faithful extern catalog."

---

### E6 — `main`'s manifest not extracted (folds into E1)

The *typing* of `main` is correct: it is the grant root, takes any row, no language
gate (probe **P10**) — exactly §7. What is missing is the *consumption* side: no
canonical path turns the verified `M(main)` into an emitted/checkable artifact. This
is the same root as E1 (the manifest realization), recorded separately only because
the spec calls out `main` as the manifest's source. Closing E1 closes E6.

## 4. Empirical verification log (canonical `./medaka`, `HEAD = bb0bf8d`)

All probes run native **and** OCaml oracle; identical unless noted.

| Probe | Source shape | Native result | Confirms |
|---|---|---|---|
| **P1** | `effect Net Prefix` + `extern … <Net "a.com/*">` | accept | parameterized surface real (§2, Stage 2a) |
| **P2** | `<Net "a.com">` (no delimiter) | reject — sibling-host lint | §2.3 delimiter discipline |
| **P3** | `<Net _>` hole | accept | §3 `prim` hole (Stage 2b) |
| **P4** | `<Net {"a.com","b.com"}>` set-literal | **parse error** | **E2** (no `Set` domain) |
| **A1** | hole + literal `"a.com/page"` under `<Net "a.com/*">` | accept | §4 α = Known ⊑ bound |
| **A2** | hole + literal `"evil.com/x"` under `<Net "a.com/*">` | reject — `performs <Net "evil.com/x">` | §4/§5 escaping literal |
| **A3** | hole + computed fn-arg `url` under bound | reject — `performs <Net>` (⊤) | §4 **no-exfiltration** ⊤-fallback |
| **A4 / nested** | `fetch (let d = "a.com/page" in d)` | accept | §4 α walks nested `ELet` |
| **A4 / outer** | outer-body `let d = …` then `fetch d` | reject (⊤) | **E3** (empty call-site seed) |
| **B1** | `fetch ("a.com/" ++ sfx)` | accept | §4 α `++` leading-prefix |
| **B2** | `fetch "a.com/\{sfx}"` (interp) | accept | §4 α interpolation prefix |
| **P7** | `greet : … <Stdout>` body `putStrLn` | accept | §7 IO decomposition (`<Stdout>` inferred) |
| **P8** | `<IO>` bound + `<Stdout>` body | accept | §7 `IO` widening alias |
| **P9** | pure bound + `putStrLn` body | reject — `EffectLeak <Stdout>` | §5 escape |
| **C1** | `<IO>` bound + `set_ref` (`<Mut>`) body | reject — `performs <Mut>` | §7 `IO` excludes internal `Mut` |
| **C2a** | `map (x⇒x*2) xs` into pure binding | accept | §6 effect-poly, pure callback |
| **C2b** | `map (s⇒putStrLn s) xs` into pure binding | reject — leak `<Stdout>` | §6 effect-poly, effectful escapes |
| **C3** | declared `<Stdout>`, body unions `randomInt` | reject — `performs <Rand>` | §3 union / §5 escape |
| **P10** | `main : <Stdout, Rand>` (over-broad) | accept | §7 `main` grant root, no gate |
| **P11** | `./medaka check-policy …` | "not yet in native CLI" | **E1** (manifest oracle-only) |

Lockstep: every probe identical native == oracle, corroborating the v2 "both
typecheckers change in lockstep, fixpoint-gated" invariant.

## 5. Out of scope (frozen OCaml oracle)

The oracle is frozen and being retired; its only *effect-relevant* asymmetry is the
**presence** of `check-policy` (the canonical binary lacks it — that asymmetry is
E1's evidence, not a separate oracle defect). The oracle's effect typing is
byte-for-byte in lockstep with the canonical binary on every probe above, so there
is no oracle-vs-native effect divergence to retire. (Contrast the dictionary audit,
where the oracle diverged on superclass evidence and arg-tag dispatch.)

The forward plan to close E1–E4 is in
[`EFFECTS-CONFORMANCE-ROADMAP.md`](../EFFECTS-CONFORMANCE-ROADMAP.md).
