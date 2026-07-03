# error_quality_fixtures — compiler error-message evaluation corpus

A corpus of **small, plausible mistakes** a real human or an LLM agent would
actually make, one per file, organized by the pipeline stage that *should*
report the problem. Its purpose is to build an evaluation baseline of the
**current** error output so message quality can be judged (and later improved).

This directory is **not wired into any gate** and does not participate in the
fmt/lint pre-commit hook (which excludes `test/`). The fixtures are
intentionally broken; do not "fix" them.

## What this is / is not

- It **is** a baseline: `capture.sh` records the current stderr + exit code for
  every fixture into a sibling `<fixture>.out` golden.
- It is **not** a grader. `INVENTORY.md` carries a one-line neutral observation
  per fixture (e.g. "no location", "cascades", "cryptic type printed"), not a
  score. A separate rubric/grading pass consumes this corpus later.

## Layout

```
<stage>/<descriptive_name>.mdk    # the broken program
<stage>/<descriptive_name>.out    # captured baseline: cmd + exit code + stderr
```

## Taxonomy (stage → subcommand used by capture.sh)

| Stage        | Subcommand | Count | What the fixtures probe |
|--------------|------------|-------|--------------------------|
| `lex/`       | `check`    | 4     | unterminated string/char/comment, bad escape |
| `parse/`     | `check`    | 7     | missing `then`, unclosed paren, trailing operator, missing `=>`, `else let` block, missing comma, keyword as binder |
| `resolve/`   | `check`    | 8     | unbound var / typo'd name, unbound constructor / type, unknown module, importing a name that doesn't exist, forgotten import |
| `typecheck/` | `check`    | 19    | int/string mismatch, arg-order swap, too few / too many args, float-where-int, if-branch mismatch, heterogeneous list, annotation mismatch, apply non-function, cons mismatch, return-type mismatch, missing record field / wrong field, missing instance / constraint, ambiguous, tuple-arity, wrong map arg, bool-where-int |
| `exhaust/`   | `check`    | 5     | non-exhaustive match (Option / Bool / List / custom ADT), redundant arm |
| `effect/`    | `check`    | 3     | IO not in annotation, effect missing from row, pure fn does IO |
| `eval/`      | `run`      | 6     | division / modulo by zero, index OOB, explicit `panic`, let-else divergence, runtime non-exhaustive |
| `build/`     | `build`    | 3     | internal-only extern misuse, `main ()` shape, type error surfaced at build |

## Regenerating the baseline

```sh
make medaka                              # build ./medaka first
sh test/error_quality_fixtures/capture.sh          # (re)capture all .out goldens
CHECK=1 sh test/error_quality_fixtures/capture.sh  # compare vs goldens, no write (exit 1 on drift)
```

`capture.sh` strips absolute `$ROOT/` prefixes to `ROOT/` so goldens are
relocatable, and prints a summary (fixture count, how many exited zero/nonzero).
See `INVENTORY.md` for the per-fixture table and observations.
