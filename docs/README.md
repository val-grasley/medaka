# Docs index

<!-- GENERATED — do not edit by hand; run `make docs-index`
     (test/gen_docs_index.sh). Regenerating after a doc move/add/rename is a
     no-op if nothing changed: same input -> byte-identical output. -->

Fast lookup for an agent (or human) trying to find the right doc. Each row
leads with the doc, then a one-line summary and its current status (pulled
straight from the doc's own `**Status:**` banner — this table cannot drift
from what the doc says about itself). **PARTIAL/OPEN work is live; a doc
under `archive/` is IMPLEMENTED/SUPERSEDED and kept for provenance, not
current guidance.**

Root entry points (not indexed below — always here): [`README.md`](../README.md)
(build/test/CLI), [`AGENTS.md`](../AGENTS.md) (agent orientation, router),
[`PLAN.md`](../PLAN.md) (open roadmap), [`HANDOFF.md`](../HANDOFF.md)
(start-here snapshot — its own banner flags it partly stale; treat as a
pointer to `docs/ops/DISTRIBUTION-DESIGN.md` / `docs/ops/RELEASE-0.1.0-PLAN.md`
for current status, not as live guidance itself).

### spec — language ground truth

What parses, what it means, formal semantics. Read here first for "does X exist / what does X mean".

| Doc | What it is | Status |
|-----|------------|--------|
| [`DICT-SEMANTICS.md`](spec/DICT-SEMANTICS.md) | Dictionary-Passing Semantics for Medaka Interfaces | specification |
| [`EFFECTS-SEMANTICS.md`](spec/EFFECTS-SEMANTICS.md) | Effect-and-Capability Semantics for Medaka | specification |
| [`LAYOUT-SEMANTICS.md`](spec/LAYOUT-SEMANTICS.md) | LAYOUT-SEMANTICS.md — Medaka's layout rule, formalized | OPEN |
| [`SHADOW-SEMANTICS.md`](spec/SHADOW-SEMANTICS.md) | Declaration-Shadowing Semantics (standalone fn ⇄ interface method) | ENFORCED |
| [`STYLE.md`](spec/STYLE.md) | Medaka style guide | — |
| [`SYNTAX.md`](spec/SYNTAX.md) | SYNTAX.md — Medaka construct cheat-sheet | — |
| [`language-design.md`](spec/language-design.md) | Medaka Language Design Document | PARTIAL |

### guide — learning path

Tutorial-style onboarding, not a spec. Not yet cross-linked into this index's status convention (no banners) — this is prose-in-progress, read for teaching order, not ground truth.

| Doc | What it is | Status |
|-----|------------|--------|
| [`0. Introduction.md`](guide/0. Introduction.md) | Introduction | — |
| [`1. Quick Start.md`](guide/1. Quick Start.md) | Quick Start | — |
| [`2. Expressions.md`](guide/2. Expressions.md) | Expressions | — |
| [`OUTLINE.md`](guide/OUTLINE.md) | Medaka Guide — Outline | — |

### design — open/partial work

Live design docs: **OPEN** = not started, **PARTIAL** = in progress. Read before touching the area; update the doc when you close it (then it moves to `archive/design/`).

| Doc | What it is | Status |
|-----|------------|--------|
| [`AT-IMPL-PORT-DESIGN.md`](design/AT-IMPL-PORT-DESIGN.md) | `@Impl` Named-Instance-Selection Hint — Native Port Design | OPEN |
| [`CAPABILITY-EFFECTS.md`](design/CAPABILITY-EFFECTS.md) | Capability-safe effects — Medaka's headline direction | PARTIAL |
| [`CAPABILITY-PLATFORM.md`](design/CAPABILITY-PLATFORM.md) | The capability platform — runtime/product architecture | OPEN |
| [`EFFECTS-CONFORMANCE-ROADMAP.md`](design/EFFECTS-CONFORMANCE-ROADMAP.md) | Effect-and-Capability Conformance Roadmap | PARTIAL |
| [`GAP3-SLICE7-DESIGN.md`](design/GAP3-SLICE7-DESIGN.md) | Gap 3 — slice-7 arg-tag dispatch on a generic prelude free function | OPEN |
| [`INTERFACE-CANDIDATES.md`](design/INTERFACE-CANDIDATES.md) | INTERFACE-CANDIDATES.md — which built-in constructs could generalize behind an interface | PARTIAL |
| [`LANGUAGE-SURFACE-AUDIT.md`](design/LANGUAGE-SURFACE-AUDIT.md) | LANGUAGE-SURFACE-AUDIT.md | OPEN |
| [`MUT-SCOPING-DESIGN.md`](design/MUT-SCOPING-DESIGN.md) | `<Mut>` scoping — effect masking for allocate→fill→freeze | OPEN |

### ops — release, testing, distribution

Cross-cutting process docs: how the test suite is organized, how a build ships, what's left before 0.1.0.

| Doc | What it is | Status |
|-----|------------|--------|
| [`DISTRIBUTION-DESIGN.md`](ops/DISTRIBUTION-DESIGN.md) | DISTRIBUTION-DESIGN.md — shipping a native `medaka` binary to strangers | PARTIAL |
| [`RELEASE-0.1.0-PLAN.md`](ops/RELEASE-0.1.0-PLAN.md) | RELEASE-0.1.0-PLAN.md — the road to a public 0.1.0 preview | OPEN |
| [`TESTING-DESIGN.md`](ops/TESTING-DESIGN.md) | TESTING-DESIGN.md — a coherent testing architecture for Medaka | PARTIAL |

### stdlib — library plan

What's in the standard library, what's planned, module-by-module status.

| Doc | What it is | Status |
|-----|------------|--------|
| [`FP-STDLIB-DESIGN.md`](stdlib/FP-STDLIB-DESIGN.md) | FP Standard Library — Typeclasses, Combinators & Error Handling | IMPLEMENTED |
| [`P1-STDLIB-DESIGN.md`](stdlib/P1-STDLIB-DESIGN.md) | P1 Standard Library — Design & Prioritization | PARTIAL |
| [`STDLIB.md`](stdlib/STDLIB.md) | Medaka Standard Library Plan | — |

### compiler internals — stay in compiler/, indexed here for findability

47 docs live next to the code they describe (compiler/*.md) and are NOT moved by the docs-tree reorg. Listed here so they're still one search away.

| Doc | What it is | Status |
|-----|------------|--------|
| [`ARCH-REVIEW.md`](../compiler/ARCH-REVIEW.md) | Medaka Architecture Review | PARTIAL |
| [`ARGSTAMP-UNIFY-PLAN.md`](../compiler/ARGSTAMP-UNIFY-PLAN.md) | ARGSTAMP-UNIFY-PLAN.md — retire the `emitArgStampPasses` eval-vs-emit dispatch fork | IMPLEMENTED |
| [`BOOTSTRAP.md`](../compiler/BOOTSTRAP.md) | BOOTSTRAP.md — Native self-compile slices | IMPLEMENTED |
| [`COMPOSITE-MAIN-AUTOPRINT-DESIGN.md`](../compiler/COMPOSITE-MAIN-AUTOPRINT-DESIGN.md) | Composite-`main` Auto-Print — Design (Option A: uniform auto-print) | PARTIAL |
| [`CONSTRUCT-COVERAGE.md`](../compiler/CONSTRUCT-COVERAGE.md) | CONSTRUCT-COVERAGE.md — `medaka build` native coverage matrix | PARTIAL |
| [`DIAGNOSTIC-CODES-DESIGN.md`](../compiler/DIAGNOSTIC-CODES-DESIGN.md) | DIAGNOSTIC-CODES-DESIGN.md | IMPLEMENTED |
| [`DIAGNOSTICS-SURFACING-PLAN.md`](../compiler/DIAGNOSTICS-SURFACING-PLAN.md) | DIAGNOSTICS-SURFACING-PLAN.md — native `check` error positions + messages (WS-4 / F6) | IMPLEMENTED |
| [`DISPATCH-GAPS-SCOPE.md`](../compiler/DISPATCH-GAPS-SCOPE.md) | DISPATCH-GAPS-SCOPE.md | IMPLEMENTED |
| [`DISPATCH-INVENTORY.md`](../compiler/DISPATCH-INVENTORY.md) | DISPATCH-INVENTORY.md | PARTIAL |
| [`DRIVER-COLLAPSE-PLAN.md`](../compiler/DRIVER-COLLAPSE-PLAN.md) | DRIVER-COLLAPSE-PLAN.md — collapse the dual single-file / multi-module drivers | IMPLEMENTED |
| [`EMITTER-GAPS.md`](../compiler/EMITTER-GAPS.md) | EMITTER-GAPS.md | PARTIAL |
| [`EQ-DISPATCH-DESIGN.md`](../compiler/EQ-DISPATCH-DESIGN.md) | `==`/`!=` → `Eq` Dispatch (Option A) — Design + Blast-Radius Census | OPEN |
| [`ERROR-QUALITY.md`](../compiler/ERROR-QUALITY.md) | ERROR-QUALITY.md | IMPLEMENTED |
| [`FMT-COMMENT-INTERLEAVING-DESIGN.md`](../compiler/FMT-COMMENT-INTERLEAVING-DESIGN.md) | FMT comment-interleaving design — fixing finding "L" | IMPLEMENTED |
| [`HELPER-CENSUS.md`](../compiler/HELPER-CENSUS.md) | compiler/ generic-helper census | PARTIAL |
| [`MESSAGE-AUDIT.md`](../compiler/MESSAGE-AUDIT.md) | MESSAGE-AUDIT.md | PARTIAL |
| [`MULTICLAUSE-EXHAUST-DESIGN.md`](../compiler/MULTICLAUSE-EXHAUST-DESIGN.md) | Multi-Clause Function Exhaustiveness — Design | IMPLEMENTED |
| [`PARSE-ERROR-LOCATION-DESIGN.md`](../compiler/PARSE-ERROR-LOCATION-DESIGN.md) | PARSE-ERROR-LOCATION-DESIGN | PARTIAL/IMPLEMENTED |
| [`PERF-NOTES.md`](../compiler/PERF-NOTES.md) | Self-host performance notes & log | SUPERSEDED BY `compiler/PERF-RESULTS.md` / `compiler/PERF-SCOPE.md` |
| [`PERF-RESULTS.md`](../compiler/PERF-RESULTS.md) | PERF-RESULTS.md — native-backend performance log | PARTIAL |
| [`PERF-RUNTIME.md`](../compiler/PERF-RUNTIME.md) | PERF-RUNTIME.md — general compiled-program performance | IMPLEMENTED |
| [`PERF-SCOPE.md`](../compiler/PERF-SCOPE.md) | PERF-SCOPE.md — Stage-3 bar-item-4 performance scoping | IMPLEMENTED |
| [`PRE-FLIP-GAPS.md`](../compiler/PRE-FLIP-GAPS.md) | PRE-FLIP-GAPS.md — outstanding native-compiler items to close before the canonicalization milestone flip | IMPLEMENTED |
| [`README.md`](../compiler/README.md) | compiler — the Medaka-in-Medaka compiler | IMPLEMENTED / SUPERSEDED-FRAMING |
| [`REROOT-PLAN.md`](../compiler/REROOT-PLAN.md) | REROOT-PLAN — taking the gate suite OFF the OCaml oracle | IMPLEMENTED |
| [`RESOLVER-DIAG-LOCATION-DESIGN.md`](../compiler/RESOLVER-DIAG-LOCATION-DESIGN.md) | Real source locations for the 3 `{0,0}`-range resolver diagnostics (F3) | IMPLEMENTED |
| [`RUNTIME-DESIGN.md`](../compiler/RUNTIME-DESIGN.md) | Runtime & extern strategy for the native (Stage 2.4) backend | IMPLEMENTED, with 2 items still deferred |
| [`RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md`](../compiler/RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md) | RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN | IMPLEMENTED |
| [`RUNTIME-TRAP-UNIFY-DESIGN.md`](../compiler/RUNTIME-TRAP-UNIFY-DESIGN.md) | Runtime-trap-format unification — design | OPEN |
| [`S1-CONSTRAINED-SHADOW-DESIGN.md`](../compiler/S1-CONSTRAINED-SHADOW-DESIGN.md) | S-1 — a CONSTRAINED definer-shadow standalone is miscompiled | IMPLEMENTED |
| [`SHARED-FLOAT-RESIDUAL-DESIGN.md`](../compiler/SHARED-FLOAT-RESIDUAL-DESIGN.md) | SHARED-FLOAT-RESIDUAL-DESIGN — the signature-free type-lost-Float residual | IMPLEMENTED |
| [`STAGE2-DESIGN.md`](../compiler/STAGE2-DESIGN.md) | Stage 2 backend architecture — bytecode VM first, or straight to LLVM? | IMPLEMENTED |
| [`TRMC-DESIGN.md`](../compiler/TRMC-DESIGN.md) | TRMC-DESIGN.md — tail-recursion-modulo-cons for the native LLVM backend | IMPLEMENTED |
| [`TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`](../compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md) | Tuple as a real type constructor — design doc | IMPLEMENTED |
| [`TYPE-ALIAS-EXPANSION-DESIGN.md`](../compiler/TYPE-ALIAS-EXPANSION-DESIGN.md) | Type-Alias Expansion — Design | IMPLEMENTED |
| [`TYPE-AWARE-LINT-DESIGN.md`](../compiler/TYPE-AWARE-LINT-DESIGN.md) | Type-Aware Lint Tier — Design | OPEN |
| [`TYPE-ERROR-SPAN-DESIGN.md`](../compiler/TYPE-ERROR-SPAN-DESIGN.md) | Type-error span precision — design | IMPLEMENTED |
| [`TYPECHECK-AUDIT.md`](../compiler/TYPECHECK-AUDIT.md) | Selfhost Typechecker Audit — 2026-06-09 | IMPLEMENTED |
| [`TYPECHECK-ERROR-FRAMING-DESIGN.md`](../compiler/TYPECHECK-ERROR-FRAMING-DESIGN.md) | TYPECHECK ERROR FRAMING — Design (Tier-3 "typecheck mis-framing" reservoir) | IMPLEMENTED |
| [`TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md`](../compiler/TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md) | Signature Constraint Soundness — Design + Blast-Radius Census | IMPLEMENTED |
| [`VALUE-RESTRICTION-DESIGN.md`](../compiler/VALUE-RESTRICTION-DESIGN.md) | Generalizing constructor / record applications of values (value-restriction relaxation) | IMPLEMENTED |
| [`WASM-FLOAT-TYPING-DESIGN.md`](../compiler/WASM-FLOAT-TYPING-DESIGN.md) | WASM-FLOAT-TYPING-DESIGN — the principled fix for W-SQLITE-4 | IMPLEMENTED |
| [`WASM-POLY-NUM-DESIGN.md`](../compiler/WASM-POLY-NUM-DESIGN.md) | WASM-POLY-NUM-DESIGN — closing the wasm polymorphic-`Num` arithmetic gap | IMPLEMENTED |
| [`WASM-SELFHOST-GAPS.md`](../compiler/WASM-SELFHOST-GAPS.md) | WasmGC self-host gap census | IMPLEMENTED |
| [`WASM-SELFHOST-ROADMAP.md`](../compiler/WASM-SELFHOST-ROADMAP.md) | WASM-SELFHOST-ROADMAP.md — driving the WasmGC backend to compile the compiler | IMPLEMENTED |
| [`WASMGC-DESIGN.md`](../compiler/WASMGC-DESIGN.md) | WASMGC-DESIGN.md — WasmGC backend implementation plan | IMPLEMENTED |
| [`WASMGC-TRMC-DESIGN.md`](../compiler/WASMGC-TRMC-DESIGN.md) | WASMGC-TRMC-DESIGN.md — scoping the general fix for the WasmGC runtime stack overflow (layer-5) | IMPLEMENTED |
| [`WS2-REKEY-DIAGNOSIS.md`](../compiler/WS2-REKEY-DIAGNOSIS.md) | WS-2 full re-key — diagnosis & deferral (module-qualified dict-arity identity) | PARTIAL |

### archive — closed / historical

IMPLEMENTED or SUPERSEDED work, kept for provenance. Links inside these docs are NOT rewritten when they narrate a past tree (flat files below + `PLAN-ARCHIVE.md`); `design/` and `findings/` are current archived docs whose links ARE kept live. See [`archive/README.md`](../archive/README.md) for the layout explanation.

### archive/design — shipped design docs

| Doc | What it is | Status |
|-----|------------|--------|
| [`ASYNC-DESIGN.md`](../archive/design/ASYNC-DESIGN.md) | ASYNC-DESIGN.md | IMPLEMENTED |
| [`BROWSER-STACK-DIAGNOSIS.md`](../archive/design/BROWSER-STACK-DIAGNOSIS.md) | BROWSER-STACK-DIAGNOSIS.md — the playground `Maximum call stack size exceeded` overflow | IMPLEMENTED |
| [`CAPABILITY-EFFECTS-RESEARCH.md`](../archive/design/CAPABILITY-EFFECTS-RESEARCH.md) | Capability-effects research findings | IMPLEMENTED |
| [`CAPABILITY-EFFECTS-V2-DESIGN.md`](../archive/design/CAPABILITY-EFFECTS-V2-DESIGN.md) | Capability-Effects v2 — design doc (parameterized effects + IO decomposition) | IMPLEMENTED |
| [`D2-REKEY-DESIGN.md`](../archive/design/D2-REKEY-DESIGN.md) | D2 cross-module dict-identity — design (reproduced + root-caused) | IMPLEMENTED |
| [`F1B-MODULE-IDENTITY-DESIGN.md`](../archive/design/F1B-MODULE-IDENTITY-DESIGN.md) | F1b Loader Module-Identity — Decision-Ready Design | IMPLEMENTED |
| [`INDEX-16-PLAN.md`](../archive/design/INDEX-16-PLAN.md) | INDEX-16-PLAN.md — concrete staged implementation plan for the Index arc, Phase #16 | IMPLEMENTED |
| [`INDEX-DESIGN.md`](../archive/design/INDEX-DESIGN.md) | INDEX-DESIGN.md — Indexing (`a[i]` / `a[i] := v`) design pass | IMPLEMENTED |
| [`LAYOUT-BRACKETS-DESIGN.md`](../archive/design/LAYOUT-BRACKETS-DESIGN.md) | LAYOUT-BRACKETS-DESIGN — block expressions inside brackets | IMPLEMENTED |
| [`LIB-REMOVAL-DESIGN.md`](../archive/design/LIB-REMOVAL-DESIGN.md) | LIB-REMOVAL-DESIGN — retiring the OCaml reference compiler (`lib/`+`bin/`+`gen/`) | IMPLEMENTED |
| [`MAP-SET-AMBIGUITY-DESIGN.md`](../archive/design/MAP-SET-AMBIGUITY-DESIGN.md) | MAP-SET-AMBIGUITY-DESIGN.md — ambiguous unqualified-import occurrence (use-time / approach A) | IMPLEMENTED |
| [`NET-DESIGN.md`](../archive/design/NET-DESIGN.md) | NET-DESIGN.md — Medaka networking (decision-ready) | IMPLEMENTED |
| [`NUMLIT-DESIGN.md`](../archive/design/NUMLIT-DESIGN.md) | Design: Num-polymorphic numeric literals (PLAN.md #11) | IMPLEMENTED |
| [`PLAYGROUND-DESIGN.md`](../archive/design/PLAYGROUND-DESIGN.md) | PLAYGROUND-DESIGN.md — in-browser Medaka playground | IMPLEMENTED |
| [`PLAYGROUND-EDITOR-DESIGN.md`](../archive/design/PLAYGROUND-EDITOR-DESIGN.md) | PLAYGROUND-EDITOR-DESIGN.md — Tier 3 in-browser editor | IMPLEMENTED |
| [`REEXPORT-METHOD-SCHEME-DESIGN.md`](../archive/design/REEXPORT-METHOD-SCHEME-DESIGN.md) | Re-export does not thread schemes into the importer's typecheck seed | IMPLEMENTED |
| [`RETPOS-DISPATCH-DESIGN.md`](../archive/design/RETPOS-DISPATCH-DESIGN.md) | RETPOS-DISPATCH-DESIGN — return-position-only method mis-dispatch (run≠build) | IMPLEMENTED |
| [`SQLITE-DESIGN.md`](../archive/design/SQLITE-DESIGN.md) | SQLite Read-Path Library — Design | design document |
| [`SQLITE-MUTATION-DESIGN.md`](../archive/design/SQLITE-MUTATION-DESIGN.md) | SQLite Mutation (UPDATE / DELETE) — Design & Feasibility | IMPLEMENTED |
| [`SQLITE-WASM-DESIGN.md`](../archive/design/SQLITE-WASM-DESIGN.md) | SQLITE-WASM-DESIGN.md — scoping the WasmGC port of the Medaka SQLite library | IMPLEMENTED |
| [`SQLITE-WRITE-DESIGN.md`](../archive/design/SQLITE-WRITE-DESIGN.md) | SQLite WRITE path — design (v1) | IMPLEMENTED |
| [`TRAVERSABLE-DEFAULT-METHOD-DESIGN.md`](../archive/design/TRAVERSABLE-DEFAULT-METHOD-DESIGN.md) | Making `sequence` a default method of `Traversable t` | IMPLEMENTED |
| [`WS-4-DESIGN.md`](../archive/design/WS-4-DESIGN.md) | WS-4 Design — `Product` refinement domain (structure-aware `Net = Host(Prefix) × Method(Set)`) | IMPLEMENTED |

### archive/findings — point-in-time QA/investigation sweeps

| Doc | What it is | Status |
|-----|------------|--------|
| [`FINDINGS.md`](../archive/findings/qa-beta-2026-07-07/FINDINGS.md) | Beta-hardening QA findings — 2026-07-07 | — |
| [`FIXTURES.md`](../archive/findings/qa-beta-2026-07-07/FIXTURES.md) | Regression fixtures to add — beta hardening, 2026-07-07 | — |
| [`P0-18-BUILD-PATH-DESIGN.md`](../archive/findings/qa-beta-2026-07-07/P0-18-BUILD-PATH-DESIGN.md) | P0-18 build-path soundness hole — design & scoping | — |
| [`P0-18-STANDALONE-DISPATCH-DESIGN.md`](../archive/findings/qa-beta-2026-07-07/P0-18-STANDALONE-DISPATCH-DESIGN.md) | P0-18 standalone-fn-shadows-interface-method — dispatch miscompile | — |
| [`P0-5-MUTABILITY-DESIGN.md`](../archive/findings/qa-beta-2026-07-07/P0-5-MUTABILITY-DESIGN.md) | P0-5 — Beta Mutability Model: enforce immutability + make `let mut` work | design / scoping pass |
| [`beginner-syntax.md`](../archive/findings/qa-beta-2026-07-07/reports/beginner-syntax.md) | Beginner-syntax findings (first-hour human-user simulation) | — |
| [`bindings-mutability.md`](../archive/findings/qa-beta-2026-07-07/reports/bindings-mutability.md) | Findings: bindings-mutability | — |
| [`numerics-strings-data.md`](../archive/findings/qa-beta-2026-07-07/reports/numerics-strings-data.md) | Findings: numerics-strings-data | — |
| [`patterns-control-flow.md`](../archive/findings/qa-beta-2026-07-07/reports/patterns-control-flow.md) | Findings: patterns-control-flow | — |
| [`playground-wasm.md`](../archive/findings/qa-beta-2026-07-07/reports/playground-wasm.md) | Findings: playground-wasm | — |
| [`test-gap-analysis.md`](../archive/findings/qa-beta-2026-07-07/reports/test-gap-analysis.md) | Test-gap analysis (area: test-gap-analysis) | — |
| [`tooling-cli.md`](../archive/findings/qa-beta-2026-07-07/reports/tooling-cli.md) | QA findings — tooling-cli | — |
| [`type-system.md`](../archive/findings/qa-beta-2026-07-07/reports/type-system.md) | Type-system findings (adversarial QA, 2026-07-07) | — |

### archive/ (flat) — closed conformance audits/roadmaps + the Phase archive

| Doc | What it is | Status |
|-----|------------|--------|
| [`DICT-CONFORMANCE-AUDIT.md`](../archive/DICT-CONFORMANCE-AUDIT.md) | Dictionary-Passing Conformance Audit | audit |
| [`DICT-CONFORMANCE-ROADMAP.md`](../archive/DICT-CONFORMANCE-ROADMAP.md) | Dictionary-Passing Conformance Roadmap | — |
| [`EFFECTS-CONFORMANCE-AUDIT.md`](../archive/EFFECTS-CONFORMANCE-AUDIT.md) | Effect-and-Capability Conformance Audit | audit |
| [`LAYOUT-CONFORMANCE-AUDIT.md`](../archive/LAYOUT-CONFORMANCE-AUDIT.md) | LAYOUT-CONFORMANCE-AUDIT.md | — |
| [`LAYOUT-CONFORMANCE-ROADMAP.md`](../archive/LAYOUT-CONFORMANCE-ROADMAP.md) | LAYOUT-CONFORMANCE-ROADMAP.md | — |
| [`PLAN-ARCHIVE.md`](../archive/PLAN-ARCHIVE.md) | Medaka — Plan Archive (Phases 1–145) | — |

