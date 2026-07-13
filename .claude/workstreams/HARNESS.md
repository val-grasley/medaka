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
