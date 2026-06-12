# Medaka — convenience targets.
#
# Two compilers live here (see AGENTS.md):
#   • the native, self-hosted `medaka` (CANONICAL post-2026-06-12 flip) — built
#     OCaml-free.  Day-to-day: a 2-stage rebuild from current source (no seed).
#     Fresh clone: cold-bootstrapped once from the gzipped IR seed.  This is what
#     users invoke.
#   • the OCaml reference compiler (`lib/`+`bin/`, built with dune) — kept FROZEN
#     as the soak-period differential oracle (retirement ≠ removal); not removed.
#
# Quick start (native, no OCaml):   make medaka && ./medaka run yourfile.mdk

.PHONY: medaka emitter seed reference bootstrap clean help

## medaka  — build the native OCaml-free `medaka` CLI (CANONICAL).
##           WARM (./medaka_emitter present): 2-stage rebuild from current source,
##           no seed/OCaml.  COLD (fresh clone): bootstrap from the gzipped seed first.
medaka:
	sh test/build_native_medaka.sh

## emitter — build just the native emitter binary from the gzipped seed (medaka_emitter)
emitter:
	sh test/bootstrap_from_seed.sh

## bootstrap — STRICT seed-currency gate: verify the gzipped seed == current native
##             re-emission (C3a byte-identical) + builds medaka_emitter OCaml-free
bootstrap:
	sh test/bootstrap_from_seed.sh

## seed    — RE-MINT the gzipped IR seed via the NATIVE emitter (OCaml-free)
seed:
	sh test/refresh_seed.sh

## reference — build the OCaml reference compiler + tools (the frozen oracle)
reference:
	dune build --root .

## clean   — remove native build artifacts (keeps the checked-in seed)
clean:
	rm -f medaka medaka_emitter

help:
	@grep -E '^## ' Makefile | sed 's/^## //'
