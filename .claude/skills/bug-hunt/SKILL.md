---
name: bug-hunt
description: Adversarially hunt for lurking silent-wrongness (S0) and loud-breakage (S1) bugs in the Medaka implementation by fanning out isolated-worktree subagents across the hot subsystems, verifying every candidate first-hand, and filing deduped issues backed by self-draining pinned fixtures. Use when asked to stress-test / find bugs / "break" the compiler, and ESPECIALLY right after a batch of S0/S1s is closed — the adjacent ones hide next to the fixed ones.
---

# Hunting for lurking S0/S1 bugs

**The premise that makes this work:** the bugs cluster. Every closed S0/S1 sits next
to two more of the same shape that nobody probed — a fix for the definer case leaves
the importer case, a fix for `println` leaves `sum`, a fix for the array slice leaves
the polymorphic slice. "We just closed all the S0/S1s" is the single best moment to
run this, not the worst.

The yield in one run of this playbook (2026-07-18): **15 issues — 5 S0, 4 S1, 5 S2,
1 S3** — plus one closed issue reopened (its "(B)" half had never been fixed). Every
S0/S1 was a `check`-clean program that either produced a different value under `run`
vs the built binary, or shipped a crashing/heap-leaking binary at exit 0.

## The severity bar (Medaka's taxonomy)

- **S0 silent wrongness** — a wrong answer or corrupted output with **no error**. The
  canonical tell is **`run` value ≠ built-binary value at exit 0**. Also: a built
  binary that leaks heap / prints garbage at exit 0; a value that flips when you
  reorder declarations.
- **S1 loud breakage** — reasonable code that crashes/panics/segfaults, OR `check`/`build`
  exit 0 but the binary faults, OR `check` accepts a program `run`/`build` cannot execute.
- **S2 misleading** — wrong/absent/mislocated diagnostic, wrong trap *kind*, a message
  that names the wrong cause or leaks internal detail.
- **S3 friction & debt** — including untested behavior worth a regression fixture.

## Step 0 — run the differential fuzzer alongside the manual fan-out

`test/fuzz_diff.sh [START_SEED] [COUNT] [TIER] [BATCH] [NATIVE] [NATIVE_COUNT]` is a
complementary AUTOMATED pass, not a replacement for Steps 1-2: it generates
type-directed random well-typed programs (`compiler/entries/fuzz_gen_main.mdk`) and
checks invariants against the native-interp oracle at high volume. Its opt-in Tier-C
(`NATIVE=1`) additionally `medaka build`s each program and diffs the **native-compiled
binary** against the same oracle — mechanically hitting the exact run≠build S0 class
this skill hunts, for free, before you spend a subagent on it. Findings land in
`test/fuzz_failures/`; still run every candidate through Step 3's first-hand-reproduce
discipline before filing.

## Step 1 — derive the hot veins from the tracker (do NOT guess them)

The closed S0/S1 list *is* the map of where bugs breed. Read it first:

```sh
gh issue list --state closed --limit 80 --json number,title,labels \
  --jq '.[] | select([.labels[].name]|any(test("S0|S1"))) | "\(.number)\t\(.title)"'
gh issue list --state open --label "S0: silent wrongness"    # confirm the baseline
gh issue list --state open --label "S1: loud breakage"
```

The *pattern* of what broke recently names the subsystems to attack. The veins that
have paid out repeatedly (non-exhaustive — re-derive each time):

| Vein | Why it breeds bugs | Conformance oracle |
|------|--------------------|--------------------|
| **dict-passing / impl selection / overlap / constraints** | most-specific-wins + dict elaboration is subtle; enforcement is *occurrence-sourced not declaration-sourced* | `docs/spec/DICT-SEMANTICS.md` |
| **shadowing** (definer/importer, value/type, annotated/unannotated) | shadow × dispatch × arity is a large matrix; the corpus is always missing a cell | `docs/spec/SHADOW-SEMANTICS.md` |
| **lexer literals & escapes** (char/int/float/radix/unicode) | validation gaps: a literal that should be a lex error is silently accepted | `docs/spec/SYNTAX.md` |
| **emitter ordering / laziness** | native must refine `run`; top-level init order is a classic run≠build source | `docs/spec/EMITTER-SEMANTICS.md`, `compiler/EAGER-INIT-DESIGN.md` |
| **memory safety / OOB / slices** | wrong-container static dispatch reads foreign heap; `run` traps, `build` returns garbage | `docs/spec/EMITTER-SEMANTICS.md` §5 (trap totality) |
| **int / float / NaN** | totalOrder is sign-dependent; const-fold vs runtime NaN sign diverges | `docs/spec/language-design.md`, `compiler/SHARED-FLOAT-RESIDUAL-DESIGN.md` |
| **multi-module** | two ctor resolvers (typecheck global vs mangler per-unit) with opposite tie-breaks | `docs/spec/DICT-SEMANTICS.md` |
| **pattern matching / exhaustiveness / guards** | guard-exhaustion fallthrough emits the wrong trap; the `@mdk_oob` shape | `compiler/MULTICLAUSE-EXHAUST-DESIGN.md` |

**The `*-SEMANTICS.md` docs are the ground truth for "is this a bug and what is correct."**
`EMITTER-SEMANTICS.md` formalizes the **refinement contract**: `run` (the tree-walker)
is the reference semantics; native/wasm `build` must *observationally refine* it. Any
`run` ≠ `build` divergence is a contract violation regardless of design debates.

Effects/capabilities was probed and found **robust** (undeclared IO, higher-order
threading, laundering through a pure-arrow slot all correctly rejected) — a cleared vein,
worth re-confirming but not the richest.

## Step 2 — fan out one isolated-worktree subagent per vein

Spawn subagents with `subagent_type: general-purpose` and **`isolation: "worktree"`**
(the param — prompt text does NOT isolate). Cap at **3 concurrent** (shared box; heavy
builds). Run in waves; verify + file between waves so the box breathes.

Each agent's prompt MUST carry:

1. **Its vein + the matching `*-SEMANTICS.md` oracle** (say to read it).
2. **The closed-issue dedup list for that vein** — the exact shapes already fixed, so
   the agent pushes PAST them into the adjacent cells. Frame it: "find the ADJACENT
   still-lurking case; explain why it's distinct from closed #NNNN."
3. **The check/run/build triad** and the S0 tell (run ≠ build at exit 0). `run` is the
   oracle; the refinement contract is the yardstick.
4. **RUN-PROVE discipline** — every finding carries captured command output (probe
   source + literal check/run/build stdout & exit). No reasoning-only claims. "Disproving
   a hypothesis is SUCCESS — list dead ends."
5. **The diagnostic-quality addendum** — also surface any misleading/mislocated/uninformative
   diagnostic (S2) with the exact text.
6. **A fixed report format** (below) — the agent's final text is DATA for you, not prose.
7. **Harness cautions**: cold-bootstrap `make -C "$WT" medaka` (a fresh worktree has no
   emitter — that's FINE, ~31s–2min from `compiler/seed/`); **never borrow an emitter**
   from another tree (trips the isolation classifier, can kill the session); absolute
   paths (cwd resets between calls); `main = value` not `main () = …`; multi-arg lambdas
   `x y => body`; do NOT spawn sub-subagents; do NOT edit compiler source.

### Reusable agent report format

```
### F<n>: <title>  [S0/S1/S2/S3]
PROBE ("$WT/hunt/xNN.mdk"):
<minimal source>
check:  <stdout + exit>
run:    <stdout + exit>   (ORACLE)
build:  <stdout + exit of build then ./out>
EXPECTED: <what run gives + spec cite>
WHY / distinct from closed #NNNN: <...>
```
End with `DEAD ENDS:` (one line each). Rank most-severe first.

## Step 3 — YOU verify, dedup, and file (never let agents file)

Centralizing the filing is what keeps quality up and duplicates out.

1. **Reproduce every candidate first-hand** on your own built binary before believing it.
   *Never launder an agent's observation into your own inference* — run the probe, paste
   the output. A debunking needs the same proof as a filing.
2. **Dedup** with `gh issue list --state all --search "…"` per finding. Distinguish from
   the closest closed issue explicitly in the body. **Check the state of any issue you
   reference** — a closed issue whose bug still reproduces (the "(B) half never fixed"
   pattern) should be **reopened**, not re-filed; ask the user reopen-vs-refile if unsure.
3. **File** with `gh issue create --body-file` + severity/ws labels + `verified`. Read
   the issue back (`gh issue view`) — the write path can silently no-op. Never put a
   closing keyword (`fixes/closes #N`) in a body; it will close the referenced issue.
4. **Body shape**: verified-on-main evidence line; minimal repro with a three-engine
   table; a non-reproducing control; Expected + spec cite; "Distinct from #NNNN"; a
   "Suggested pin" section.

## Step 4 — self-draining pinned fixtures (`test/must_fail_fixtures/<N>-slug/`)

A fixture pins the CURRENT broken behavior; when the bug is fixed the fixture flips
RED and names the issue to close. Each dir: `main.mdk` (reproduces), `control.mdk` (a
near-identical CORRECT program — must exit 0, and if `check-json`, be diagnostic-free),
`claim.txt`. Supported verbs: **`check` / `check-json` / `check-types` / `run` /
`fmt-write`** — there is **NO `build` verb** (issue #590), so a pure silent `run`≠`build`
at exit 0 is *not* pinnable here; note that dependency in the issue and use the
`diff_compiler_engines` corpus (eval == native) instead.

Which shape pins where:
- **"check wrongly accepts"** (should reject) → `cmd: check main.mdk`, `exit: 0`. Drains
  when check learns to reject (exit 1). `exit: 0` claims ARE supported (several exist).
- **"run produces a wrong value"** → `cmd: run main.mdk`, `exit: 0`, `stdout: <wrong value>`.
- **"a valid program is wrongly rejected"** → `cmd: check-json main.mdk`, `exit: 1`,
  `diag-code: <CODE sl:sc-el:ec>` (message-agnostic; use `diag:` only when the *wording*
  is the bug). Control = the valid variant.
- **build-crash / segfault** (shadow value-position class) → the `test/shadow_fixtures/`
  gate has a `BUILD_CRASH` verdict (see `d18`); mirror it for the missing cell.

`claim.txt` fields: `issue:`, `what:` (multi-line ok), `cmd:`, `exit:`, optional
`stdout:`/`stdout-line:`/`diag:`/`diag-code:`, `control:`, `why-control:`. Validate before
committing: `sh test/diff_compiler_must_fail.sh 2>&1 | grep '<your-slug>'` must print
`REPRO` (not MALFORMED / CONTROL-BROKE). See `test/diff_compiler_must_fail.sh` header and
`docs/ops/TESTING-DESIGN.md` §4.5.

## Step 5 — independent reviewer + summary

Spawn a fresh (non-fork) reviewer agent over the filed issue numbers: check each has the
right severity/ws labels, a clear reproducing body, a correct distinct-from, and is not a
duplicate. Then give the user a high-level summary (counts by severity, the systemic root
causes, and recommendations) — the filed issues are the real deliverable; relay what matters.
