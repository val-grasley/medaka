# ORCHESTRATING.md — a guide to being the orchestrator

You design and delegate work to subagents, verify their output, and keep the project's docs/state
coherent. You usually do **not** implement directly. Your durable value: framing precise tasks,
judging results, holding the thread across many agents. **Living guide — append learnings as the
pattern recurs.**

Companion docs: `AGENTS.md` (agent-facing router) and the per-task **skills** in `.claude/skills/`.

---

## 🚦 `main` IS PROTECTED. YOU CANNOT PUSH TO IT.

`git push origin main` fails with `GH013: Repository rule violations`. **No admin bypass** —
protection you can bypass is theatre.

```sh
git checkout -b <topic>          # never commit on main
# ... work, verify ...
git push -u origin <topic>
gh pr create --fill
gh pr merge --auto --merge       # enqueues; the merge queue does the rest
```

**Nine required checks:** the six `gates (…)` shards, **`soundness`**, `seed-health`, `inlang`. Zero
approvals — the *checks* are the gate, not a human, so an agent can self-merge on green.

**`soundness` is required ON PURPOSE and must never be dropped.** It runs the compiler-source
typecheck + the self-compile fixpoint. **Every gate passes on an ill-typed compiler** (the build does
not gate on type errors) — which is how a compiler with unbound constructors once shipped to `main`
with every shard green.

### ✅ There is a MERGE QUEUE. Do not hand-manage staleness.

The repo is in the **MedakaLang org**; the queue is **ON** and replaced `strict` mode. It builds a
temp branch of *your PR merged onto current `main`, plus everything queued ahead of you*, runs all
nine checks **on that**, and merges only if green — the guarantee `strict` crudely approximated, and
the reason branch-only CI is not enough (two branches both touched `typecheck.mdk`, auto-merged fine,
and their **goldens** diverged → `main` red). It batches up to 5 entries per run (`ALLGREEN`: a bad
PR fails its group and is bisected out; 5-min window; a lone PR never waits). Config:
`merge_method=MERGE`, `grouping_strategy=ALLGREEN`, batch 1–5, 60-min check timeout. **`ci.yml`'s
`merge_group:` trigger is what makes the checks run on the queue's temp branch — without it the queue
deadlocks. Do not remove it.**

**`strict` is OFF deliberately.** With a queue it is redundant *and harmful*: it forces every open PR
to rebase onto every merge and re-run all nine checks — the O(N²) tax the queue exists to delete.
(The day we enabled the queue: 13 merges in one hour across three orchestrators; under `strict` one
PR paid five full 20-minute suites without landing.)

**So stop doing all of this:** `update-branch` kicks (also **impossible** on any PR touching
`.github/workflows/` — `gh`'s OAuth app lacks `workflow` scope, the call 403s); watching for
`BEHIND`; batching unrelated PRs onto one branch to save CI runs. **The ONLY remaining reason to
batch is DIAGNOSIS:** if two changes are so entangled that a red result would not name the culprit,
they belong together — otherwise keep them separate.

What the queue still **cannot** catch: two semantically incompatible changes that merged cleanly and
are now both wrong. See "A clean auto-merge is NOT agreement."

---

## The core loop

```
scope-read (bounded) → frame a precise prompt → get approval → spawn (bg, isolated worktree)
  → VERIFY empirically → open a PR → CI green → merge → reconcile docs/tasks/memory → next
```

- **Bounded scope-read.** Read just enough to write a precise prompt + STOP guardrail. Targeted
  `grep`/`sed` of specific functions, not whole-file reads. For a broad census/taxonomy, **delegate to
  an Explore agent** and keep only its conclusion — don't fan the reads through your context.
- **Approval before spawn.** Present each agent's prompt + model; get an explicit OK. Surface genuine
  design decisions as questions (you're a design collaborator, not a dispatcher). Once pre-approved
  for a class of work, chain without re-asking — but pause when an agent trips a guardrail.

---

## 🎯 The backlog is GITHUB ISSUES. The workstream docs are the domain knowledge. (2026-07-14)

```sh
gh issue list --label "S0: silent wrongness"      # always start here
gh issue list --label "ws:soundness" --state open # one workstream
gh issue list --label "needs-repro"               # claims NOBODY has reproduced
gh issue list --milestone "0.1.0 public preview"  # the release floor
```

**Severity:** `S0: silent wrongness` (a wrong answer, or destroyed source, **with no error**) →
`S1: loud breakage` → `S2: misleading` → `S3: friction & debt`.
**Workstream:** `ws:soundness|language|tooling|wasm|diagnostics|testing|release|perf|stdlib`.
**Evidence:** `verified` (repro run at a stated SHA) vs **`needs-repro`** (nobody has reproduced it).
**S0 beats everything, and soundness beats release.**

### Why it moved — this is the #1 lesson, applied to itself

The backlog used to be markdown lists across `PLAN.md`, `HANDOFF.md`, `workstreams/*.md`, and the
gap docs, each carrying an instruction to *"keep this in sync when an item opens/closes."* **It was
not kept in sync — and it could not have been, because nothing forced it.**

Re-deriving every claim against the binary (2026-07-14, `e34e2b46`) found **six entries already
fixed**, including *both* "silent build miscompile" P0s the roadmap was advertising, a
duplicate-definition **segfault**, a "fabricated `1:0` source location" that would not reproduce, and
a `newtype` bug billed as *"the best value-to-risk item on the board"* — which works.

**An issue self-drains: closing it removes it from the backlog. A markdown row has to be
remembered.** That is the entire argument, and it is the same one as *DERIVE, don't encode* below.

Two failure modes worth naming, because both were invisible while the backlog was scattered:

- **The worst bug in the tree hid by being filed three times.** `fmt --write` destroying source, a
  "scientific-notation float literal" *parser gap*, and a `1e12` must-fail row were **one defect** —
  the lexer has no exponent form, so it cannot read the float the printer writes. Three docs, three
  owners, nobody holding the whole shape.
- **An S0 sat unranked in a housekeeping list.** `Int` silently wraps at 63 bits, filed as "P1-1"
  among *remaining TODOs*. **Severity has to be a label you can sort by, not an adjective in prose.**

### The workstream docs (`.claude/workstreams/`) are NOT the backlog

They hold what does **not** belong in an issue and would rot if scattered across 34 of them: the
**traps**, the **collision map**, and **why each bug class recurs**. Read the one matching your labels
*before* you spawn anything.

**COMPILER-SOUNDNESS** · **LANGUAGE** · **TOOLING** · **WASM** · **DIAGNOSTICS** · **TESTING** ·
**RELEASE** · **PERF** · **STDLIB** · **HARNESS**.

`workstreams/README.md` carries the **collision map** — read it before running two orchestrators in
parallel. The unit of collision is a **file**, not a topic: TESTING (`test/`) and RELEASE (`docs/`) are
safe alongside anything; SOUNDNESS/LANGUAGE/DIAGNOSTICS all live in `compiler/frontend/` + `types/` and
should be run **one at a time**; `stdlib/core.mdk` is the **prelude**, so it moves every golden and must
land **alone, at a checkpoint**.

---

## Agents do NOT run the full suite — CI does

The full suite is CI's job: six parallel hosted runners, free. Locally it costs the *shared box* — one
agent running all the gates plus a 54-binary oracle build pushes load average past 10 and turns
everyone else's 30-second gate run into minutes. That has happened repeatedly.

```
agent:        make preflight        # targeted: builds + runs ONLY what the diff touches
              commit on its own branch, REPORT THE SHA
orchestrator: verify → push → open a PR → CI runs the FULL suite → merge ONLY on green CI
```

The mechanics are in `AGENTS.md` (`make preflight` / `build_oracles.sh --for` / `make test` vs
`make gates`). What you need to enforce: **preflight derives its gate set from the diff and its oracle
set from those gates** — a `parser.mdk` change builds 9 oracles and runs 11 gates, not 54 and 82 — and
that derivation comes from the gate *scripts* themselves (each names its oracle as `test/bin/<name>`),
so **there is no hand-maintained map to drift**; CI shards and `preflight.sh` share it.

A full local run is justified only for: a `compiler/backend/*` change (preflight forces the fixpoint
there anyway — it is decisive and CI is too late); a `compiler/support/*` or `stdlib/core.mdk` change
(blast radius is everything); a merge of two branches touching one subsystem; a CI failure you cannot
reproduce.

### ⚠️ THE PREFLIGHT IS A FILTER, NOT AN AUTHORITY

Green preflight = *the gates most likely to notice your change did not break*. Nothing more. **CI on
the PR is the authority. Never merge on a green preflight.** A targeted local run re-introduces the
exact hazard the testing overhaul exists to kill — **a suite reporting green while testing less than
it appears to** (`diff_compiler_lint_multi` sat "skipped" for months, *while also failing*, because
dash couldn't parse it and exit 2 counted as SKIP; a fresh clone once ran **zero tests and printed "0
failed"**). So `preflight.sh` **ends by printing what it did not run**, and must stay loud.

### The orchestrator OWNS red CI — watch it, don't wait to be told

**Arm a persistent background `Monitor` on CI as soon as you push** (poll `gh run list --limit 15
--json databaseId,status,conclusion,headBranch`; emit a line for every newly-terminal run and list the
failed jobs). A CI failure nobody watches is a slower version of no CI. ⚠️ **Emit on every terminal
state, not just failures** — a monitor that greps only for red is *silent* through a cancel, a
timeout, or a crashloop, and silence is indistinguishable from "still running." Seed the seen-set with
already-completed runs at arm time.

When CI goes red, **act, don't just report**:

1. **Diagnose from the log** (`gh run view <id> --log-failed`): infra/workflow bug, real regression, or
   already-known red?
2. **Fix it yourself if it is small and mechanical** — a bad glob, YAML quoting, a stale golden, a
   misnamed make target, a missing `chmod +x`. Don't spawn an agent to change three characters. (Real:
   a shard pattern using brace expansion dash cannot expand; `pattern: 'a' 'b'` invalid YAML;
   `make test` secretly running the whole gate suite.)
3. **Re-spawn the responsible agent** when the failure is inside work it just did — paste the CI
   failure, add a STOP guardrail. Don't "fix" an agent's logic for it; you'll lose its context.
4. **Record known-red ONLY with a ledger entry that detects an accidental fix.** Never a bare skip: a
   skip-list cannot notice when the bug is fixed, so it rots (this is how `test/ported/` died).

### Branching off an UNVERIFIED base — a judgment call, not a rule

CI is minutes and agents are cheap, so waiting for green before every spawn serializes what you just
parallelized. **You MAY branch off a base whose CI is still running** — price it: *"if this base turns
red, what does it cost me?"*

- **Cheap to be wrong (branch freely):** the work is **disjoint** (different files/subsystem), so a red
  base gets fixed *underneath* it; the uncertainty is in **docs/CI-config/gate-script**, not the
  compiler; the work is **additive new files**; preflight was green; the fixpoint +
  `typecheck_compiler_source` passed; or CI already went green on an earlier commit of the branch.
- **Expensive (WAIT):** the work **builds on** the uncertain change (a red base voids its premise — the
  work is *discarded*, not rebased); the base moved **goldens or the seed**; you'd have to re-derive a
  **diagnosis**, not re-apply a diff. High-risk signals: emitter/`Value`/dispatch touched, a shard
  already red, or a change an agent reported and you never verified.
- **The escape hatch nobody remembers: branch off the last KNOWN-GREEN SHA**, not the tip. Parallelism
  *and* a verified base; cost is one merge later. Strictly better than waiting or gambling.

⚠️ **If you branch off an unverified tip, SAY SO in the prompt.** A STEP-0 `BASE_OK` assert proves
*ancestry*, not *correctness* — it passes happily on a base CI is about to reject. An agent that knows
its base is provisional STOPs and reports instead of "fixing" your bug and tangling the two changes.

### CI shape

`.github/workflows/ci.yml`, GitHub-**hosted** runners (free + unlimited on a public repo). **No
self-hosted runner** — a fork PR on a public repo with one is arbitrary code execution on the host.
Sharded: 6 gate shards + `inlang`, each cold-bootstrapping from the seed and building only its own
oracles. Every `diff_compiler_*` gate is in **exactly one** shard (one falling between shards would
silently never run; `diff_compiler_ci_shard_coverage.sh` proves it). Each shard ends with a **review
gate** (`git diff --exit-code`) on the tree its gates just ran over — it cannot be a separate job,
because a fresh checkout in a fresh VM would never see the drift.

---

## ⭐ DERIVE, don't encode — and where you can't, make it SELF-DRAIN (2026-07-13)

This is the unifying lesson of the docs overhaul, and it generalizes far past docs.

**Every defect was one shape: a statement that ENCODED a fact about the code, and the code
moved.** `SYNTAX.md` encoded "backtick infix parses" (true once). `AGENTS.md` encoded "grep for
`checkGuardExhaust`" (existed once). A skill encoded "insert into `primitives`" (existed once).
The CI classifier encoded "nothing outside `test/` reads a `.md`" — **true when written, false
within hours.** A memory encoded "prefer list comprehensions" (removed in June).

**A document is an allowlist of facts about the world, with no derivation and no expiry.** That is
the disease, and *tidying does not treat it.* In priority order:

1. **DERIVE the fact instead of stating it.** `docs/README.md` is now GENERATED from the docs'
   `**Status:**` banners and CI regenerates + diffs it. The shard-coverage gate derives the gate set
   from the gate *scripts* — no map to drift. A hand-maintained index is what rotted in the first
   place.
2. **Where you must encode, ATTACH A DERIVATION.** A status banner cites the **SHA** that proves it
   (`**Status:** IMPLEMENTED — 9100df2e, 2026-07-01`). A claim with a receipt is auditable; a claim
   without one is a fact waiting to expire. It also turns archive-vs-keep into a *filter*, not a
   judgment call.
3. **Where you cannot derive, make it SELF-DRAIN.** An exceptions ledger must FAIL the build when an
   entry stops earning its place — **both** when the excused thing came back **and** when nothing
   cites it anymore. Half a ratchet is a skip-list, and **a skip-list cannot notice when the bug is
   fixed, so it rots** (this is how `test/ported/` died). The doc-link gate shipped with only the
   first half and had **3 orphaned entries within one merge.**

> **⭐ The BACKLOG was the biggest un-drained ledger of all (fixed 2026-07-14).** A markdown bug list
> is *exactly* the disease this section describes: a statement encoding a fact about the code
> (*"this is broken"*), with **no derivation and no expiry**, and a footnote politely asking humans to
> keep it in sync. They didn't — **six entries were dead**, two of them labelled *silent build
> miscompile*.
>
> **A GitHub issue is the self-draining form of a bug report: closing it removes it from the
> backlog.** There is no separate act of remembering, so there is nothing to forget. Severity, owner,
> and evidence are **labels you can sort by** — not adjectives buried in prose, which is how an S0
> (`Int` silently wraps at 63 bits) spent weeks in a list called *"remaining TODOs"*.
>
> Same shape, one level up: **`sqlite/findings/verify_compiler_bugs.sh` is the model.** The bug list
> ships with a script that **re-runs every repro and prints OPEN/FIXED** — the list cannot lie for
> longer than it takes to run it. That script is the only reason we *know* four of those bugs were
> fixed. **Every bug corpus should ship its own verifier.**

### 🔴 The lazy fix hides the real bug

Three times in one session, **refusing to "just add an exception" exposed a genuine defect**:

- adding the ledger's *orphan* half → 3 entries were already fiction;
- refusing a blanket `archive/*` exception → found that a POSIX `case` glob **`*` matches across
  `/`**, so it was silently swallowing 10 dead links two directories deep;
- refusing to excuse `gen_docs_index` from shard coverage, and making it a real check instead →
  caught that **`sort` is locale-dependent** and the "generated" index produced **different bytes on
  the dev box and the CI runner**. A generated artifact that isn't byte-reproducible is a
  hand-written one with extra ceremony.

**If your first instinct is to excuse a check, that is where the bug is.** Corollary: *a gate that
has to excuse its own false positives is a gate with a parsing bug* — fix the parser, not the ledger.

---

## A gate must RUN where the bug lands — ask "where is this skipped?" FIRST

Writing the gate is the easy half. **Placing it is where it dies.**

`ci.yml`'s `detect` job sets `docs_only=true` for prose-only PRs, and every heavy job skips its
steps when it is true. So **a docs gate placed in a gate shard is skipped on docs-only PRs — exactly
the PRs it exists to police.** Green forever, checking nothing. That is the silent-green bug the
whole suite exists to prevent, reproduced *inside the tool built to prevent it*. It nearly shipped
twice.

- **Text-only gate that must run on prose PRs** → an **UNGUARDED step in an already-REQUIRED job**
  (`soundness`). No compiler needed, so it is nearly free — and being in a required job means it
  gates on merge *today*, with no repo-settings change.
- **Gate needing a built `medaka`** → a gate shard. But then **its INPUT must be reclassified as
  not-docs-only**, or a change to that input skips the gate. Hence `SYNTAX.md) docs_only=false` —
  it is an *executable spec*, not prose.
- **A gate matching no shard pattern silently never runs.** `diff_compiler_ci_shard_coverage.sh`
  catches this — and it caught me.

Before adding any gate: **(1)** where is this skipped? **(2)** is the class of bug it catches exactly
the class of change that triggers the skip? **(3)** have you *seen it fail* — broken something on
purpose and watched it name the `file:line`? **(4)** can it no-op? Print `checked N …`; **N == 0 must
be a FAILURE, not a pass.**

---

## The gap docs lie — reproduce before you trust them (the #1 lesson)

**EVERY LAYER LIES ABOUT THE LAYER BELOW IT:** the router lied about the language (AGENTS.md
recommended three constructs that are hard parse errors); the skills lied about the code (**5 of 6
were DANGEROUS**; `harden-typechecker` taught `pushTypeError` at the wrong arity, which *silently
drops the error*, and its "grep these names" index was **19/20 fictional**); the memories lied about
the docs; **and the shared binary we check the docs against lied about `main`** (it rejected valid
current syntax). None of it was findable by *reading*. It only fell out when something was forced to
**execute** each claim against the code.

### ⚠️ And an AUDIT is not evidence either — it will FABRICATE

A read-only **Opus** auditor correctly found ~35 false claims in the skills — **and then invented its
own replacements**, asserting that `registerImpl`, `ppMonos`, `implEntry`, `registerRecord` "**do**
all exist." Four of five return **ZERO hits.** An agent executing that punch-list on trust would have
replaced 19 dead symbols with 4 fresh dead ones — *with an audit's authority behind them.*

It was caught only because the fix agent was **required to grep-prove every symbol it wrote and paste
the evidence.** So: **never let an agent execute an audit's punch-list on trust.** And ⚠️ note
`grep -r compiler/` also matches the `.md` docs living there, so a fabricated symbol *appears to
resolve* — resolve symbol claims against **`.mdk`/`.c` source only**.

### The gap/status docs drift faster than anyone updates them

One gap doc mispredicted on **every** contact: items marked OPEN were already closed (sometimes
incidentally, by an unrelated fix), items marked CLOSED were still broken, and the documented root
cause was wrong ~every time.

> #### 📊 Re-measured 2026-07-14 — the drift rate is roughly **1 in 5, and it favours "already fixed"**
>
> Rebuilding the whole backlog by executing every claim against `e34e2b46` found **six dead entries**:
> `B2` and `B3` (**both billed as *silent build miscompile* P0s** — the scariest label we have), `B4`,
> `T30` (a **segfault**, per the doc), `T20`'s "fabricated `1:0` location" (**would not reproduce on any
> error shape**), and `#31` — `newtype` "entirely unusable", advertised as *"the best value-to-risk item
> on the board"*. It works. An orchestrator who trusted that ranking would have spent a session
> re-fixing a working feature.
>
> **The bias is important: stale entries skew toward *already fixed*, not *still broken*.** Bugs get
> fixed incidentally by adjacent work far more often than docs get updated. So the default failure mode
> is **aiming a good agent at a dead bug** — which costs a session and produces a confused PR.
>
> Two structural lessons, both now enforced by labels:
>
> - **A claim nobody has reproduced must not look like a known bug.** Every issue is stamped `verified`
>   (repro run at a stated SHA) or **`needs-repro`**. `needs-repro` is a *lead*, not a fact. **Closing
>   an issue as already-fixed is a GOOD outcome** — say so in the PR and delete the ledger rows citing
>   it.
> - **A bug filed in three places is invisible in all three.** `fmt --write` destroying source, a
>   "scientific-notation float literal" *parser gap*, and a `1e12` must-fail row were **one defect** —
>   the lexer has no exponent form, so it cannot read the float the printer writes. No single doc owned
>   enough of it to see the shape. **One tracker, one item, one root cause.**

### ⚠️ Check the SET, not one member — a plural noun in a backlog item is a claim about a set

An item that says *"the four X's"*, *"the warnings"*, *"both backends"*, *"the whole tree"* is a claim
about a **set**. **Enumerate it and check every member, or narrow the claim to what you actually ran.**
Reporting N after verifying 1 is worse than not verifying: it *retires the question*.

It happened here, to this very doc set: *"W-errors has no remaining exception — **it is fully
frozen**"* was written after checking the non-exhaustive-**match** warning and generalizing. The
**guard** warning still fabricates a `0:0` location (#99). The edit turned a hedged doc into a
confidently false one, stamped `verified`.

Same disease as *"a one-backend fix is a half fix"* (#59) and *"a parity gate cannot see a bug where
both backends are equally wrong"*. **The unit of verification must be the unit of the claim.**

- **Reproduce a "known gap" on current main before you scope or spawn a fix.** A throwaway repro
  (`run` = oracle, `build` + run = native, compare) takes a minute and repeatedly saved an Opus agent
  from being aimed at an already-closed gap.
- **Expect symptoms to SHIFT as upstream layers close** — one bug went "panic" → "garbage output" →
  "SIGSEGV one layer deeper" across successive fixes. Re-scope on what the binary does *now*.
- **Bake DIAGNOSE-FIRST into every route-fragile prompt:** *"the filed root cause is a starting point,
  almost certainly stale; trace it on current main; STOP and report if the probe disproves it."* A
  clean STOP-with-a-correct-diagnosis is a **success**.
- **A landing often closes adjacent gaps** (universal ctor mangling alone closed three parked gaps and
  mooted a fourth) — re-verify the set after a merge, before spawning the next agent.
- **"Fixed" can be TRUE and MISLEADING — a one-backend fix is a half fix.** A partially-applied-ctor
  miscompile was fixed in the LLVM emitter and never reached WasmGC. The verifier said FIXED
  (correctly!), so I reverted the library's workaround, re-verified under native `build` — all green —
  and was one command from merging a library that **silently no longer compiled to wasm**. Only the
  wasm tandem gate caught it. **Re-verify a fix on every target the code actually ships to.**
- **A spot-check is not a diff.** I "verified" overflow-page reads by sampling a patterned payload;
  every sample matched. The path was **silently corrupting data** — my 1000-char pattern blocks hid a
  4-byte shift. An agent's byte-level `cmp` caught it (diverged at byte 1817) and overturned a
  "verified fact" I had already told the user. **For data fidelity compare bytes, not samples** — and
  bake "disprove my premises" into prompts (it fired three times in one session, always against me).

Run this as a **verified audit before any milestone**: fan out read-only agents by domain that
REPRODUCE each claimed item (don't recite the doc). It catches both directions —
already-fixed-but-marked-open *and* marked-closed-but-actually-broken.

---

## The agent-prompt skeleton

### 🔴 Five lines that stop agents dying — put these in EVERY prompt (2026-07-13)

Each is a failure actually watched happen this session:

1. **"Do NOT spawn sub-agents / forks. Sequential, yourself."** An agent given a 40-file census
   **fanned out to sub-forks, then ended its turn waiting on one** — producing nothing. The harness
   re-invoked it and it said *"I'll wait for the batches"* **forever**. Nested forks also fail with a
   *misleading success signal* (`Fork is not available inside a forked worker`, while one still
   reports success and produces nothing). **Remedy: `TaskStop <agentId>` FIRST**, or it respawns.
2. **"APPEND each result to disk as you finish it. Never buffer for a final write."** If it dies
   halfway you want half a census on disk, not zero.
3. **"NEVER end your turn with anything still running"** + **"Do NOT build."** A docs/audit agent has
   no reason to run `make medaka` or `build_oracles.sh` (the latter spawns an `xargs -P` pool that
   **outlives the turn and gets RESPAWNED**). Say: *"this is pure text analysis; it needs no
   compiler — keep it that way."*
4. **"GREP-PROVE every symbol and path you write. Paste the proof."** `test -e <path>`, and
   `sed -n '<line>p' <file> | grep <sym>` — at the **exact cited line**, not "exists somewhere." *If
   you cannot verify it, DELETE the claim rather than guess.* **This is the single highest-value line
   in any prompt** — it is what caught the Opus auditor fabricating symbols.
5. **"Disproving me is a SUCCESS."** Say it explicitly. It fired **three times in one session**, every
   time against the orchestrator. An honest `UNVERIFIED` beats a confident wrong answer.

### 🎯 A sixth, now that the backlog is issues: **"REPRODUCE THE ISSUE BEFORE YOU FIX IT."**

Hand the agent an **issue number**, not a paraphrase — the issue carries the repro, the evidence
stamp, and the source citations, so there is no game of telephone. Then put this in the prompt:

> *"Start by running the repro in issue #N against the current binary. If it does NOT reproduce, STOP
> and report that — closing an issue as already-fixed is a **success**, not a failed task. Six items on
> this backlog turned out to be already fixed."*

Without that line an agent will *implement a fix for a bug that no longer exists*, and — because it
cannot see the bug — will "fix" something else to make its change look justified. **The
`needs-repro` label exists precisely so you can tell an agent which issues are leads rather than
facts.** When it lands, have the agent flip the label to `verified` (with the SHA) or close it.

⚠️ Also: **`git merge main` SILENTLY NO-OPS** when another worktree has `main` checked out (very
likely with several agents live). Tell agents **`git merge origin/main`**.

Every delegated task prompt should contain, in order:

1. **One-line project framing** + the task.
2. **STEP 0 — sync + VERIFY BASE:** `git merge origin/main --no-edit` first (never bare `git merge
   main`), then `git merge-base --is-ancestor <tip-SHA> HEAD && echo BASE_OK || echo BASE_STALE` —
   must print `BASE_OK`, else STOP+report. (An agent once silently built Phase 5 on a base missing two
   prior phases; a redo was needed.)
3. **Environment rules:** how to build (`make -C <worktree> medaka`), the no-`eval`/PATH quirks, the
   `perl -e 'alarm N; exec @ARGV'` timeout shim.
4. **Context (verified facts):** the root cause + `file:line` pointers you already confirmed, and the
   precedent to mirror. Hand the agent the map, not a treasure hunt — this is where your bounded
   scope-read pays off.
5. **The task**, with latitude where the approach is uncertain.
6. **Gates:** exact commands + expected numbers. Rebuild `./medaka`, and prefix any `test/bin/*` gate
   with `FORCE=1 bash test/build_oracles.sh` (see Failure modes: stale-binary footguns).
7. **STOP guardrail:** *"if the probe disproves the hypothesis / the fix balloons / a design decision
   appears, STOP and report with options — do NOT force the prescribed fix."* Scope hypotheses are
   often wrong; make stopping safe and cheap.
8. **Output discipline:** commit on its own branch, REPORT the SHA, do NOT merge to main, don't re-mint
   expensive artifacts, and **stage BY PATH — never `git add -A`**.
9. **Report-back contract:** *"your final message is the ONLY thing I see — be self-contained, WAIT for
   gates and report real numbers, never end with background tasks running."*
10. **A friction report** (below).

---

## Every agent prompt MUST demand a FRICTION REPORT

> **Surface everything that fought you** — any bug, gap, missing feature, workaround you had to invent,
> misleading error message, stale/wrong doc, or surprising behavior — **even if you worked around it
> and even if it is unrelated to your task.** If you did something ugly to make progress, say what and
> why. If an error message sent you down the wrong path, quote it. A clean report that hides three
> workarounds is worse than a messy one that names them.
>
> **Explicitly include MISSING STDLIB FUNCTIONS.** Did you hand-roll a helper `stdlib/` didn't have,
> reach for something obvious by name and find it absent, or write the same three-line utility twice?
> **Name it** — what you wanted, what you wrote instead, and where.

**Why this is not optional.** Agents are extremely good at *routing around* problems and never
mentioning them, and everything they route around is a bug the user hits later with less context. This
session agents silently worked around: `medaka run` unable to read `args`; `import … as` not parsing
despite SYNTAX.md advertising it; `emitProgram` name-colliding across two backends; `/bin/sh` being
dash so a gate could not even be parsed. **Every one was a real, filed-worthy defect that surfaced
only because an agent happened to mention it in passing.**

**The orchestrator TRIAGES the report.** Per item: reproduce it (the gap docs lie), then fix it, file
it in the backlog / `PLAN.md`, or record it as a known-red ledger entry with accidental-fix detection.
**Do not let it evaporate.** A stdlib gap found by USE comes with a real call site attached — worth far
more than one found by planning.

---

## Review every agent PR before merging

An agent's own report is a claim, not a review. After CI is green, spawn a **Sonnet reviewer** over the
diff (playbook: **`.claude/skills/pr-review/SKILL.md`**). Keep it READ-ONLY — it reports; you decide;
the *authoring* agent fixes (it has the context). **Gates prove *behavior*; the reviewer judges
*craft*.** Green CI on a bad diff is still a bad diff.

It has twice returned **do-not-merge** on a diff whose own gates were green, both times on this repo's
#1 bug class (check green / run dies) — e.g. import aliasing left an aliased *interface method* unbound
(`check` 0 diagnostics, `run` E-PANIC, `build` emitter failure), and the author's regression fixture
**tested the bug it fixed, not the feature it shipped**.

---

## ⚠️ A clean auto-merge is NOT agreement

**A clean `git merge` proves only that two changes did not touch the same LINES. It says nothing about
whether they agree.** Two agents changed the LLVM emitter in parallel; git flagged 2 conflicts and
cleanly auto-merged a **third break it could not see** — TMC had added a brand-new caller
(`emitGDispBody`'s `CDecision` arm) into the very machinery whose signature the other change was
rewriting (single scrutinee word → `roots : List String`). No conflict; the merged tree **crashed**. A
reviewer caught it, not git and not either author.

When two branches touch one subsystem:

1. **Do NOT resolve a semantic conflict yourself.** Hand it to the authoring agent — it knows what the
   code must *mean*; you know only what the lines look like. A wrong resolution in an emitter is a
   **silent miscompile**, not a build error.
2. **Grep the merged tree for every CALLER of any signature that changed** — not just the ones that
   conflicted. That is where the invisible break lives.
3. **Re-run the decisive gates ON THE MERGED TREE.** Pre-merge greens do not carry over. Cheapest
   first: `typecheck_compiler_source.sh` (catches a left-behind caller in ~5s — and **`make medaka`
   does NOT gate on type errors**, so nothing else will), then the fixpoint, then the differentials.

---

## Verifying a landing — never trust prose

"Done, all gates green" is a claim, not evidence. Verify, bounded to the decisive checks.

- **For a feature that EXPANDS the set of accepted programs, the decisive check is probing the
  newly-accepted FRONTIER yourself — not the agent's fixtures**, which cluster on the happy path.
  Num-polymorphic literals shipped four stages "all gates green," yet nobody tested a *user*
  polymorphic-literal fn applied to Float (`inc x = x + 1; inc 2.5`): it typechecked but **panicked at
  runtime** (a soundness hole) and separately built to **silent garbage** (an emitter gap the feature
  newly exposed). Both found in a 60-second hand-probe *after* the agents reported green. Ask: "what
  does this newly accept, and does it RUN *and* BUILD correctly across every instantiation (Int *and*
  Float)?" A clean fixpoint + green differentials do NOT cover behavior the corpus never had.
- `git log main..<branch>` + `git diff --stat` — the commits exist and the surface matches the report.
- **Pick the decisive check per change type.** Self-hosted emitter → the **fixpoint** (C3a/C3b): it
  recompiles the whole compiler and proves byte-for-byte self-reproduction. A code *transform* (TRMC) →
  an **IR-shape assertion** that it actually fired (grep the emitted body for *no* `call @mdk_<self>`):
  the differentials compare program OUTPUT, so a pure transform is invisible to them while a mis-route
  shows as wrong output. One decisive check beats re-running everything.
- **`FORCE=1 bash test/build_oracles.sh` before you re-run any `test/bin/*` gate yourself** — your own
  re-verify can read a stale oracle too (this masked a real prop regression as "9/0 unchanged" until a
  forced rebuild showed 5/4).
- `ps` for **orphan processes**, and treat an agent that ended with "waiting on the monitor…" as
  **unverified** — gate its commit yourself.
- Only after green: **push and open a PR** — the queue lands it; you cannot push `main`. If you combine
  branches locally first, do it on a topic branch and confirm it actually advanced (`git rev-parse
  <branch>` == the new tip): a "Fast-forward" printed on a *detached HEAD* is indistinguishable from one
  on the branch, and that silently stranded two phases (see Failure modes). Then reconcile
  docs/tasks/memory.

---

## Hand-offs that don't rot — make the bug list EXECUTABLE

"The gap docs lie" is the diagnosis; this is the remedy, and it should be the default whenever you hand
a list of defects to anyone. **Do not hand over prose. Hand over a script.**

- **Encode every verified repro in a status script** (`verify_<topic>.sh`) that re-runs each against the
  current binary and prints **OPEN / FIXED** per item. Status report, **not a gate** — always exit 0, so
  nobody wires it into CI and starts ignoring it. Banner the companion doc **"⚠️ DO NOT TRUST THIS LIST
  — RUN THE SCRIPT."** (While my branch was in flight another orchestrator fixed one of my P0s; the
  script detected it with **zero bookkeeping from either of us**. A static list would have been wrong
  within hours.)
- **Tag every workaround with a greppable marker** — `WORKAROUND(B2): … revert when B2 closes` — and
  have the script print the marker sites beneath its report. Then the command that says a bug is fixed
  also says which lines to delete; otherwise workarounds quietly become permanent architecture. (We
  carried 7 workarounds for 4 bugs.)
- **Separate what YOU reproduced from what an agent claimed** (✅ VERIFIED / 🟡 REPORTED). Agent
  root-causes were wrong often enough that a confident-but-wrong entry poisons the next person's search.
- **Distinguish the diagnosis from the inference.** An agent reported "we need `runST`". The
  *observation* (two authors hit the same wall, with measured cost) was gold; the *conclusion* was
  premature — the real defect was upstream, in what the effect actually meant. **Log what hurt, not what
  you'd build.**

---

## Choosing the model

- **Sonnet** — surgical, scoped, additive, read-only, or mechanical-with-a-template work (wiring, one
  additive dispatch arm, audits).
- **Opus** — heavy/risky: real codegen, central-dispatch refactors, uncertain blast radius, or where
  debugging depth matters. Default for the hottest/most-load-bearing files.
- Escalate mid-pattern: a "simple" first step may be Sonnet; the general fix it ladders into is Opus.

---

## Parallelism & file hygiene

### 🚨 TELL EVERY AGENT TO WORK IN ITS OWN WORKTREE — SAY IT EXPLICITLY

**Two agents in one session independently ended up building in the ORCHESTRATOR'S worktree.** The
harness injects the *orchestrator's* `CLAUDE.md`/`AGENTS.md` path into the agent's context, so an agent
that trusts that header `cd`s into **your** tree. One ran `make medaka` there concurrently with your own
build, writing the same `./medaka`/`./medaka_emitter`; it "succeeded" with exit 0 and was worthless.
Another's `git diff > patch` swept up a sibling's unstaged golden. Worst near-miss: an agent had
uncommitted **emitter** edits in the orchestrator's tree while the orchestrator ran `refresh_seed.sh` —
which could have baked an unreviewed emitter change into the seed, **the trust anchor**, and pushed it.
(Verified clean afterwards: a fixpoint from a *pristine* `origin/main` checkout gave C3a YES + C3b YES —
that drift detector is exactly what proves the seed was not contaminated. Do this if you suspect a leak.)

> Work ONLY in your own worktree. Do NOT `cd` into `/root/medaka` or any
> `.claude/worktrees/<other>` directory, and do NOT build there — the CLAUDE.md path in your
> context may point at someone else's tree; ignore it and use your own cwd.

On your side: **never run `refresh_seed.sh`, `make medaka`, or `git add -A` in a tree you have not just
confirmed clean** (`git status --short`). A shared worktree makes "capture my diff" unsound.

- Parallelize only **non-overlapping files**. Never two agents on one file; never pile agents onto the
  single hottest file. Sequential when they share a file.
- **The MERGE is where integration bugs live.** Two agents on genuinely disjoint files both reported
  green and git merged them with **zero conflicts** — and the merged tree had defects neither could see:
  git auto-merged A's `deriving (Eq)` on top of B's *deliberately hand-written* `impl Eq` (overlapping
  impls), and A's exhaustive `match` predated the new ADT constructor B added (latent panic). **"No
  conflict" means textually compatible, not semantically compatible.**
- **Read-only audits parallelize freely** — zero merge risk; good use of idle time while a write agent
  runs. For a broad review, **fan out by domain** (typecheck / emitter / parser / error-path); one
  consolidated agent is shallower.
- **Doc-edit hygiene under concurrency:** if an agent is concurrently *appending* to a shared doc (most
  append an "AS-BUILT" section at EOF), make your own edit a **mid-file insert** in a stable region — the
  3-way merge then auto-resolves instead of conflicting at EOF.

---

## Dogfooding as a bug-finding strategy

Building a real library in the language is the highest-yield bug finder we have — **but only if you
choose the work deliberately.**

- **Pick work that stresses NEW language surface, not more of the same shape.** Six SQL query features
  found **zero** compiler bugs — not luck: all the same shape (add an ADT node, an evaluator arm, an
  oracle). The moment the work had a *different* shape — a parser on a user-defined monad, byte-chain
  manipulation, a cross-project dependency — bugs fell out immediately. **Ask: "what part of the language
  does this exercise that nothing else has?"** If the answer is "nothing," it will find nothing.
- **Know which execution path your tests cover.** Every doctest runs under the **interpreter**, so a
  compiled-only bug is invisible to the entire suite: the SQL parser shipped **32/32 green doctests**
  while *every arithmetic operator in its grammar* was silently miscompiled natively. **Tell agents an
  interpreter-green result proves nothing, and require gates to run against a real `build`.**
- **Feed the system real input, not hand-built structures.** Every prior oracle built its query as an ADT
  by hand; none ever put a `NOT` over a nullable column. The first time we fed actual SQL *text* through
  the same engine it exposed a wrong-answer bug (3-valued logic collapsed to 2-valued) that had been
  sitting there the whole time.

---

## Principles

- **Close gaps principled, not piecemeal — but ladder up.** Prefer the general fix over a half-measure;
  surface the choice. Incremental is fine **iff** each bounded rung reusably composes into the general fix
  (or is a strict subset), not a throwaway it discards. Keep a proven fallback if it might balloon.
- **Bounded orchestrator research** — frame, don't exhaustively map.
- **Surface design decisions**; give recommendations, not surveys; act on sensible defaults rather than
  over-asking.
- **Defer expensive regenerations** (the seed) to real checkpoints, not after every sub-task.
- **For a large task delegated in pieces, grant "incremental-landing" permission and ask for the next
  gap.** Land a coherent gated chunk, stub the rest with a recognizable marker, REPORT the precise
  residual. The honest STOP with a precise punch-list (ideally + a pointer to where the fix already
  exists) is the deliverable, not a failure.

---

## Big architectural changes — the design→staged→seams playbook

For a large, route-fragile change (this session: TRMC), don't hand one agent the whole thing.

1. **Design-pass first** — a read-only Plan agent that confirms the problem *empirically*, recommends the
   mechanism, maps the touchpoints, and returns a decision-ready design with an explicit **"design forks
   (need a human decision)"** section. Persist it as a `*-DESIGN.md`: the implementation agents share one
   spec, and it is the future record. Two rules learned the hard way:
   - **Ask "does an existing spec already answer this?" FIRST, before reasoning from principles.** I was
     about to write a design doc from scratch; the reviewer found the question *was* already answered in
     a spec I hadn't read — and that **the implementation contradicted the spec**, which reframed the
     whole problem. One `grep` would have saved an hour of theorising.
   - **Hand the reviewer your hypothesis and tell it to BREAK it** — an independent model beats a second
     opinion that agrees. My soundness argument was demolished three ways and I reproduced all three
     counterexamples on the binary. **Ship the design with the rejected alternative and the
     counterexamples that kill it** — it is the proposal the next person will reach for, and it looks
     right until you try to break it.
2. **Surface the forks to the user**, lock scope, and write the locked scope into the design doc.
3. **Staged implementation agents** — one per sub-part, ascending risk, each **independently gated +
   merged** before the next branches (same file ⇒ sequential). Verify each landing's decisive check.
4. **Keep deferred-scope seams parameterized** so the deferred part is an *additive* later patch, not a
   rewrite (computed offsets, no "zero leading params" assumptions). Then **scope the deferred extension
   explicitly** (a read-only scoping agent) even while deferring it: it captures the seam knowledge,
   verifies whether a real target even exists (often none → defer is the principled call), and corrects
   the implementers' over-optimistic seam notes.

Re-mint the seed once at the **completed-change checkpoint**, not per sub-part. A *comment-only* edit to
an emitter-graph file does NOT invalidate the seed (emitted IR is identical); any logic change does.

---

## Failure modes seen

- **Agent commits on its OWN-named branch, not the `worktree-agent-<id>` branch.** Merging the
  worktree-id branch is then a silent no-op (a gate read 52/52 instead of 68/68). **Merge by the reported
  SHA**; confirm with `git branch --contains <sha>`.
- **A self-reported `BASE_OK` can be FALSE.** One agent reported `BASE_OK` while rooted at the
  *session-start* commit, missing every overnight landing. The catch was the orchestrator's own **`git
  diff --stat <main> <branch>`**: ~1400 spurious deletions and a recent fixture listed as *deleted*.
  **Always diff-stat the branch against current main before merging** — a surface that doesn't match the
  agent's "small additive change" report means a stale base.
- **Stale-binary footguns.** (1) `make medaka`'s `find -newer` short-circuit can leave `./medaka` NOT
  carrying a lexer/compiler-graph change → `FORCE_EMITTER_REBUILD=1 make medaka` to verify one. (2) The
  `test/bin/*` oracles: `test/build_oracles.sh` **mtime-skips rebuilds**, so after a
  `typecheck.mdk`/`eval.mdk` change a gate silently runs OLD source. **RULE: run `FORCE=1 bash
  test/build_oracles.sh` before trusting ANY `test/bin/*` gate.** This bit three times in one session
  (two agents reached opposite conclusions; a real prop regression read as "unchanged"). A green/red on a
  stale binary means nothing.
- **The empty-report + RESPAWNING-oracle-pool mode** (recurred on MANY agents, Sonnet AND Opus). An agent
  ends its turn with a stray line ("Background scan in progress…") instead of a report, having launched a
  bare `build_oracles.sh` (an `xargs -P` pool) that didn't finish inside the turn — so every harness
  re-invoke RESTARTS the pool. Reaping alone doesn't work; it respawns, and the `TaskStop` + salvage loop
  is routine. **Remedy, in order: (1) `TaskStop <agentId>` FIRST to stop the respawn; (2) reap ONLY that
  agent's own PIDs (`ps -eo pid,args | grep "agent-<id>" | grep -v grep | awk '{print $1}' | xargs -r
  kill`) — NEVER a box-wide `pkill -f build_oracles.sh` / `pkill -f 'xargs -P'`, which kills other
  sessions' builds (the sandbox blocks it, correctly); (3) salvage or discard.** Salvage IF the WIP in its
  worktree is COMPLETE (`git -C <wt> status` + a grep for the target end-state): gate it yourself and
  commit on its branch; DISCARD + re-spawn if it is a partial hack. **Bake into every prompt: NEVER run
  bare `build_oracles.sh`; build one oracle with `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one
  <name>`.**
- **Three shapes of report you must NOT act on:** ≈0 tool uses + a boilerplate/empty result (a *failed*
  run, not a completed one — re-spawn, sometimes as a different agent type); a stray monitor/tool echo
  returned as the "result"; and "all gates green" computed against STALE oracles or a stale `./medaka`.
  All three are unverified: inspect the branch from git and re-run the decisive gate with FORCE-rebuilt
  oracles + a fresh `make medaka`.
- **Salvaging a session-limit-killed agent.** It can die having committed NOTHING while its WIP is live in
  its worktree (`git -C <worktree> status`). Preserve it (commit on its branch), then verify INDEPENDENTLY
  from scratch — it left no report.
- **Stranded commits from a detached HEAD.** `git checkout <sha>` in a worktree DETACHES HEAD; a later
  `git merge --ff-only <branch>` then advances the *detached HEAD*, not the branch — the work lands on a
  dangling line. This stranded two verified phases (recovered via `git reflog <branch>`). **Never `git
  checkout <sha>` in a worktree** — to drop commits use `git reset --hard <sha>` ON the branch; to inspect
  an old commit use a throwaway `git worktree add`. After any checkout assert `git rev-parse
  --abbrev-ref HEAD` is a branch name, not `HEAD`.
- **Non-isolated background agents SHARE your worktree's filesystem + git HEAD.** An Agent spawned WITHOUT
  `isolation: worktree` runs in your working dir: it `git checkout -b`s there (leaving YOUR worktree on
  its branch) and its builds write the same `./medaka` artifacts as yours. So: **never run two
  build-heavy things at once**, and a clean `git status` doesn't prove an agent isn't mid-edit (it may
  just not have written yet). For parallel write-agents, pass `isolation: worktree`.
- **An agent can commit stray build-artifact binaries via `git add -A`** (once: 5 root-level demo
  binaries, ~250 KB each, alongside the real change). Caught by the pre-merge `git diff --stat` surface
  check. Fix: rebuild a CLEAN commit off main with only the intended files (`git checkout -B clean main`,
  then `git checkout <agent-sha> -- <good files>`) — do NOT merge the polluted commit. **Bake "stage BY
  PATH, never `git add -A`" into every prompt.**
- **A fresh isolated worktree has NO `./medaka_emitter` — and that is FINE: plain `make medaka`
  cold-bootstraps there, and a lagging seed does NOT break it** (a drifted seed only WARNS — `C3a WARN …
  lagging seed`). This is the thing agents most often misreport as "I broke the seed." ⚠️ Until
  2026-07-13 the advice to `cp` another worktree's emitter in first was **actively unsafe**: the build
  tested "is this emitter current?" by **mtime**, and `cp` stamps the copy with the *current* time — so
  the staler the emitter's origin, the FRESHER its copy time, the rebuild was skipped, and the ancient
  binary died on syntax it predated. A **provenance stamp** (`.medaka_emitter.srcstamp`, hashed from the
  compiler sources, never travels with a `cp`) fixed it; the `cp` is now a safe ~4 s speedup.
- **A construct-removal census MUST scan the always-loaded prelude (`stdlib/core.mdk`) for REAL uses** (not
  just doc-comment/string matches). A missed prelude use makes the *compiled* binary fail to load the
  prelude → it errors on EVERY program, mimicking a codegen/DCE miscompile (an Opus agent spent a 12-build
  bisection before another proved the emitted IR was byte-identical live-vs-dead). Grep the prelude first;
  there is no DCE miscompile.
- **⚠️ A GATE THAT CAN SILENTLY NO-OP WILL. "Green" is not "ran".** Three instances in one session: every
  wasm gate shelled out to `wasm-tools`, which **was not installed** — each printed `skipping` and
  **exited 0**, so the WasmGC tandem gate had never once executed on this machine (the standing "1 skip"
  everyone read past); `sqlite3`, the differential oracle for 18 gates, was also absent; and two oracle
  scripts had **never been able to pass** (each `mv`'d a binary onto itself, dying before a single
  assertion). **At session start, prove your gates execute: check the tool deps exist, and read assertion
  COUNTS, not exit codes.** A gate whose failure mode is "exit 0" manufactures confidence.
- **Stale worktree:** a long-lived orchestrator worktree drifts behind → `git merge origin/main` it before
  relying on its state (**never bare `git merge main`** — it SILENTLY NO-OPS when another worktree has
  `main` checked out).
- **Session start:** `git worktree list` + `ps` — check for other live sessions, orphan gate processes, and
  stale worktrees (prune merged ones; preserve your own, any running agent's, and branches with unmerged
  commits).
- A "surgical one-node" scope hypothesis turns out coupled to a deeper issue → the STOP guardrail catches
  it; re-scope rather than ship "panic-gone but output-wrong."

---

## Bookkeeping

- A `TaskList` chain for multi-step sub-projects (blockedBy dependencies); mark in_progress/completed as
  you go.
- After each landing, reconcile `PLAN.md`, and verify root-cause claims on the binary before trusting them
  in docs.
- Record durable workflow learnings in memory; record role learnings **here**.

---

## Medaka specifics

Build/seed mechanics live in `AGENTS.md`; what is orchestrator-specific:

- **Build in a worktree:** `make -C /absolute/path/to/worktree medaka` — the shell cwd resets between
  calls, so a bare `make medaka` would build the MAIN checkout.
- **Who re-mints the seed:** not agents. An emitter-graph change (`compiler/backend/llvm_emit.mdk` etc.)
  leaves `compiler/seed/emitter.ll.gz` STALE; agents just verify `test/selfcompile_fixpoint.sh` (it
  self-compiles fresh and never reads the committed seed). **You** re-mint at real checkpoints only — it
  is a multi-MB churn commit — with `sh test/refresh_seed.sh` (**run it TWICE**: not idempotent after a
  codegen change) then `test/bootstrap_from_seed.sh`.
- **The decisive emitter gate is the fixpoint** (C3a = native == interpreted emission; C3b = native
  reproduces its own IR), plus the byte-identical `diff_compiler_llvm` / `_modules` / `_typed` /
  `diff_compiler_build` differentials. These compare the native compiler against **checked-in goldens
  captured from itself** — there is no OCaml oracle (OCaml was removed 2026-06-26).
- **Decided invariants — do not relitigate** (see memory): retirement ≠ removal; lazy top-level nullary
  canonical; no catchable panics.
- **A new gap in a tool's native compile** (a tool pulled into the native graph for the first time) is the
  recurring shape: census it gap-tolerantly, then close each gap principled. `compiler/EMITTER-GAPS.md` is
  the gap ledger.
