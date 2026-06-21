# Effect-and-Capability Conformance Roadmap

**Status:** roadmap (forward plan). **Target spec:**
[`EFFECTS-SEMANTICS.md`](EFFECTS-SEMANTICS.md). **Findings:**
[`EFFECTS-CONFORMANCE-AUDIT.md`](EFFECTS-CONFORMANCE-AUDIT.md) (`HEAD = bb0bf8d`).

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
