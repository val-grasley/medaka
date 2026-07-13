# QA findings — tooling-cli

Binary: `$WT/medaka` where WT=/Users/val/medaka/.claude/worktrees/virtual-fluttering-meteor
Probes: /private/tmp/claude-501/-Users-val-medaka/07db78cb-7807-4285-bb67-639494a218d2/scratchpad/probes/tooling-cli
All findings reproduced twice.

## F1: `medaka test` exits 0 when doctests and prop tests FAIL
- Severity: critical
- Class: silent-wrong
- Launch blocker: yes (CI/automation silently green on failing tests)
- Repro:
  ```
  {- | Doubles.

     > dbl 4
     8
     > dbl 0
     1 -}
  dbl : Int -> Int
  dbl x = x * 2
  ```
  $ medaka test dt4.mdk; echo $?
  ```
  running doctests in dt4.mdk
    ok   dt4.mdk:3: dbl 4
    FAIL dt4.mdk:5: dbl 0
         expected: 1
           actual: 0

  dt4.mdk: 1/2 passed (1 failed, 0 errors)
  0
  ```
  Same with a failing `prop`: `Testing "bogus: x < 100" ... FAILED after 1 test ... 1 passed, 1 failed` → exit 0.
- Expected: nonzero exit on any test failure. (The failure *report itself* is good — file:line, expected/actual, prop counterexample.)

## F2: Any lex/parse error kills the whole REPL session (exit 1)
- Severity: high
- Class: crash / error-ux
- Launch blocker: yes (REPL is a first-touch surface; one typo ends the session and loses all definitions)
- Repro:
  $ printf '1+1\n?\n2+2\n' | medaka repl
  ```
  runtime error [E-PANIC]: unexpected character '?'
  medaka repl (:quit to exit, :reset to clear session)
  > 2 : Int
  > (session dead — 2+2 never evaluated, exit 1)
  ```
  Same death for any parse error: `let x =`, `f x = match x`, `{ name = "v" }`, `"unclosed`, `let x = 5` (a line every Python/JS/Rust user types). Type errors and unbound variables ARE recovered gracefully — only lexer/parser errors are fatal.
- Expected: report the error, keep the session alive, reprompt.
- Hypothesis: REPL doesn't route lex/parse failures through the accumulating-diagnostics path; they surface as an uncaught E-PANIC.

## F3: REPL has no multiline input — cannot define multi-line functions, records, or match
- Severity: high
- Class: missing-feature
- Launch blocker: yes (combined with F2, typing the natural 2-line function kills the session)
- Repro:
  $ printf 'f x =\n  x + 1\nf 1\n' | medaka repl
  ```
  runtime error [E-PANIC]: parse error   (session dies at line 1)
  ```
  No continuation prompt, no `:{ :}` blocks, no trailing-incompleteness detection. `record` declarations (which are layout-based multi-line per SYNTAX.md) are therefore impossible in the REPL entirely.
- Expected: continuation prompt when input is incomplete, or at least a documented block-entry mechanism.

## F4: `import` does not work in the REPL (silently or with a bogus error)
- Severity: high
- Class: silent-wrong / missing-feature
- Launch blocker: yes ("import list; reverse [1,2,3]" is a minute-two action)
- Repro:
  $ printf 'import list\nlist.reverse [1,2,3]\nimport list.{reverse}\nreverse [1,2,3]\n' | medaka repl
  ```
  <repl>: Unbound variable: list
  <repl>: Field 'reverse' does not belong to record '<unknown>'
  <repl>: Unbound variable: reverse
  ```
  `import list` itself is ACCEPTED with no output/error; every subsequent use of imported names fails. `import list.{reverse}` is also accepted, then `reverse` is still unbound.
- Expected: imports load the module into the session, or the import line errors with "imports are not supported in the REPL".

## F5: `medaka run` cannot execute stdin/file/env IO — panics; native build works (run vs build divergence)
- Severity: high
- Class: run-build-divergence / error-ux
- Launch blocker: yes, unless documented + given a real error message ("read input / read a file" is a day-one task)
- Repro:
  ```
  main =
    let name = readLine ()
    println "Hello, \{name}"
  ```
  $ echo Val | medaka run stdin.mdk
  ```
  runtime error [E-PANIC]: unbound identifier: readLine
  ```
  $ medaka build stdin.mdk -o b && echo Val | ./b
  ```
  Hello, Val
  ```
  Same for `readAll`, `args`, `getEnv`, `readFile`, and stdlib wrappers built on them (`import io.{readLines}` → "unbound identifier: readFile"). `medaka check` passes all of these (they typecheck fine).
- Expected: either the interpreter implements these externs, or a clean located error at check/run time saying "this primitive is native-only; use medaka build" — not a runtime E-PANIC with no location that reads like a scoping bug.
- Hypothesis: the interpreter's extern table (compiler/eval/eval.mdk) has no readFile/readLine/args/getEnv entries; only the LLVM runtime does.

## F6: A panicking or syntactically-bad doctest aborts the entire `medaka test` run with a useless location
- Severity: high
- Class: error-ux
- Launch blocker: no
- Repro (panic):
  ```
  {- | > dbl 4
     ... -}   -- plus a second fn:
  boom x = panic "kaboom"   -- with doctest  > boom 1  expecting 2
  ```
  $ medaka test dt2.mdk
  ```
  :0:0: runtime error [E-PANIC]: kaboom
  running doctests in dt2.mdk
  ```
  exit 1 — empty filename, 0:0 location, and the OTHER doctests in the file are never run/reported.
  Repro (bad syntax in an example): a doctest line `> 1 +* 2` yields bare `runtime error [E-PANIC]: parse error` with no file, no line, no indication which doctest — and kills the run.
- Expected: a panicking/unparseable doctest is reported as one FAIL/error with its file:line; remaining doctests still run.

## F7: Slightly-off doctest formatting is silently ignored ("no doctests found")
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro:
  ```
  {- | > dbl 4
     8 -}
  dbl : Int -> Int
  dbl x = x * 2
  ```
  $ medaka test dt3.mdk
  ```
  running doctests in dt3.mdk
    (no doctests found)
  ```
  exit 0. Putting the `> expr` on the `{- |` line (instead of after a blank line) makes the doctest invisible — tests pass vacuously with no warning.
- Expected: recognize the example, or warn that a `>`-looking line was skipped.

## F8: Module resolution is cwd-relative, not entry-file-relative — `medaka run path/to/main.mdk` breaks sibling imports
- Severity: high
- Class: silent-wrong / error-ux
- Launch blocker: yes (breaks any project with an src/ dir the moment it's run from the root; medaka.toml does not help)
- Repro: proj2/medaka.toml (entry = "src/main.mdk"), proj2/src/helper.mdk (`export hi = "from helper"`), proj2/src/main.mdk (`import helper.{hi}` … `main = println hi`).
  $ cd proj2 && medaka run src/main.mdk
  ```
  unknown module: helper
  ```
  $ cd proj2/src && medaka run main.mdk
  ```
  from helper
  ```
  Absolute path from any other cwd also fails. `medaka check src/main.mdk` from the root shows "available modules:" = stdlib only, confirming siblings are searched in the CWD, not next to the entry file.
- Expected: imports resolve relative to the entry file's directory (and/or the medaka.toml project root).

## F9: `medaka run` misreports file errors as "unknown module", and loses the good import diagnostics `check` has
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  - $ medaka run nope.mdk → `unknown module: nope` (file simply doesn't exist)
  - $ medaka run adir → `unknown module: adir` (it's a directory)
  - $ medaka run notmdk.txt → `unknown module: notmdk.txt` (valid program, wrong extension — no hint that only .mdk is accepted)
  - $ medaka run --wat hello.mdk → `unknown module: --wat` (unknown flag parsed as a module)
  - For a real bad import, `medaka run badimp.mdk` prints the terse `unknown module: nosuchmod`, while `medaka check badimp.mdk` prints a beautiful located error with caret and the full "available modules: array, async, base64, …" list. run should show the check-quality error.
- Expected: "file not found: nope.mdk", "expected a .mdk file", "unknown flag --wat", and run reusing check's rich import diagnostic.

## F10: No `--version`; unknown/misspelled subcommands leak internal jargon and give no suggestion
- Severity: medium
- Class: missing-feature / error-ux
- Launch blocker: no (but --version is the first command many users and bug reporters type)
- Repro:
  - $ medaka --version → `medaka: subcommand '--version' not yet in native CLI` (exit 1). Same for `version`, `-v`.
  - $ medaka chek foo.mdk → `medaka: subcommand 'chek' not yet in native CLI` — no "did you mean 'check'?" (the compiler DOES do typo suggestions for unbound variables, so the machinery exists).
  - "not yet in native CLI" is bootstrap-internal jargon that means nothing to a user.
- Expected: a version string; `unknown subcommand 'chek' (did you mean 'check'?)`.

## F11: `medaka fmt` on a directory is a silent no-op (exit 0) — CI trap
- Severity: medium
- Class: silent-wrong
- Launch blocker: no
- Repro: fdir/u.mdk is unformatted.
  $ medaka fmt --check fdir; echo $? → (no output) `0`
  $ medaka fmt fdir; echo $? → (no output) `0`, file untouched
  $ medaka fmt --check fdir/u.mdk → `fdir/u.mdk: not formatted`, exit 1
  Help says `medaka fmt [paths...]` and `medaka lint` DOES accept directories, so users will wire `fmt --check src/` into CI and get green forever.
- Expected: recurse into the directory like lint does, or error "directory arguments not supported".

## F12: `medaka bench` is in --help but not implemented; `medaka manifest` implemented but not in --help
- Severity: medium
- Class: doc-mismatch
- Launch blocker: no
- Repro:
  $ medaka bench dt4.mdk → `medaka: subcommand 'bench' not yet in native CLI` (exit 1), yet `--help` lists `medaka bench [file.mdk]   Run bench declarations`.
  $ medaka manifest → `usage: medaka manifest <file.mdk> [--fn name]` — works, absent from `--help`.
- Expected: help matches reality.

## F13: REPL `:help` missing; banner omits half the commands; `:type`/definitions display drops constraints
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  - $ printf ':help\n' | medaka repl → `Unknown command: :help (try :browse, :type, :reset, :quit)` — so `:browse`/`:type` exist but the banner only advertises `:quit`/`:reset`, and the universal `:help`/`:h` don't work.
  - `double x = x * 2` echoes `val double : a -> a`; `:type map` prints `(a -> b) -> c a -> c b`. Both drop the constraint (`Num a =>` / `Mappable c =>`), asserting polymorphism the values don't have. `medaka doc` has the same bug: `export tri x = x * 3` documents as `tri : a -> a`.
- Expected: `:help` lists commands; printed types include their constraints.

## F14: Anonymous record literal gets "unexpected `r`" pointing at the binding name
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  r = { name = "v", age = 3 }

  main = println r
  ```
  $ medaka run rec.mdk
  ```
  rec.mdk:1:0: unexpected `r`
    |
  1 | r = { name = "v", age = 3 }
    | ^
  ```
  Medaka records are nominal (`record Person` + `Person { … }`, per SYNTAX.md), so rejection is correct — but every JS/Elm/OCaml newcomer will type this, and the error points at `r` (which is fine) instead of the `{`, with no hint that records need a declared type or that `Person { … }` is the construction syntax. In the REPL this same line additionally kills the session (F2).
- Expected: error at the `{` with help like "Medaka has no anonymous records; declare `record R` and construct with `R { … }`".

## F15: Doctest/prop failure with an unbound name is a bare mid-run E-PANIC, not a located check error
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  prop "reverse involution" (xs : List Int) = reverse (reverse xs) == xs
  ```
  (no `import list.{reverse}`)
  $ medaka test pt2.mdk
  ```
  runtime error [E-PANIC]: unbound identifier: reverse
  running doctests in pt2.mdk
    (no doctests found)
  Testing "reverse involution" ... (exit 1)
  ```
  No file:line, and it aborts mid-run. `medaka check` on the same file would locate it; `medaka test` apparently doesn't surface resolve errors before executing.
- Expected: located "Unbound variable: reverse (did you forget to import list.{reverse}?)" before any test executes.

## F16: `medaka check` success output has no trailing newline
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: $ medaka check hello.mdk → prints `main : Unit` with no `\n` (next shell prompt glued: `main : Unitexit=0`). Reproduced on every clean check.
- Expected: newline-terminated output.

## F17: Bare `import util` is accepted but provides nothing (no names, no qualified access)
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `import util` then `greet "x"` → `Unbound variable: greet. (Did you forget to 'import util.{greet}'?)` (good suggestion); `util.greet "x"` → `Unbound variable: util`. So the bare-import line is a silent no-op that parses fine and does nothing.
- Expected: either bare import enables qualified `util.greet`, or the import line itself warns "imports nothing — use import util.{…} or util.*".

## F18: Cyclic-import error has no file/location
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: a.mdk `import b`, b.mdk `import a`, cmain.mdk `import a`.
  $ medaka run cmain.mdk → `cyclic dependency: a → b → a` (exit 1). Correct and readable, but no `file:line` caret like other diagnostics, and `check` gives the same bare line.
- Expected: located at the closing `import` with the standard caret format.

## F19: Assorted exit-code / usage inconsistencies
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro:
  - $ medaka test (no arg, no project) → `usage: medaka test [file.mdk]` but **exit 0** (a usage error reporting success).
  - $ medaka new (no arg) → exit 2; $ medaka doc (no arg) → exit 1; $ medaka fmt (no arg) → exit 2; unknown subcommand → exit 1. No consistent convention.
  - Help says `medaka test [file.mdk]` / `medaka doc [file.mdk]` (optional arg) but both fail without an argument — the brackets promise a project-wide default that doesn't exist.
  - $ medaka check nope.mdk → bare `No such file or directory` (no filename, no `medaka:` prefix); run on unreadable file → bare `Permission denied`.
  - $ medaka lint --only=no-such-rule f.mdk → exit 0, silent (unknown rule name never validated).
- Expected: nonzero on usage errors, one convention, filenames in OS-error messages, unknown-rule diagnostics.

## F20: `medaka doc` output leaks the `|` doc-comment marker and silently emits an empty doc for export-less files
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: docm.mdk with `{- | Doubles a number. … -}` on `export dbl`.
  $ medaka doc docm.mdk → body renders as `| Doubles a number.` (the `{- |` marker's pipe is kept). On a file with documented but non-exported fns, output is just `# dt4` with no note that only exports are documented.
- Expected: strip the `|`; print "(no exported declarations)" hint.

## F21: `medaka new` accepts any name verbatim
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: $ medaka new 'my proj!' → `Created my proj!/` with `name = "my proj!"` in medaka.toml. No validation that the name is usable as a module/package identifier. Also `medaka.toml` is never validated by anything: replacing it with `[package\n@@@garbage` leaves run/lint/build all silently green.
- Expected: reject or sanitize bad names; malformed medaka.toml should at least warn in commands that read it.

## Positive surprises (worth regression fixtures)
- `medaka new` scaffold builds, runs, and tests out of the box (`run`/`build`/`test` all green, README/toml accurate).
- `medaka fmt` on ugly-but-valid code: correct, idempotent, meaning-preserving (ran before/after — identical output), and refuses syntax-error files with a proper located caret error without touching the file.
- `medaka check --json`: clean stable shape, real ranges, stable `code` (`T-NO-IMPL`), exit 1 on errors / 0 clean.
- `medaka check` import error is excellent: caret + full "available modules" list + line snippet.
- Unbound-variable suggestions are good everywhere (`reverse` → "Did you forget to 'import list.{reverse}'?").
- `medaka lint` messages are beginner-legible (bool-simplify, lambda-section, dead-code all clear); `--deny` exits 1 correctly.
- Prop-test failure output includes a minimal counterexample (`x = 100` for `x < 100`).
- Wildcard `import util.*` and local shadowing of an imported name both behave sensibly.
- REPL recovers fine from type errors and unbound variables (only lex/parse errors are fatal — F2).
- `medaka run --release` and `build` default output name (`hello.mdk` → `hello`) work.
- Program args: `./bin foo bar` + `args ()` → `[foo, bar]` (native).

## Suggested regression fixtures
1. `test/` fixture: doctest file with 1 pass + 1 fail — assert `medaka test` exit code != 0 (F1).
2. Fixture: failing `prop` — assert nonzero exit (F1).
3. REPL script fixture (pipe-driven): lex error, parse error, then a valid line — assert session survives and evaluates the last line (F2).
4. REPL fixture: `import list.{reverse}` then `reverse [1,2]` — assert `[2, 1]` (F4).
5. Interpreter externs: `readLine`/`args`/`getEnv`/`readFile` under `medaka run` — assert parity with `medaka build` output (F5), or assert the documented native-only error message.
6. Doctest-panic fixture: file with a panicking doctest + a passing one — assert both are reported, run completes (F6).
7. Doctest-format fixture: `>` on the `{- |` line — assert it is found or warned about (F7).
8. cwd-independence: project with src/main.mdk + src/helper.mdk — run via relative path from root AND absolute path from elsewhere; assert both work (F8).
9. `medaka run` on a nonexistent file / directory / unknown flag — golden error text (F9).
10. `medaka fmt --check <dir>` with one unformatted file inside — assert exit 1 (F11).
11. `--help` vs implemented-subcommand parity check (bench/manifest) (F12).
12. `medaka check` clean-file output ends with newline (F16).
13. Cycle error golden including file:line once located (F18).
14. Positive: `medaka new` scaffold → run+build+test green (currently untested end-to-end).
15. Positive: fmt idempotence + run-before==run-after on a corpus of weird-but-valid files.
16. Positive: `check --json` golden for a clean file (`{"files":[{"file":…,"diagnostics":[]}]}`).
