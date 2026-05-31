#!/usr/bin/env python3
"""UserPromptSubmit hook: nudge skill triage on roadmap/Phase tasks.

Fires when a prompt mentions PLAN.md or "phase <N>" and injects a
carve-out-aware reminder to load the matching task-playbook skill *before*
planning. It poses the triage question — it does not make the routing call,
because whether a Phase is typechecker-internal is only knowable after
exploration (see AGENTS.md's harden-typechecker carve-outs)."""
import sys, json, re

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt", "") or ""

# Broad trigger: any roadmap-flavored task. Deliberately catches a bare
# "implement phase 65 in PLAN.md" that names no typechecker terms.
if not re.search(r"PLAN\.md|phase\s+\d", prompt, re.IGNORECASE):
    sys.exit(0)

print(
    "Skill triage (roadmap/Phase task detected): before planning, decide where "
    "the change lands and load the matching skill from AGENTS.md's task-playbook "
    "table — skills are PLANNING inputs, so load during exploration, not after "
    "the plan is approved.\n"
    "- Typechecker-internal work in lib/typecheck.ml (most of the Phase 62-72 "
    "arc: a new type_error, constraint/coherence/unification tightening) -> load "
    "harden-typechecker.\n"
    "- Cross-cutting items threading resolve/desugar/eval (e.g. Phase 63, 69.x "
    "dictionary passing) are NOT harden-typechecker -> treat like "
    "add-language-feature.\n"
    "Triage reminder, not a directive: confirm where the fix actually lands first."
)
sys.exit(0)
