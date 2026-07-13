# Archived docs

Historical records that are **closed** and no longer living roadmaps. Kept for
provenance. Open work is tracked in [`PLAN.md`](../PLAN.md) (see its
**Open issues index**); the living specs are under [`../docs/`](../docs/).

## Layout

- **This directory (flat `.md` files below)** — the original conformance
  audits/roadmaps: closed records that narrate a past tree (paths as they
  were when written), not rewritten to match today's layout.
- **`design/`** — root design/plan docs whose status banner says
  **IMPLEMENTED** or **SUPERSEDED** (moved from the repo root in the
  2026-07-13 docs-tree reorg). Current docs, just archived because the work
  they describe shipped — their links ARE kept live/correct, unlike the flat
  files below.
- **`findings/`** — point-in-time QA/investigation sweeps, e.g.
  [`findings/qa-beta-2026-07-07/`](findings/qa-beta-2026-07-07/FINDINGS.md).
- **`PLAN-ARCHIVE.md`** — the completed-Phase archive (moved from the repo
  root). Like the flat files below, it narrates the compiler tree as it
  existed at each phase and is deliberately NOT rewritten.

## Flat historical audits/roadmaps

| Archived doc | Supersedes / closed by | Living spec |
|--------------|------------------------|-------------|
| `DICT-CONFORMANCE-AUDIT.md` | D1–D10 all closed (2026-06-21) | [`../docs/spec/DICT-SEMANTICS.md`](../docs/spec/DICT-SEMANTICS.md) |
| `DICT-CONFORMANCE-ROADMAP.md` | all WS closed; residual **Bug C** elevated to PLAN.md | [`../docs/spec/DICT-SEMANTICS.md`](../docs/spec/DICT-SEMANTICS.md) |
| `EFFECTS-CONFORMANCE-AUDIT.md` | E1–E4 closed; residuals (WS-3b/WS-5) live in PLAN.md Phase 146 | [`../docs/spec/EFFECTS-SEMANTICS.md`](../docs/spec/EFFECTS-SEMANTICS.md), [`../docs/design/EFFECTS-CONFORMANCE-ROADMAP.md`](../docs/design/EFFECTS-CONFORMANCE-ROADMAP.md) (still active) |
| `LAYOUT-CONFORMANCE-AUDIT.md` | no divergences; all findings closed | [`../docs/spec/LAYOUT-SEMANTICS.md`](../docs/spec/LAYOUT-SEMANTICS.md) |
| `LAYOUT-CONFORMANCE-ROADMAP.md` | WS-1/2/3/5/6/7 landed (2026-06-21) | [`../docs/spec/LAYOUT-SEMANTICS.md`](../docs/spec/LAYOUT-SEMANTICS.md) |
