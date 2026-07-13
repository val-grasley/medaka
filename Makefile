# Medaka — convenience targets.
#
# The native, self-hosted `medaka` (CANONICAL post-2026-06-12 flip) — built
# OCaml-free.  Day-to-day: a 2-stage rebuild from current source (no seed).
# Fresh clone: cold-bootstrapped once from the gzipped IR seed.
#
# Quick start:   make medaka && ./medaka run yourfile.mdk

.PHONY: medaka emitter seed bootstrap test clean help

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

## test    — run the differential gate suite (test/run_gates.sh, all
##           test/diff_compiler_*.sh gates in parallel, ~32s). Needs `make medaka`
##           AND pre-built oracles (`sh test/build_oracles.sh`, ~1-2min) — a gate
##           whose oracle is missing now FAILS the run (not a silent skip); build
##           oracles first if this reports failures on a fresh clone/worktree.
##           This does NOT itself build oracles (that step is slow/parallel and
##           deliberately explicit — see test/build_oracles.sh).
test: medaka
	sh test/run_gates.sh

## clean   — remove native build artifacts (keeps the checked-in seed)
clean:
	rm -f medaka medaka_emitter

help:
	@grep -E '^## ' Makefile | sed 's/^## //'
