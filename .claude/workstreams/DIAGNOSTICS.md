# Workstream: DIAGNOSTICS

**Owns:** error-message quality, and wrong/fabricated source locations.
**Touches:** `compiler/driver/diagnostics.mdk`, `compiler/frontend/`.

Read `compiler/ERROR-QUALITY.md` (the rubric) and `compiler/DIAGNOSTIC-CODES-DESIGN.md` (the
taxonomy) first. A new diagnostic needs a **stable code**.

---

## D-1 · A FABRICATED source location: `1:0`

Type-mismatch diagnostics can be reported at `1:0` — a **default** location, not the real one.
So the caret points at whatever is on line 1, which in one agent's case was a comment.

**A diagnostic with no location must SAY it has no location, not invent one.** A confidently
wrong location is worse than none: it sends the reader to the wrong place and they trust it.

## D-2 · "Clauses of 'X' must be contiguous" for a DUPLICATE DEFINITION

The real problem is **two unrelated functions sharing a name**. The message advises you to
"group all clauses together" — which would **merge two different functions**. Actively harmful
advice.

Should be: *"'X' is already defined at line NNN."* (Paired with COMPILER-SOUNDNESS S-2, where
the same duplicate **segfaults the emitter** before you ever see this message.)

## D-3 · Leading-`->` continuation in a multi-line type signature is rejected

Rejected with an **indentation** error, which is not what is wrong. AGENTS.md advertises
leading-operator continuation as supported. Either support it or say the true reason.

## D-4 · `public export` on a function is a parse error with an unhelpful message

`public export f : ...` yields *"expected data after public export"*. `public` applies **only to
`data`**; a function is just `export`. The message names the token it wanted but never says the
actual fix. (This exact confusion — `export data` exporting a type *abstractly* — is what put
unbound constructors on `main`.)

## D-5 · `medaka check` prints its scheme dump with no trailing newline

`main : Unitexit=0` in a harness. Cosmetic, but it mangles any shell pipeline that appends.

## D-6 · No way to ask which pass raised a diagnostic

Diagnosing a typechecker bug required **rebuilding the compiler three times (~5 min each)** just
to append `currentFn` to a type-mismatch message. A `MEDAKA_TC_TRACE=1` that tags each
diagnostic with the pass + `currentFn` that raised it would have halved that task.
