# Workstream: HARNESS (the agent tooling, not the repo)

This is not a Medaka bug. It is a **Claude Code harness** bug, and it is the single biggest
hazard for running several orchestrators on one box.

---

## H-1 · 🚨 Agents get misrouted into the ORCHESTRATOR's worktree

The harness injects the **orchestrator's** `CLAUDE.md`/`AGENTS.md` path into a subagent's
context. Agents that trust that header `cd` into the orchestrator's tree instead of their own.

**Four incidents in one session:**

1. An agent ran `make medaka` **concurrently with the orchestrator's build**, in the same
   directory, writing the same `./medaka` and `./medaka_emitter`. Its build reported **exit 0**
   and was **worthless**.
2. An agent's `git diff > patch` silently swept up a **sibling's** unstaged golden.
3. An agent had uncommitted **emitter** edits present while the orchestrator ran
   `refresh_seed.sh` — which could have baked an unreviewed emitter change into
   `compiler/seed/emitter.ll.gz`, **the trust anchor**. (Verified clean afterwards by
   byte-comparing a 2-pass re-mint against the committed seed. Only luck.)
4. An agent's uncommitted `typecheck.mdk` **semantics change** was swept into the orchestrator's
   commit by `git add -A`. **`ab395e0b` is on `main` right now with a message that claims it
   touches only test ledgers.** It does not — it carries 38 lines of typechecker code.

**Real fix:** inject the agent's **own** worktree path, or always carry the absolute worktree
path in the prompt.

**Until then — mitigations, all landed:**
- **State the absolute worktree path in every agent prompt**, and tell the agent to ignore the
  CLAUDE.md path in its context.
- **STAGE COMMITS BY PATH. NEVER `git add -A`.**
- Never run `refresh_seed.sh` / `make medaka` / `git add -A` in a tree you have not *just*
  confirmed clean (`git status --short`).

---

## H-2 · Shared `.git` means shared REFS, and a ref is not a fixed point

Every worktree on this box is `git worktree add` off the **same** `.git` (`git rev-parse
--git-common-dir` proves it). That means `origin/main`/`main` are **not local to your
worktree** — they advance the instant ANY sibling agent runs `git fetch`, mid-task, with no
signal to you (#519).

**Two failures this causes, both silent:**
1. `git diff --stat origin/main...<branch>` (or `main...<branch>`) lies about YOUR surface. A
   sibling's fetch advances the ref underneath a running diff, so a genuine 6-file change can
   report 78 files touched.
2. A "prove the bug still reproduces" recipe that does `git checkout origin/main -- <file>`,
   rebuilds, and checks the fixture still fails — then restores — now reverts to an *advanced*
   `origin/main`, not the tree the agent actually started from. It silently rebuilds and tests
   a DIFFERENT tree than the one under investigation, defeating the check without ever
   erroring.

**Remedy: pin the branch point once, at STEP 0, and never name a moving ref again.**
```sh
BASE=$(git rev-parse HEAD)        # at STEP 0, before any work
git diff --stat $BASE...HEAD      # your REAL surface
git checkout $BASE -- <file>      # a revert that means what it says
```
`git stash push -- <file>` is NOT a substitute — it silently no-ops with "No local changes to
save" once the change is already committed.

## H-gh: gh CLI write-path workarounds on this box (#835)

`gh` here fails PR/issue **edits** against this repo with `GraphQL: Projects (classic) is
being deprecated … (repository.pullRequest.projectCards)` — and the trap is that
`gh pr edit N --body-file f` / `gh issue edit` exit **without applying the change**
(verified by read-back, twice, 2026-07-21; `gh --version` 2.46.0 (Debian)). Working path is REST:

```sh
gh api repos/MedakaLang/medaka/pulls/816  -X PATCH -F body=@file   # PRs
gh api repos/MedakaLang/medaka/issues/820 -X PATCH -F body=@file   # issues
```

then READ BACK (`gh pr view N --json body | grep <sentinel>`) — never trust the exit
status (this is the general gh write-path rule; the Projects-classic error is one more
cause). Also: backticks inside a DOUBLE-quoted `--title`/`--body` are shell command
substitution — a title containing `` `gh pr edit` `` executed it mid-flight this session;
use single-quoted heredocs for bodies and plain text for titles. Re-check whether a gh
upgrade fixed the GraphQL path before propagating this further; delete this block when it
has.
