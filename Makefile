# Medaka — convenience targets.
#
# The native, self-hosted `medaka` (CANONICAL post-2026-06-12 flip) — built
# OCaml-free.  Day-to-day: a 2-stage rebuild from current source (no seed).
# Fresh clone: cold-bootstrapped once from the gzipped IR seed.
#
# Quick start:   make medaka && ./medaka run yourfile.mdk

.PHONY: medaka emitter seed bootstrap seed-health test gates preflight ci clean help

## medaka  — build the native OCaml-free `medaka` CLI (CANONICAL).
##           WARM (./medaka_emitter present): 2-stage rebuild from current source,
##           no seed/OCaml.  COLD (fresh clone): bootstrap from the gzipped seed first.
medaka:
	sh test/build_native_medaka.sh

## emitter — build just the native emitter binary from the gzipped seed (medaka_emitter)
emitter:
	sh test/bootstrap_from_seed.sh

## bootstrap — STRICT seed-currency gate (CHECKPOINT USE): verify the gzipped seed
##             == current native re-emission, byte-identical (C3a). Run this before
##             cutting a release or a seed re-mint — NOT on every emitter change.
##             The everyday requirement is only that the seed still WORKS (which
##             `make medaka` proves on its cold path); byte-currency is a drift
##             detector. See the SEED POLICY note in test/bootstrap_from_seed.sh:
##             conflating the two drove 41 re-mints = 86 MB = 40% of git history.
bootstrap:
	SEED_STRICT=1 sh test/bootstrap_from_seed.sh

## seed-health — the EVERYDAY check (what CI runs): the seed must still BUILD a
##             working emitter from current source. C3a drift only WARNS.
seed-health:
	sh test/bootstrap_from_seed.sh

## seed    — RE-MINT the gzipped IR seed via the NATIVE emitter (OCaml-free)
seed:
	sh test/refresh_seed.sh

## preflight — THE AGENT LOOP. Build + run only what your DIFF touches.
##             Derives the gate set from `git diff --name-only`, derives the ORACLE
##             set from those gates, and builds only those (an agent touching
##             parser.mdk builds 9 oracles, not 54). Skips the expensive gates —
##             the 3-engine differential (346 fixtures × clang) and the fixpoint
##             (unless you touched the backend, where it IS the decisive gate).
##             ⚠️ A FILTER, NOT AN AUTHORITY. It runs a SUBSET and prints what it
##             skipped. CI on the PR is the authority. Do not merge on a green
##             preflight.  Usage: make preflight [BASE=main]
preflight:
	sh test/preflight.sh $(BASE)

## test    — the IN-LANGUAGE suite: doctests, property tests, and `test "…"` decls,
##           run by `medaka test` itself (dogfooding). Needs NO oracle binaries.
##           This is what `medaka test` means; the differential gate suite is
##           `make gates`.
test: medaka
	sh test/diff_compiler_ported.sh
	./medaka test stdlib/list.mdk
	./medaka test stdlib/core.mdk

## gates   — the FULL differential gate suite (all 82 test/diff_compiler_*.sh, in
##           parallel). Needs `make medaka` AND pre-built oracles:
##             sh test/build_oracles.sh                    # all 54
##             sh test/build_oracles.sh --for '<pattern>'  # only what a gate reads
##           A gate whose oracle is missing now FAILS (not a silent skip), and the
##           runner hard-fails if 0 gates passed — so a fresh clone can no longer
##           report "0 failed" having tested nothing.
##           Slow on a small machine; CI shards it across 6 hosted runners.
gates: medaka
	sh test/run_gates.sh

## ci      — everything CI runs, locally. Slow. Prefer `make preflight`.
ci: medaka
	FORCE=1 sh test/build_oracles.sh
	sh test/run_gates.sh
	$(MAKE) test

## clean   — remove native build artifacts (keeps the checked-in seed)
clean:
	rm -f medaka medaka_emitter

help:
	@grep -E '^## ' Makefile | sed 's/^## //'
