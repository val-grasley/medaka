# Findings — overflow-page read + write (`sqlite/lib/{overflow,btree,dbwriter}.mdk`)

Task: implement overflow-page WRITE. The task brief stated overflow READ "already works,
byte-for-byte". **It did not** — see the preamble below. The work therefore covered both
directions, which is why this file leans on byte-array slicing, `<Mut>` effects, integer
arithmetic, and recursion over page chains.

## Preamble — the library bug that framed everything (NOT a language finding)

Recorded here because it changed the task's scope, not because it says anything about Medaka.

Overflow-page READ was silently corrupting data. `btree.decodeLeafCell` parsed the record
*contiguously* out of the file image starting at the cell's payload offset, with no notion of a
local-payload limit. For a spilling row it therefore ran straight off the end of the leaf page and
swallowed the overflow page's own 4-byte next-pointer as if it were payload. The *length* came out
right (which is presumably how it was mis-verified), so only a byte-level compare catches it:

```
$ sqlite3 big.db "SELECT v FROM t WHERE id=2" > sqlite_out.txt   # 10,000-byte TEXT
$ ./sqlite_reader big.db t | sed -n 2p | cut -d'|' -f2 > medaka_out.txt
$ cmp medaka_out.txt sqlite_out.txt
... differ: byte 1817, line 1        # == localPayloadSize(4096, 10005) - recordHeader + 1
```

Both directions now go through one shared threshold module (`sqlite/lib/overflow.mdk`), so the
writer is by construction the inverse of the reader. Gated by `sqlite/test/overflow_oracle.sh`.

---

## F1 — No way to scope `<Mut>`: a pure function cannot use a local mutable buffer

- **Category:** ergonomics / language design
- **Severity:** workaround-required (twice now, independently)
- **Repro:** the natural way to reassemble a spilled payload is a mutable destination buffer:

  ```medaka
  gatherPayload : Array Int -> Int -> Int -> Result String (Array Int)
  gatherPayload bytes payloadLen local =
    let dst = arrayMake payloadLen 0        -- <Mut>
    blit bytes pos dst 0 local              -- <Mut>
    ...                                     -- walk the chain, blitting each chunk
    Ok dst
  ```

- **Expected:** the mutation is *entirely local* — `dst` is allocated, filled, and returned frozen;
  no caller can observe it. A `runMut`/`runST`-style combinator should let me discharge `<Mut>` at
  the boundary and keep `gatherPayload` pure.
- **Actual:** there is none, so `<Mut>` is contagious. Adding it to `decodeLeafCell` would have
  propagated through `decodeCells` → `scanTablePage` → `sqlite.scanTableRows`/`readSchema` → every
  consumer including `select.mdk`, `aggregate.mdk`, `query.mdk`, `mutate.mdk` and all the demos.
  A read path has no business carrying a mutation effect.
- **Workaround:** re-implemented the gather with the *pure* `array.slice` + `array.concat` instead
  of `arrayMake` + `blit`. Correct, but it allocates a chunk list and then copies again, and
  `array.concat`'s lookup is O(outer) per element (`concatLookup` walks the outer array), so
  reassembling a 100 KB payload from a 25-page chain is O(25 × 100 000) rather than O(100 000).
- **Notes:** **this is the second independent hit of the same gap in this one library.**
  `sqlite/lib/recordenc.mdk:71-78` already carries a comment saying exactly this — it hand-rolls a
  pure `beSintBytes` rather than use `bytebuilder.emitBeSint`, "because there is no `runMut`
  scoping combinator, so using it would propagate `<Mut>` through `encodeRecord` and all callers."
  Two unrelated authors reached for a mutable buffer, hit the same wall, and paid the same tax.
  The pattern (allocate → fill → freeze → return immutable) is the single most common shape in
  binary-format code, and today Medaka makes you choose between an effect that infects your whole
  public API and a slower pure rewrite. `bytebuilder.buildArray` is a *special-case* freeze for one
  blessed type; the general combinator is missing.

## F2 — No bounds-checked `slice`: the only slice silently truncates

- **Category:** missing-stdlib
- **Severity:** annoyance (but it is the *exact* shape that hides corruption)
- **Repro:**
  ```medaka
  import array.{slice}
  main : <IO> Unit
  main =
    let a = arrayFromList [1, 2, 3]
    println (intToString (arrayLength (slice 0 99 a)))   -- 3
    println (intToString (arrayLength (slice 50 99 a)))  -- 0
  ```
- **Expected:** for a *parser*, an out-of-range slice means the input is truncated/corrupt/hostile
  and I want to hear about it. I expected an `Option`/`Result` variant to exist alongside.
- **Actual:** `3` then `0` — silently clamped, identical under `run` and `build`. This is documented
  (`stdlib/array.mdk:154`), so it is not a bug; the *gap* is that the checked variant doesn't exist.
- **Workaround:** hand-rolled a `requireBytes : Array Int -> Int -> String -> Result String Unit`
  guard in `btree.mdk` and call it before every `slice` on the file image, so a truncated `.sqlite`
  yields `Err "overflow page 7: file truncated (need 28680 bytes, have 20480)"` instead of a short
  read that decodes to garbage.
- **Notes:** `btree.mdk` already had to do this once for single bytes (`byteAt`, which exists purely
  to wrap `arrayGetUnsafe`), so the file now carries two hand-written bounds-check wrappers.
  Suggest `array.sliceChecked : Int -> Int -> Array a -> Option (Array a)` (or `Result`).
  Related: `arrayGetUnsafe` is what `slice` uses internally, so "never panics" is achieved by
  clamping rather than by checking — a reader of the doc could reasonably expect the opposite
  trade.

## F3 — "unexpected a number; expected a dedent" — ungrammatical, and doesn't name the rule

- **Category:** error-message
- **Severity:** annoyance
- **Repro:**
  ```medaka
  f : Int -> Int -> Int -> Result String Int
  f a b c = Ok (a + b + c)

  main : <IO> Unit
  main = match f
    1
    2
    3
    Err e => println e
    Ok n => println (intToString n)
  ```
- **Expected:** something naming the actual rule — that a `match` scrutinee may not be wrapped onto
  the lines that hold the arms, because at that indentation an argument and an arm are
  indistinguishable. Ideally with the fix ("bind the scrutinee with `let` first").
- **Actual:**
  ```
  r1.mdk:6:2: unexpected a number; expected a dedent
    |
  6 |   1
    |   ^
  ```
  Two problems: the article is broken ("unexpected **a** number" — the token-class name is being
  interpolated into a slot expecting a bare noun), and "expected a dedent" describes the *lexer's*
  internal state, not anything the programmer wrote. Nothing points at the `match` on line 5, which
  is the actual cause.
- **Workaround:** `let res = f 1 2 3` then `match res`. (This is what `sqlite/overflow_demo.mdk`
  does in three places.)
- **Notes:** `medaka fmt` is NOT complicit — I checked, it correctly refuses to wrap a long `match`
  scrutinee and leaves the over-long line intact. This is purely a diagnostic-quality issue on
  hand-written code. Per `compiler/ERROR-QUALITY.md` this scores badly on "names the rule" and
  "actionable fix". Likely `compiler/frontend/parser.mdk` + whatever renders token classes.

## F4 — The `sqlite/` tree is not `fmt`-clean under the session's own compiler

- **Category:** tooling
- **Severity:** annoyance (but it silently inflates every diff in this tree)
- **Repro:** on the `sqlite-arc` base, with the prebuilt `./medaka` this session was told to use:
  ```
  $ ./medaka fmt --check sqlite/lib/varint.mdk
  sqlite/lib/varint.mdk: not formatted
  ```
  (`varint.mdk` is a file no one in this session touched.)
- **Expected:** `AGENTS.md` says "the whole tree is `medaka fmt`-clean" and a pre-commit hook
  enforces it, so `fmt --check` on an untouched file should pass.
- **Actual:** it fails. The cause is benign but the effect is not: the compiler has since migrated
  array indexing from `arr.[i]` to bare `arr[i]` (both parse — `compiler/frontend/parser.mdk:623`
  builds the same `EIndex` node — but the printer now only emits the bare form). Files still
  carrying the old spelling are therefore "unformatted" under the current binary.
- **Workaround:** none needed, but be aware: because the hook requires `fmt --write` on any file you
  touch, **touching a `.[`-using file drags an unrelated `.[i]` → `[i]` normalization into your
  diff.** That is why `sqlite/lib/{btree,sqlite}.mdk` in this branch show indexing churn on lines I
  never edited. `sqlite/lib/varint.mdk` is still stale because I had no reason to touch it.
- **Notes:** worth one sweep of `medaka fmt --write` over the repo to retire the old spelling in one
  commit, rather than letting it leak into unrelated feature diffs one file at a time.
  `SYNTAX.md:185` also still documents `arr.[0]` as *the* indexing syntax, which is now the
  non-canonical spelling — a doc fix.

---

## Checked, nothing to report

- **Integer / bit arithmetic.** The threshold math (`(usable - 12) * 32 / 255 - 23`, and
  `m + (payloadLen - m) % overflowCapacity usable`) behaved exactly as C would: `/` truncates,
  `%` binds tighter than `+`, and the result matched real `sqlite3`'s page layout on the nose (size
  4053 stays local, 4054 spills — confirmed against sqlite3's own `dbstat`). No surprises, no
  precedence traps. `shiftLeft b0 24` on a 4-byte BE page number never came near an overflow edge.
- **`check` vs `run` vs `build` divergence.** None found in this work. Everything shipped here is
  gated on a native `medaka build` binary; `array.slice`'s clamping behaves identically under the
  interpreter and the native build.
- **The three known landmines.** No new variants surfaced. I deliberately used a 3-tuple
  `(Int, Array Int, Array Int)` rather than a record for the writer's pending-row type, specifically
  to stay clear of the cross-module record-field-slot miscompile — worth noting that the landmine
  is actively shaping code away from the more readable construct. No partially-applied constructors
  were passed as values; no `deriving (Eq)` on `Array`-bearing types.
- **Recursion over page chains.** Deep recursion (a 25-page chain, and `concat` over 26 chunks) was
  fine; the 256 MB worker stack never came into it.
