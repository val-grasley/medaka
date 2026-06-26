#!/usr/bin/env python3
"""UserPromptSubmit hook: nudge skill triage on roadmap/Phase and stdlib tasks.

Injects a carve-out-aware reminder to load the matching task-playbook skill
*before* planning. It poses the triage question — it does not make the routing
call, because where a change actually lands is only knowable after exploration
(see AGENTS.md's harden-typechecker / extend-stdlib carve-outs)."""
import sys, json, re

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt", "") or ""

# Roadmap/Phase task. Catches a bare "implement phase 65 in PLAN.md".
roadmap = re.search(r"PLAN\.md|phase\s+\d", prompt, re.IGNORECASE)

# Stdlib task: STDLIB.md by name, or "stdlib" with an authoring verb. Pure-Medaka
# stdlib edits and native externs route to different skills, so still a triage.
stdlib = re.search(r"STDLIB\.md", prompt, re.IGNORECASE) or (
    re.search(r"\bstd(?:lib| library)\b", prompt, re.IGNORECASE)
    and re.search(r"\b(implement|add|write|extend|complete|finish|port)\b",
                  prompt, re.IGNORECASE)
)

if not roadmap and not stdlib:
    sys.exit(0)

if roadmap:
    print(
        "Skill triage (roadmap/Phase task detected): before planning, decide "
        "where the change lands and load the matching skill from AGENTS.md's "
        "task-playbook table — skills are PLANNING inputs, so load during "
        "exploration, not after the plan is approved.\n"
        "- Typechecker-internal work in compiler/types/typecheck.mdk (most of "
        "the Phase 62-72 arc: a new type_error, constraint/coherence/unification "
        "tightening) -> load harden-typechecker.\n"
        "- Cross-cutting items threading compiler/frontend/resolve.mdk / "
        "compiler/frontend/desugar.mdk / compiler/eval/eval.mdk (e.g. Phase 63, "
        "69.x dictionary passing) are NOT harden-typechecker -> treat like "
        "add-language-feature.\n"
        "Triage reminder, not a directive: confirm where the fix actually "
        "lands first."
    )

if stdlib:
    print(
        "Skill triage (stdlib task detected): route:\n"
        "- Pure-Medaka function/impl/doctest/prop in stdlib/*.mdk -> load "
        "extend-stdlib (read its doctest-harness + language sharp-edge notes "
        "BEFORE writing — they cost real iterations otherwise).\n"
        "- A new native primitive (extern in compiler/eval/eval.mdk) -> load "
        "add-primitive.\n"
        "STDLIB.md is the checklist but is prone to drift; verify each item "
        "against the actual .mdk before trusting its status."
    )

sys.exit(0)
