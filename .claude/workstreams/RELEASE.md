# Workstream: RELEASE — the 0.1.0 public preview 🚢

**Owns:** shipping Medaka to strangers.
**Touches:** `docs/`, packaging, `playground/`, `.github/workflows/` (release matrix).

```sh
gh issue list --milestone "0.1.0 public preview"
```

**Hub:** [`docs/ops/RELEASE-0.1.0-PLAN.md`](../../docs/ops/RELEASE-0.1.0-PLAN.md) ·
**Packaging:** [`docs/ops/DISTRIBUTION-DESIGN.md`](../../docs/ops/DISTRIBUTION-DESIGN.md)

---

## Soundness outranks release — but the two are not independent

Decided 2026-07-14: **the preview ships on a compiler you can trust, or it does not ship.** An `S0`
beats a release item.

That is not a delay tactic. Three of the release items are *gated on soundness work anyway*:

- **The playground (#75) runs on wasm**, which has **7 confirmed codegen bugs** (#60) and cannot emit
  a partially-applied constructor (#59). Polishing a front door on top of a backend that traps is
  wasted work.
- **`KNOWN-GAPS.md` (#73) is a curation of the `S0`/`S1` labels.** It cannot be written before the
  list settles — and every bug fixed is a line that never has to be written.
- **The audience bar decides everything else.** `RELEASE-0.1.0-PLAN.md:254` asks Val to confirm:
  *"HN/Reddit strangers who'll try to break it"* vs *"a dozen personally-invited people."* Under the
  first, the recursion-depth segfault (#77) is a blocker; under the second it is a footnote. **Nothing
  else can be sized until this is answered.**

---

## The critical path is a HUMAN, not an agent

**W3 — the quickstart — is "the serialization bottleneck of the whole launch"** (#73). It is
Val-authored and cannot be delegated. Everything else on this list can be picked up by an orchestrator.

**Start it early, in parallel with the compiler work.** If it starts last, it *is* the launch date.

---

## The funnel

**playground (front door) → native download.** A stranger tries Medaka in the browser without
installing anything; if they like it, they install a binary. Both halves have to work, and the
playground half runs on the weaker backend.

---

## Floor vs ceiling

| | |
|---|---|
| **FLOOR** (cannot ship without) | quickstart · `KNOWN-GAPS.md` · stdlib reference docs · native binaries for mac + Linux · `--version` · a license |
| **CEILING** (makes it land well) | polished playground · `.vsix` · showcase programs · release CI matrix · crash→report path |

**Already done — do not redo:** W6 LICENSE (Apache-2.0, `d94bae5f`) · D1/D2 distribution tracks ·
`medaka --version` (verify + close) · the error-message quality freeze (its one listed exception —
warnings without `file:L:C` — **is fixed**).

⚠️ **W5 ("create a separate public repo") may already be satisfied**: `MedakaLang/medaka` *is* public,
Apache-2.0, CI green. Check before doing the work.

---

## ⚠️ The dual-platform invariant

**Every build/test script must run on BOTH Linux and macOS.** Primary dev is an x86_64 Debian box; the
Mac is retained for macOS smoke-testing and there is no alternative. When you touch a script, keep both
arms alive — `stat -c %Y` *or* `stat -f %m`; `pkg-config`/`-lgc` *or* `brew --prefix bdw-gc`; no
Mach-O-only link flags.

Two platform facts worth not rediscovering:

- The emitted LLVM IR carries **no target triple**, so the checked-in seed cold-bootstraps on x86 *or*
  arm from the same bytes. Do not "fix" that by adding one.
- The deeply-recursive compiler gets its stack from a **256 MB GC-aware worker pthread** spawned in
  `runtime/medaka_rt.c`, not a link flag — so it runs fine under Linux's default 8 MB `ulimit -s`.
</content>
