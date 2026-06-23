# Capability-effects research findings

Research pass for the Phase 146 capability-effects near-term sequence (item #1 from
PLAN.md). Date: June 2026. This note is the input to the design note + manifest
format step (item #2).

---

## What Medaka has today

Medaka has a sound, fully-inferred effect-row system with laundering-closed
soundness (open/closed rows + closed-closed point-free via covariant-only
instantiation re-opening). Effect rows are **erased before codegen**; the manifest is
compile-time metadata only, zero runtime cost. User/platform-definable effect labels
(`effect Foo`, `export effect Foo`) and cross-module export (`exp_effects` across
the loader boundary) are implemented. A working demo (`demo/plugin_good.mdk`,
`demo/plugin_malicious.mdk`, `medaka check-policy`) rejects a malicious plugin
that buries a `fetch` call four helpers deep — transitively propagated effect row
`{Fetch, Cache, Log} ⊄ {Cache, Log}` with the call chain printed. **Manifest
emission is also done** (2026-06-21): `medaka manifest` extracts the verified
security-row of an entry point and writes it as TOML `[package.capabilities]`
(WS-1c per `EFFECTS-CONFORMANCE-ROADMAP.md`); `medaka check-policy` supports
parameter-level policy (`--allow 'Net=host/*'`). The WasmGC backend (needed for
real edge deployment) is downstream and not yet started; the LLVM backend can
produce native binaries for development/demo purposes.

---

## 1. WASI Preview 2 / Wasm Component Model

### Capability model

WASI is explicitly capability-based: modules hold no ambient authority. All resource
access (files, network, clocks, RNG) must come through handles (capabilities) the
host explicitly grants at instantiation time. This is the textbook ocap model
applied at the Wasm module boundary.

**Worlds** are the key abstraction: a WIT `world` is a named set of imports
(capabilities the component requires) and exports (interfaces it provides). A
component targeting a world declares exactly what it needs; the host satisfies those
imports — or refuses to instantiate. No import → no access. Example:

```wit
// greeter.wit
package example:greeter@1.0.0;
world greeter {
  import wasi:http/outgoing-handler@0.2.0;   // capability: outbound HTTP
  export greet: func(name: string) -> string; // what we expose
}
```

**WIT (WebAssembly Interface Types)** is the IDL: defines typed interfaces —
strings, records, variants, resource handles — and the Canonical ABI translates them
across the Wasm boundary. Resources are first-class typed handles (unforgeable
capability tokens); type mismatches are caught at link time.

**Capability grant mechanism**: imports are satisfied at component instantiation by
the host or by composing with another component that exports the matching interface.
Capability checking is structural/nominal (does the component's declared import match
something the host provides?) rather than a separate policy layer.

### Maturity (June 2026)

- **WASI Preview 2 (v0.2.x)**: stable; v0.2.11 released April 7, 2026. Production
  use in Wasmtime, used by Cloudflare Workers, Fastly Compute, Fermyon/Akamai
  Functions.
- **WASI 0.3 / Preview 3**: released February 2026; adds native async I/O
  (futures + streams), language-integrated concurrency; Spin v3.5 shipped first
  WASIp3 RC in November 2025. Spec API names could shift.
- **Wasm 3.0**: W3C standard, September 2025.
- **Component Model**: specified and shipping in runtimes but not yet a W3C
  standard; the "Docker moment" (broad cross-runtime composition) is pending — the
  component spec itself is still a W3C proposal-phase draft. Cross-language
  composition works in Wasmtime/WASI context; full portability across all engines
  still maturing.
- **Threads**: major missing primitive; wasi-threads experimental. Not in Preview 2
  mainstream runtimes. Blocks compute-heavy server workloads.
- **WasmGC** (required for Medaka's WasmGC backend): separate proposal. Wasm GC
  struct/array heap types; enables managed-language backends (Kotlin, Dart, Grain
  WasmGC direction). Targeting this means a **direct WIT emitter**, not LLVM
  (LLVM targets linear-memory Wasm; WasmGC is a separate code path).

### What a Medaka component would look like

A Medaka plugin compiled to a Wasm component would declare a WIT world whose imports
correspond to its effect row. The effect row is the **semantic layer**; the WIT world
is the **binary-format expression** of it at the Wasm boundary. These are
complementary, not competing: Medaka verifies the effect row statically (stronger,
compiler-derived, transitive), and the WIT world enforces it at the module boundary
at runtime (coarser but binary-format portable and host-checkable without Medaka).

A host could accept Medaka components and trust the WIT world alone (coarse); or
also verify the Medaka-generated effect manifest (fine-grained, static) to get
tighter guarantees than the binary boundary alone provides.

### Key tension: Medaka manifest vs. WIT world

The component model's capability boundary is **import-driven at instantiation**: the
host grants what imports it satisfies. There is no "capability manifest" file that a
host reads separately — the WIT `world` declaration *is* the manifest. This means:

- A Medaka-compiled component whose effect row is `{KV, Log}` should emit a WIT
  world that imports only `wasi:kv/...` and `wasi:logging/...` — the WIT world and
  the effect row must agree.
- The host can enforce via standard Wasm instantiation (deny ungranted imports);
  it does not need to parse a separate Medaka-format manifest for coarse enforcement.
- A **separate Medaka manifest** (e.g. `[package.capabilities]` in TOML) serves a
  **different purpose**: human-readable metadata, integration with non-Wasm hosts
  (the current LLVM native demo, CI/CD policy gates, `medaka check-policy`), and
  documentation for the platform SDK. It is the pre-Wasm layer and the
  source-of-truth for the `check-policy` demo.

**Recommendation**: emit two artifacts: (a) a `[package.capabilities]` TOML block
(human-readable, check-policy input, native/pre-Wasm use); (b) when WasmGC/component
backend exists, also declare the WIT world to match the effect row exactly, so the
binary-boundary enforcement is consistent with the static manifest.

---

## 2. Edge-host isolation (Cloudflare / Fastly / Fermyon Spin)

All three converged on the same underlying model by 2025–2026:

| Platform | Runtime | WASI status | Capability model | Key limit |
|---|---|---|---|---|
| **Cloudflare Workers** | workerd / V8 isolates | WASI = experimental, partial syscalls only | V8 isolates; no raw sockets; access via fetch/bindings only; process-level sandbox for extra isolation | JS-first; Wasm WASI support not production-grade |
| **Fastly Compute** | Viceroy (Wasmtime-based) | WASI Preview 2 via Wasmtime | Wasm module with explicit host imports; network via `fastly_http_req`/backend config; secrets/stores via typed host APIs | fastly.toml is build/deploy config only — **no** capability allowlist in manifest |
| **Fermyon Spin / Akamai Functions** | Wasmtime | WASI P2 production; P3 RC (November 2025) | `allowed_outbound_hosts` per component in `spin.toml`; KV/SQL/AI inferencing via typed SDK imports; full WASI P2 capability model | Fermyon acquired by Akamai December 2025; now Akamai Functions |

### What a host actually consumes from a Medaka manifest

All three platforms enforce capabilities at the **Wasm import boundary** (what
host functions the module is linked to), not via a separate policy file. However,
**Spin is the closest match** to what Medaka wants:

- Spin's `spin.toml` has an `allowed_outbound_hosts` field per component:
  ```toml
  [component.plugin]
  allowed_outbound_hosts = ["https://idp.example.com"]
  ```
  This is a **coarse runtime allowlist** (URL-level, not function-level). It is
  enforced by the Spin host at request time.
- A Medaka-generated capability manifest (from the verified effect row) could
  **populate this field automatically** from the entry point's inferred row —
  e.g., `<Fetch "idp.example.com">` → `allowed_outbound_hosts = ["https://idp.example.com"]`.
  This is the concrete translation step that closes the loop from type to deployment.

### Cloudflare: the complication

Cloudflare Workers use V8 isolates for JS/WASM, not WASI. WASI support is
experimental and partial. A Medaka → Wasm component targeting Cloudflare today
requires JS glue or `workers-wasi` experimental shim. The cleaner Cloudflare story
is deferred to when WasmGC/component-model adoption widens — Cloudflare has not
committed to Production WASI P2 as of 2026.

**Implication**: for the near-term real deployment target, **Spin/Akamai Functions**
(full WASI P2, explicit TOML capability config, WIT-component direction) is the best
fit. Fastly Compute is a secondary option (WASI P2 via Wasmtime) but its manifest
format offers no capability policy field — enforcement is entirely via host-import
linking at build time.

### The "Sandbox SDK" distinction (Cloudflare)

Cloudflare's Sandbox SDK runs untrusted code in isolated containers (full Linux
environment), separate from Workers. Its credential pattern (Worker proxy validates
JWTs from sandbox, injects real credentials) is essentially the Level-2 segregation
model (§7 of CAPABILITY-PLATFORM.md) implemented at the container level rather than
the effect-type level. Medaka's approach gives the same guarantee statically
and more cheaply.

---

## 3. Object-capability & effects-as-security literature

### The ocap invariants Medaka must preserve

The object-capability model requires:
1. **No ambient authority**: a module can only use resources passed to it as
   explicit references. No global mutable state, no implicit imports.
2. **Unforgeability**: capabilities cannot be synthesized; only obtained by creation,
   parenthood, endowment, or introduction (Dennis & Van Horn).
3. **Transitivity**: the capability set of a function is bounded by what it receives,
   transitively. A function cannot acquire capabilities it was not given.

Medaka's effect system satisfies the intent of (1) and (3) at the type level: the
effect row is transitively inferred; a function cannot have an effect in its row
unless it calls something (an extern, ultimately a host import) that carries that
effect. The "unforgeability" invariant (2) holds because effect labels are compiler
vocabulary (not values) and externs are the only way to "perform" an effect. **The
host import is the capability token**; the effect label is the type-level name for it.

### The PL literature: two framings

Two research lineages address effects + capabilities, converging:

**Effekt / System C (capability-based)**: model effects as capabilities — second-class
function values (blocks) that grant authority when in scope. The caller passes a
capability; the callee can only use effects the capability grants. No ambient
authority by construction. Contextual effect polymorphism rather than effect
variables. See: Brachthäuser, Schuster, Ostermann (2020), "Effekt: Capability-Passing
Style for Type- and Effect-Safe, Extensible Effect Handlers in Scala" (JFP).

**Koka / row-polymorphic**: effects as row labels in function types; effect polymorphism
via row variables. Functions carry their effect row; inference computes it
transitively. Sound (no effect laundering if the system is closed). Leijen (2014),
"Koka: Programming with Row Polymorphic Effect Types" (arXiv:1406.2061). Koka v3.1.3
active as of July 2025.

**Synthesis: Tang & Lindley (POPL 2026)**, "Rows and Capabilities as Modal Effects"
(arXiv:2507.10301): unifies both framings via modal effect types. Key finding:
row-based and capability-based systems are different encodings of the same underlying
structure; each trades off between effect polymorphism styles and first-class function
support. **Medaka's design is the row-based framing** — correct and sound, with the
limitation that it requires effect variables for polymorphism (Medaka already has
these: `<e>` row tails). The capability-framing (Effekt) avoids effect variables but
requires second-class functions. Since Medaka targets general-purpose programming
(first-class functions), the row-based framing is the right choice.

**Odersky ICFP 2024 keynote, "Capabilities for Control"**: object-capability model
experiencing a renaissance in type systems. Scala 3 capture checking tracks
capabilities as captured variables in types. The security application (Gradient,
2024): gradual compartmentalization using object capabilities tracked in types
against supply-chain attacks. **These systems track capability *possession*, not just
capability *use* as effects**. The distinction matters for Medaka: Medaka's effect
rows track whether a function *can reach* a capability (transitive use), which is
sufficient for the manifest use case.

**"Designing with Static Capabilities and Effects: Use, Mention, and Invariants"**
(arXiv:2005.11444): formally names the key asymmetry — possession ≠ use. A system
can tell you what a function *can* do (capability-based: what it possesses) vs. what
it *does do* (effect-based: what it performs). Medaka's system tracks *use* (via
effect propagation) which is sufficient for sandboxing. Possession-based systems
(Wyvern, Scala CC) are more conservative (they flag any code that *has* the
capability, even if it doesn't use it). **Both are sound for security; use-based
gives fewer false positives**.

**PermRust (arXiv:2506.11701, 2026)**: token-based permission system for Rust with
explicit I/O tokens. Similar goal to Medaka's effect rows (make I/O explicit, prevent
ambient authority), but implemented as value tokens rather than type-level labels.

### Invariants Medaka must preserve to claim "capability-safe"

1. **Effect labels must correspond 1:1 to host capabilities**. Each `effect Foo` must
   have a unique host import that is the *only* way to perform that effect. No
   side-channel (no unsafe, no FFI escape in plugin code).
2. **Externs are the capability primitives**. A bare `effect Foo` does nothing without
   an `extern foo : ... -> <Foo> ...`. The extern is the unforgeable reference.
3. **No ambient auth**: submitted plugins must not be able to declare their own
   externs matching platform host functions. The platform controls the extern
   namespace.
4. **Laundering soundness (already closed)**: effect rows must not be droppable via
   coercion to a pure type. This is now enforced.
5. **No handler escape**: Medaka explicitly rejects algebraic-effect handlers — the
   host is the handler. Plugin code cannot install a handler that intercepts and
   reinterprets an effect. This is the "tracking ≠ handlers" separation.

**Currently sound or explicitly enforced**: (1) by design of the `extern` mechanism,
(4) by Phase 146 laundering fixes. **Open**: (3) — the platform's extern-namespace
control is a deployment constraint, not yet enforced by the compiler (plugins can
declare their own externs). This is a design question for the manifest format: the
host must either (a) only link its own externs (WASI instantiation model handles
this), or (b) Medaka must allow a "sealed extern namespace" mode for submitted code.

---

## 4. Competitor scan

### MoonBit (closest)

MoonBit is the most direct competitor for Wasm-first functional language. Status
as of 2025-2026: beta-to-1.0 (beta released June 2025; 1.0 planned H1 2026). Open
source December 2024. 10–100× faster compilation than Rust.

**Effect system**: MoonBit has **limited, narrowly scoped effect tracking** in types:
- Error effects (`raise`/`noraise` annotations on function signatures)
- Async effects (compiler tracks asyncness; IDE highlights async calls; structured
  concurrency model with `with_task_group` and cancellation-as-error)

**No general capability/security effect tracking**. MoonBit does not have:
- Capability labels (`effect Foo` vocabulary)
- Security-oriented effect row inference
- `check-policy`-style manifest verification

MoonBit's "capability" story is entirely the **component model boundary**: WIT worlds,
WASI imports, and structured concurrency runtime safety. The language does not give
you a compile-time "what can this function access?" manifest beyond error/async types.

**Component model**: MoonBit has first-class WIT/component-model tooling (`wit-bindgen`
integration, tutorial-documented). It targets WasmGC + component model as primary
deployment. It presented at WASM I/O 2025 on AI agents with Wasm components.

**Differentiation from Medaka**: MoonBit has better tooling and industrial backing
(IDEA Group). Medaka's effect row system is **significantly more powerful** for
capability safety: it infers the full capability set of any function transitively,
user-defines fine-grained capability labels, and verifies policy bounds at
compile time without any runtime enforcement. MoonBit cannot tell you "this function
cannot reach the network"; Medaka can. That gap is Medaka's wedge.

### Grain

Grain is a functional, WebAssembly-first language (via Binaryen, not LLVM; WasmGC
direction). No platform or effect-capability system. Effects are direct and
side-effecting code is permitted; capability model relies entirely on WASI/host
imports at the Wasm boundary. Active development (WIT bindgen commits into 2026) but
no capability safety story beyond WASI's coarse "host grants imports" model. Grain is
not a direct competitor on the capability-safety axis.

### Roc

Roc's platform model is conceptually closest to capability-safe design:
- **All I/O primitives come from the platform**: the stdlib has only data structures;
  effects come from the platform the app links against. Effects not available on a
  platform cannot be called — **build-time prevention**, not runtime enforcement.
- **Exclusivity**: platform authors have exclusive control over what primitives exist.
  A browser/WASM platform omits file I/O; mismatches fail at build time.
- **Single-platform per binary**: a Roc app links exactly one platform; the platform
  is the capability grantor.

**Key difference from Medaka**: Roc's capability set is **platform-scoped** (fixed at
link/build time) not **function-scoped** (per entry-point, transitively inferred).
Roc cannot tell you whether a *function within a program* uses file I/O; only whether
the program's platform offers it. Medaka's per-function effect rows give a
**function-level capability manifest**, which is what you need for the plugin/SDK
model (different plugins in the same program need different capability bounds).

**Maturity**: Roc is early-stage (alpha; new zig-based compiler in nightlies; basic-cli
0.20.0). Platform composition (multi-plugin) and Wasm-specific platform design are
not yet worked out. The effect interpreter model (tag union + continuation) is planned
but not shipped.

---

## Implications for Medaka's capability-manifest format & surface syntax

### What the manifest must contain

A minimal capability manifest for a Medaka plugin entry point includes:

1. **Entry point name**: which function is the plugin boundary.
2. **Effect row** (the verified set): the compiler-derived label set, e.g.
   `{Cache, Log}`. This is the authoritative source — computed, not declared.
3. **Parameterized atoms** (Phase 146b, future): `Fetch "idp.example.com"`, etc.
4. **Required interface** (the plugin SDK contract): which effect-labeled externs
   the plugin expects the host to provide (maps to the WIT imports).
5. **Policy bound declared** (optional, user-written): the `<Cache, Log>` annotation
   the user explicitly put on the entry point signature; the compiler verifies
   inferred ⊆ declared. Both are useful: declared = policy contract; inferred = proof.

### Recommended format: dual-layer

**Layer 1 — human-readable TOML `[package.capabilities]` block**

In `medaka.toml` (or a sidecar `capabilities.toml` next to the emitted Wasm):

```toml
[package.capabilities]
entry = "transform"
declared_bound = ["Cache", "Log"]
verified_effects = ["Cache", "Log"]  # compiler-derived, sound
required_externs = [
  { name = "cacheGet",  type = "String -> <Cache> String" },
  { name = "cacheSet",  type = "String -> String -> <Cache> Unit" },
  { name = "logEvent",  type = "String -> <Log> Unit" },
]
```

This is the format `medaka check-policy` already conceptually consumes. It is the
pre-Wasm, developer-facing, CI/CD-integrable artifact. Crucially: `verified_effects`
is **compiler-emitted**, not user-written — the host reads it from the build artifact,
not the source.

**Layer 2 — WIT world (when WasmGC/component backend exists)**

```wit
world plugin {
  import cache-get: func(key: string) -> string;
  import cache-set: func(key: string, val: string);
  import log-event: func(msg: string);
  export transform: func(req: string) -> string;
}
```

The world's imports = `verified_effects` mapped to WIT interfaces. The compiler
generates this world declaration as a build artifact alongside the Wasm binary. A
standard Wasm host can enforce it at instantiation without needing to understand
Medaka's effect system.

**The two layers serve different audiences**:
- TOML: human operators, CI/CD policy gates, `medaka check-policy`, platforms that
  want fine-grained per-function reasoning, the "show the call chain" story.
- WIT world: standard Wasm hosts (Spin, Wasmtime, Fastly), binary-level enforcement,
  language-agnostic tooling.

### Mapping to WASI / component model

Effect labels should map to standard WASI interfaces where they exist:
- `<IO>` / `<Log>` → `wasi:logging` (if WASI logging interface stabilizes; currently
  ad-hoc in most platforms)
- `<Fetch>` → `wasi:http/outgoing-handler@0.2.0`
- `<KV>` → `wasi:keyvalue` (experimental in WASI; Spin has its own KV API)
- `<Mut>` → no WASI counterpart (internal; signals mutable state, not a host
  capability)
- Custom labels (`<GeoIP>`) → platform-specific host imports

**Don't invent what the component model already expresses.** Where a WASI standard
interface exists, map to it. Where it doesn't, declare a custom import in the WIT
world.

### Which host to target first

**Fermyon Spin / Akamai Functions** is the best first target:
- Full WASI P2 (stable), Wasmtime-based (reference implementation).
- `spin.toml` has `allowed_outbound_hosts` — a real, documented capability config
  field. The Medaka manifest emission can **generate this field** from the entry
  point's `<Fetch d>` atoms.
- WIT/component-model direction is Spin's stated roadmap.
- Wasm P3 (async) RC already shipping (November 2025) — Medaka's effects-erased
  model is compatible with any async model at the host level.
- Akamai acquisition brings infrastructure scale without changing the technical model.

Cloudflare is a secondary target: its WASI support is experimental; the V8-isolate
JS-first model is a worse fit for a compiled-Medaka-to-Wasm story. Target after WasmGC
backend exists and WASI component model support in Cloudflare Workers matures.

### Surface syntax

No changes needed for the manifest format itself — the existing surface syntax
(`effect Foo`, `export effect Foo`, annotated entry-point signatures) is already the
right surface. The manifest is a **compiler output**, not a source-level declaration.

The one surface design question: should the user annotate the entry point's bound
explicitly (`handler : Request -> <KV, Log> Response`) or let the compiler infer it
and emit the manifest automatically? **Recommendation**: both paths should work.
Explicit annotation gives the policy contract (compiler verifies inferred ⊆ annotated);
unannotated entry point emits the inferred row as the manifest (weaker — any effect
change widens the manifest automatically, which may be surprising). The `check-policy`
flag model already implements the explicit-bound path.

---

## Open questions / forks for the design note

> **Historical note (verified done 2026-06-22):** these were inputs to the
> `CAPABILITY-EFFECTS-V2-DESIGN.md` design pass + the WS-1–4 workstreams. Items 2,
> 4, 5, 7 are resolved; items 1, 3, 6 remain open design questions for the
> platform/WasmGC layer. See `EFFECTS-CONFORMANCE-ROADMAP.md` for current state.

1. **Extern namespace sealing**: how does the platform prevent a submitted plugin from
   declaring its own `extern fetch` (bypassing the effect system by naming a host
   function directly)? Options: (a) the compilation sandbox forbids `extern`
   declarations in plugin source; (b) the host only links its own namespaced imports
   and ignores plugin-declared externs; (c) Medaka adds a "no-extern" module mode.
   The WASI instantiation model (host only supplies its declared imports) handles (b)
   for Wasm targets, but the native demo needs an explicit answer.

2. **TOML vs. embedded in Wasm custom section**: ✅ **RESOLVED** — TOML
   (`medaka manifest` → `[package.capabilities]`, WS-1c 2026-06-21) done; custom
   section deferred to WasmGC backend (`wasm_emit.mdk`).

3. **Effect → WASI mapping table**: which standard WASI interfaces do Medaka's
   built-in labels (`IO`, `Mut`, `Async`, `Panic`, `Rand`, `Time`) and the common
   custom labels (`Fetch`, `KV`, `Log`) map to? `Mut` and `Panic` have no WASI
   counterpart (they are internal tracking effects, not host capabilities). The design
   note should pin the mapping table and decide which labels are "internal-only"
   (not emitted in the manifest) vs. "host-capability" (emitted).

4. **Parameterized effects in the manifest** (Phase 146b): ✅ **RESOLVED** —
   `medaka manifest` emits parameterized atoms (WS-1c/WS-3b, 2026-06-21). The
   Spin `allowed_outbound_hosts` translation and the WIT world annotation remain
   future platform work (no WasmGC backend yet).

5. **Inferred vs. declared in the emitted manifest**: ✅ **RESOLVED** —
   `medaka manifest` emits the inferred row (compiler's proof); `check-policy` takes
   the user-declared bound as the policy; `EFFECTS-CONFORMANCE-ROADMAP.md` WS-1c.

6. **Multi-entry-point plugins**: the plugin SDK model (CAPABILITY-PLATFORM.md §5)
   expects multiple bounded functions per plugin (e.g. `extractToken`, `verify`,
   `decide`). The manifest must capture each entry's bound separately. The TOML format
   should be an array of entry points, each with its own `verified_effects`.

7. **The target-first decision**: ✅ **RESOLVED** — manifest emission + native
   `medaka check-policy` is sufficient for the "wow" demo phase (CAPABILITY-PLATFORM.md
   §7c: demo is complete and runnable). Spin/Wasm integration waits on WasmGC backend.

---

## Sources

- [WASI and the WebAssembly Component Model: Current Status — eunomia.dev (Feb 2025)](https://eunomia.dev/blog/2025/02/16/wasi-and-the-webassembly-component-model-current-status/)
- [Bytecode Alliance — WebAssembly: An Updated Roadmap for Developers](https://bytecodealliance.org/articles/webassembly-the-updated-roadmap-for-developers)
- [WASI Preview 2 vs. WASIX (2026) — wasmruntime.com](https://wasmruntime.com/en/blog/wasi-preview2-vs-wasix-2026)
- [Wasm Components & WASI Preview 3 at the Edge (2026) — techbytes.app](https://techbytes.app/posts/wasm-components-wasi-preview-3-edge-optimization-2026/)
- [WebAssembly in 2026: WASI 0.2 — Java Code Geeks (Apr 2026)](https://www.javacodegeeks.com/2026/04/webassembly-in-2026-where-it-has-landed-what-wasi-0-2-changes-and-why-java-and-kotlin-developers-should-pay-attention-now.html)
- [Capabilities-Based Security with WASI — marcokuoni.ch](https://marcokuoni.ch/blog/15_capabilities_based_security/)
- [Spin Application Manifest Reference — developer.fermyon.com](https://developer.fermyon.com/spin/v2/manifest-reference)
- [Spin HTTP Outbound (`allowed_outbound_hosts`) — spinframework.dev](https://spinframework.dev/v2/http-outbound)
- [Announcing Spin 2.0 — fermyon.com](https://www.fermyon.com/blog/introducing-spin-v2)
- [Akamai acquires Fermyon — Network World (Dec 2025)](https://www.networkworld.com/article/4099424/akamai-acquires-fermyon-for-edge-computing-as-webassembly-comes-of-age.html)
- [Cloudflare Workers: Security Model — developers.cloudflare.com](https://developers.cloudflare.com/workers/reference/security-model/)
- [Cloudflare Workers: WebAssembly — developers.cloudflare.com](https://developers.cloudflare.com/workers/runtime-apis/webassembly/)
- [Cloudflare Sandbox SDK — developers.cloudflare.com](https://developers.cloudflare.com/sandbox/)
- [fastly.toml manifest reference — Fastly documentation](https://www.fastly.com/documentation/reference/compute/fastly-toml/)
- [Rows and Capabilities as Modal Effects — Tang & Lindley, POPL 2026, arXiv:2507.10301](https://arxiv.org/abs/2507.10301)
- [Modal Effect Types — arXiv:2407.11816](https://arxiv.org/pdf/2407.11816)
- [Koka: Programming with Row Polymorphic Effect Types — Leijen, arXiv:1406.2061](https://arxiv.org/abs/1406.2061)
- [Effekt: Capability-Passing Style — Brachthäuser, Schuster, Ostermann (JFP 2020)](https://www.cambridge.org/core/services/aop-cambridge-core/content/view/A19680B18FB74AD95F8D83BC4B097D4F/S0956796820000027a.pdf/effekt_capabilitypassing_style_for_type_and_effectsafe_extensible_effect_handlers_in_scala.pdf)
- [Scoped Capabilities for Polymorphic Effects — arXiv:2207.03402](https://arxiv.org/pdf/2207.03402)
- [Designing with Static Capabilities and Effects: Use, Mention, and Invariants — arXiv:2005.11444](https://arxiv.org/pdf/2005.11444)
- [Object-Capability as Means of Permission and Authority — arXiv:1907.07154](https://arxiv.org/pdf/1907.07154)
- [Capabilities for Control — Odersky, ICFP 2024 keynote](https://icfp24.sigplan.org/details/icfp-2024-papers/38/Capabilities-for-Control)
- [Tracking Capabilities for Safer Agents — arXiv:2603.00991 (2026)](https://arxiv.org/pdf/2603.00991)
- [PermRust: A Token-based Permission System for Rust — arXiv:2506.11701 (2026)](https://arxiv.org/pdf/2506.11701)
- [Roc Platforms and Apps — roc-lang.org](https://www.roc-lang.org/platforms)
- [Roc Planned Changes — roc-lang.org](https://www.roc-lang.org/plans)
- [MoonBit: 10 Features — Hivemind Technologies, Medium](https://medium.com/@hivemind_tech/moonbit-language-in-10-features-4dc41a3a1d6c)
- [MoonBit for Component Model — docs.moonbitlang.com](https://docs.moonbitlang.com/en/stable/toolchain/wasm/component-model-tutorial.html)
- [Introducing Async Programming in MoonBit — moonbitlang.com](https://www.moonbitlang.com/blog/moonbit-async)
- [MoonBit Error Handling — docs.moonbitlang.com](https://docs.moonbitlang.com/en/latest/language/error-handling.html)
- [Grain in WebAssembly — developer.fermyon.com](https://developer.fermyon.com/wasm-languages/grain)
- [Meet Grain: High-Level Language for WebAssembly — The New Stack](https://thenewstack.io/meet-grain-the-high-level-language-optimized-for-webassembly/)
- [How to Build WebAssembly Components with MoonBit — The New Stack](https://thenewstack.io/how-to-build-webassembly-components-with-the-moonbit-language/)
