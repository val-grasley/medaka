# Table case-fold fix + stale rejection-corpus labeling

Two small, isolated fixes: (1) `findTable`/`findTableGo` case-insensitivity (F4 residual from
`sql-parser-select.md`), and (2) re-partitioning `sqlite/inmem_sqlparse_probe.mdk`'s stale
REJECTIONS list now that the engine grew `LIKE`, `BETWEEN`, and scalar `upper()`.

## F6 — `findTable` was case-sensitive while `columnIndex` (same file) already folds

- **Category:** compiler-bug (library-level; the exact F4 residual)
- **Severity:** workaround-required, now fixed
- **Repro (pre-fix):** in-memory DB with `CREATE TABLE users(...)`, then
  `SELECT name FROM USERS` → `error: table not found: USERS`, while
  `SELECT NAME FROM users` (uppercase *column*) already worked — a real asymmetry, because
  `columnIndex` (a few dozen lines below `findTable` in the very same file,
  `sqlite/lib/sqlite.mdk`) already ASCII-folds via a local `lowerChars`/`lowerCode` pair, but
  `findTableGo` compared `e.ename == name` with plain `==`.
- **Fix:** `findTableGo` now compares `lowerChars (stringToChars e.ename) == lowerChars
  (stringToChars name)` — reusing the *exact same* `lowerChars`/`lowerCode` helpers
  `columnIndex` already uses, rather than inventing a second ASCII-fold (the codebase already
  has one ASCII-fold trap logged — see `select.mdk`'s `asciiFold`/`asciiUpperChar` comment
  about not hand-rolling a second copy — so I searched for and reused the *closer* one, in
  the same file, instead of importing across the `lib.select` ↔ `lib.sqlite` boundary, which
  would have been circular anyway (`select.mdk` imports `lib.sqlite`).
- **Kept:** the stored `ename` (original case) is untouched; only the lookup comparison
  folds. The not-found error still echoes the name exactly as the caller wrote it (folds
  neither side of the message, only the comparison) — did not want to silently normalize the
  caller's string in a diagnostic.
- **Verified:** new standalone probe `sqlite/inmem_tablecase_probe.mdk` proves
  `FROM users`/`FROM USERS`/`FROM Users`/`FROM uSeRs` all render byte-identical rows (and,
  as a regression guard, that column-name casing is still independently case-insensitive).
  Confirmed the probe actually discriminates the bug: `git stash`-ing the fix reproduces
  three `FAIL` lines (`error: table not found: USERS` etc.); un-stashing flips it to PASS.
  All 22 `sqlite/test/*oracle.sh` gates still pass, plus `test/wasm/diff_sqlite.sh` (native ==
  wasm on 11 in-mem/file probes, unaffected since the fold is ASCII char-code arithmetic, not
  a runtime-conditional path) and `test/wasm/diff_wasm.sh` (155 ok).
- **Not wired into CI:** `inmem_tablecase_probe.mdk` is a standalone probe, not added to
  `test/wasm/diff_sqlite.sh`'s `CORPUS` array — that file is a shared corpus another agent's
  parallel work could also be touching this session, so I left it alone per the AGENTS.md
  shared-corpus trap rather than risk a needless conflict. A natural follow-up for whoever
  next touches that gate.

---

## Stale REJECTIONS labeling in `inmem_sqlparse_probe.mdk`

Not really an "F" finding (no engine bug) — the probe's own comment had drifted from
reality. `rejects` claimed `LIKE 'a%'`, `age BETWEEN 20 AND 30`, and `upper(name)` "MUST come
back as a clean error", but running the built binary showed all three now return correct
rows (`ada`; `ada, cyd, dee`; `ADA, BOB, CYD, DEE`) — the engine grew `LIKE`/`BETWEEN`/scalar
`upper()` at some point after this probe was written, and nobody moved the three queries out
of the rejection corpus. A `medaka lint`/`fmt --check`-clean tree can still lie about intent
in its own comments; this is a case of "the fixture claim rotted, the code moved on."

- **Fix:** moved the 3 queries from `rejects` into `queries` (with a one-line comment
  pointing at this findings file for why), leaving the remaining 10 genuinely-unsupported
  constructs (`UNION`, column aliases, boolean literal `= TRUE`, `RIGHT JOIN`, aggregate in
  `WHERE`, `sum(*)`, ungrouped column, malformed WHERE/LIMIT, unknown column) in place.
- **Verified:** `./medaka run sqlite/inmem_sqlparse_probe.mdk` output is now self-consistent
  — everything under "REJECTIONS" is a clean `error: ...`, everything above it returns rows.
- **Gate consumers enumerated** (word-bounded grep for `inmem_sqlparse_probe`, per the
  AGENTS.md shared-corpus trap): `test/wasm/diff_sqlite.sh` (its `CORPUS` array) and one doc
  comment in `sqlite/lib/sqlstmt.mdk` (`queryString`'s docstring references the probe by
  name; no behavioral coupling). `diff_sqlite.sh` does NOT diff against a captured golden —
  it's a live tandem oracle that builds+runs the SAME probe source under both the native and
  WasmGC backends and diffs their stdout against *each other*, fresh every run — so there was
  no stale golden to re-bless. Ran it directly (`bash test/wasm/diff_sqlite.sh`, after `sh
  test/wasm/build_wasm_oracle.sh`): `11 ok, 0 failing`, including `inmem_sqlparse_probe.mdk`.

## Process notes

- `sh sqlite/test/<name>_oracle.sh` fails with `Bad substitution` under `sh` (dash) — these
  scripts are `#!/usr/bin/env bash` and use bash-only syntax; must invoke as
  `bash sqlite/test/<name>_oracle.sh`, matching `#!/usr/bin/env bash` in the shebang. Several
  also require `MEDAKA_ROOT` set explicitly when run standalone (outside
  `test/run_gates.sh`, which sets it) — e.g. `aggregate_oracle.sh` hard-requires it
  (`${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}`) while others (`delete_negative_oracle.sh`)
  self-derive `ROOT` from `$0`'s location and only need it exported for sub-scripts. Cost a
  couple of failed invocations before reaching for `export MEDAKA_ROOT=<worktree-abs-path>`.
- `sqlite/lib/sqlite.mdk` has zero doctests (`medaka test lib/sqlite.mdk` → "no doctests
  found") — the read-path functions there (`findTable`, `columnIndex`, `scanTableRows`, ...)
  are only exercised through the oracle/probe corpus, not `> ...` doctests. Didn't add one
  for `findTable` because it needs a live `Db` (built from bytes), the same reason
  `queryString`'s docstring gives for having no doctest — a standalone in-memory probe was
  the natural fit instead, matching the existing `inmem_*_probe.mdk` convention.
