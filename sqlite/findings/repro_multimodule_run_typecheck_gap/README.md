# Repro — `medaka run` does not gate on TYPE errors in a multi-module program

Verified on `sqlite-arc` @ `f4e579c5` with a freshly built `./medaka`.

## Why it probably didn't reproduce for you

Three ways to miss it. All three are easy:

1. **It must be MULTI-MODULE.** Single-file `run` gates correctly — it prints the same clean
   diagnostic `check` does and refuses to run. The bug is specific to the loader path.
   (`single.mdk` below is the control; it behaves correctly.)
2. **It must be a TYPECHECK error, not a RESOLVE error.** An unbound variable *is* gated on the
   multi-module path, with a good message. Only typecheck errors (missing impl, type mismatch)
   leak through.
3. **⚠️ THE EXIT CODE IS `1` EITHER WAY.** This is almost certainly what got you. `run` still
   exits nonzero — it just exits nonzero for the *wrong reason*: it **executes the ill-typed
   program** and dies on a runtime panic, instead of refusing to run it. Any check of the form
   "does `run` reject this?" answers **yes**. The bug is only visible in the *message*, and in
   the fact that the program actually ran.

## Files

    f3/
      lib/t.mdk      public export data Foo = Foo Int
      main.mdk       import lib.t.{Foo}
                     main : <IO> Unit
                     main = println "\{Foo 1}"        -- Foo has no Display impl
      single.mdk     same program, one file (the CONTROL — this one behaves correctly)

## Commands + actual output

    $ medaka check main.mdk
    main.mdk:4:16: No impl of Display for Foo; add 'deriving Display' to the 'Foo' type,
                   or write an 'impl Display Foo'.
      |
    4 | main = println "\{Foo 1}"
      |                 ^
    exit=1                                    <-- correct, located, actionable

    $ medaka run main.mdk
    runtime error [E-PANIC]: intToString: not an Int
    exit=1                                    <-- WRONG. Unlocated, unrelated message.
                                                  The ill-typed program was EVALUATED.

    $ medaka run single.mdk                   <-- CONTROL: same program, single file
    single.mdk:4:16: No impl of Display for Foo; add 'deriving Display' ...
    exit=1                                    <-- correct. Proves the gap is loader-specific.

`medaka build` gives a *third* message for the same program:

    error: emitter failed compiling main.mdk
    runtime error [E-PANIC]: no impl of method 'display' for type 'Foo' (slice 6)

So one program yields three different diagnoses: `check` ✓ right, `run` ✗ wrong, `build` ✗ third.

## Suspected location

The multi-module `run` path never consults `hadTypeErrors()`. AGENTS.md already documents the
same hole on the **bootstrap emit path** ("the bootstrap emit path does NOT gate on
`hadTypeErrors()`, so an ill-typed compiler source builds green"); this looks like the same
omission on the loader's `run` path. Note `checkRoute`/the `check` predicate already computes
the right answer — P0-1 (`96894932`) routed `run`/`build` through `check`'s full diagnostic
predicate, so this may be a case that P0-1 missed for the multi-module route specifically.

Found independently by two different agents in this session (the SQL-expression-parser and the
query-engine-unification tasks). Both lost real time to it: `intToString: not an Int` reads like
data corruption, so both went hunting for a bug in their own library code. Cost is high because
the misdirection is so plausible.

---

# BONUS — a SECOND, separate bug found while narrowing the above

**`medaka run` discards buffered stdout when the program panics. The built binary does not.**

This is a `run` ≠ `build` divergence, and it is a vicious debugging footgun: your `println`
traces vanish at exactly the moment you need them — when the program crashes.

    -- flush.mdk (WELL-TYPED; the panic is deliberate and unrelated)
    boom : Int -> Int
    boom 0 = panic "deliberate"
    boom n = n

    main : <IO> Unit
    main =
      println "PRINTED BEFORE PANIC"
      println "\{boom 0}"

    $ medaka run flush.mdk
    flush.mdk:2:15: runtime error [E-PANIC]: deliberate
                                       <-- "PRINTED BEFORE PANIC" is GONE

    $ medaka build flush.mdk -o /tmp/flush && /tmp/flush
    PRINTED BEFORE PANIC               <-- built binary flushes correctly
    runtime error [E-PANIC]: deliberate

Sanity check: without the panic, both lines print under `run`. So it is the panic path exiting
without flushing stdout, not a lost `println`.
