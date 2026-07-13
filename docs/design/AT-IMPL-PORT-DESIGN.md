# `@Impl` Named-Instance-Selection Hint — Native Port Design

**Status:** OPEN — genuinely not implemented. `currentImplHintRef` (the
module-level ref this design proposes) does not exist anywhere in
`compiler/types/typecheck.mdk`; the native `@Impl` typecheck arm has not been
built. What remains: the two-stage gap in the TL;DR below (typecheck `EApp(f,
EVar "@hint")` arm + route-key threading; eval needs no change). ⚠️ **The `lib/`
oracle this design mirrors line-for-line was removed 2026-06-26** (`06356a80`) —
every `lib/*.ml:NNN` citation below is now a dead path and cannot be re-checked;
treat them as a historical behavior-spec (what the removed OCaml implementation
did) to match, not as live pointers.

Date: 2026-06-23. Oracle = frozen `lib/` (complete at the time). Native = `compiler/` (gap).

## TL;DR

The feature is **80% already present** in native. Parser: done (both sides lower
`@Name` → `EVar "@Name"`). Resolve: **done** (`checkVar` exempts `@`-prefixed
names via `isHint`, mirroring `lib/resolve.ml:591`). Named-impl **storage**: done
(`DImpl.name : Option String` survives, and `implKeyTc`/`keyEntryOf` already bake
the name into the canonical impl key `iface|args|name`). The **value rep already
distinguishes named impls by key** (`VTypedImpl`'s `key` field), so **native needs
NO `VNamedImpl` variant** — it uses key-narrowing where the oracle uses value
tagging.

The actual gap is two stages:
1. **typecheck** — no `EApp(f, EVar "@hint")` arm. The hint `EVar` falls into
   `inferVar` → `unboundVarFresh` → the user-visible `Unbound variable: @Additive`
   (this is a TYPECHECK error, not a resolve one — verified below). Need: a hint
   arm that (a) drops the hint arg from `f`'s type, and (b) threads the impl name
   into the route stamp so `resolveSite` stamps `RKey (implKeyTc iface tys (Some
   name))` instead of the bare head tag.
2. **eval** — no behavior change needed IF the route already carries the named
   key: `narrowMethod`/`pickByTag` select the `VTypedImpl` whose `key` matches.
   Verify the multi-impl-same-head VMulti actually carries both named candidates
   keyed distinctly (it should — `keyEntryOf` emits one `KeyEntry` per impl with
   `implKeyTc … name`).

`build` (LLVM) is IN SCOPE per the goal but is a thin follow-on: slice-6/7 dispatch
keys symbols by the same route key, so a correctly-stamped named `RKey` flows
through; needs verification, not new machinery.

## 1. Native has-vs-needs (cited)

### HAS
- **Parser** — `compiler/frontend/parser.mdk:632-638` `parseAtHint` → `EVar ("@"
  ++ name)`. Mirrors `lib/parser.mly`. DONE both sides.
- **Resolve exemption** — `compiler/frontend/resolve.mdk:312-319` `checkVar`, first
  guard `| isHint n = []` (`isHint` = `startsWithAt`, line 332-336). Mirrors
  `lib/resolve.ml:591`. DONE. (Empirically: `medaka check` still prints
  `Unbound variable: @Additive`, but that string comes from TYPECHECK
  `unboundVarFresh` at `typecheck.mdk:3399/3641`, NOT resolve — `resolve.mdk:964`
  renders the same text. The resolve pass already passes the hint through.)
- **Named-impl storage** — `compiler/frontend/ast.mdk:294` `DImpl { … name :
  Option String … }`. The name survives the whole pipeline.
- **Canonical key embeds the name** —
  `compiler/types/typecheck.mdk:5901-5909` `keyEntryOf` → one `KeyEntry` per impl;
  `implKeyTc iface tys name` (`:5912-5918`) = `iface ++ "|" ++ args ++ "|" ++
  fromOption "" nm`, byte-identical to `lib/ast.ml`'s `impl_key`. So two impls of
  `Combine Int` named `Additive`/`Multiplicative` already produce DISTINCT keys.
- **Value rep keyed by impl key** — `compiler/eval/eval.mdk:88` `VTypedImpl String
  String (List Int) Int Value` (2nd field = key). `narrowMethod`
  (`eval.mdk:776-790`) → `pickByTag` → `hasTag` selects the VMulti candidate whose
  key matches the route key. This is the native analogue of the oracle's
  `VNamedImpl` + `candidate_key`/key-narrow (`lib/eval.ml:592-690`).
- **Coherence exemption for named impls** —
  `compiler/types/typecheck.mdk:5383` `cohImplsOfMid` records `isSome name` as the
  `isNamed` flag; `cohAnonConflict` (`:5557`, `| named = cohConflictWith e1 rest`)
  SKIPS the OverlappingImpls error when either impl is named. Mirrors
  `lib/typecheck.ml:4176`. DONE — so two named overlapping impls already coexist
  without a coherence error. (Orphan exemption `lib/typecheck.ml:4241`: confirm
  native's orphan check — if native has no orphan check, no exemption is needed;
  if it does, add the same `isSome name` skip. Low priority — orphan checks are
  cross-module-import-only.)

### NEEDS
- **typecheck `EApp(f, EVar "@hint")` arm** — absent. The crux.
- **route-stamp threading of the hint name into `implKeyTc … (Some name)`** —
  `resolveSite` (`typecheck.mdk:5152-5162`) currently builds the key from
  `keyForSite keyTable name resultMono` (head-tycon / C7-collision logic). With two
  same-head impls (`Additive`/`Multiplicative`, both head `Int`), `keyForSite`
  cannot pick between them from the result type alone — the HINT must override.
- **eval** — likely NO change; verify key-narrow reaches the right candidate.
- **build** — verify; likely no new machinery.

## 2. Per-stage mirror (oracle → native, file:line)

### Resolve — DONE (no work)
- Oracle: `lib/resolve.ml:591` (`EVar n when n.[0]='@' -> ()`).
- Native: `compiler/frontend/resolve.mdk:314` (`| isHint n = []`). Already present.
- ACTION: none. Add a resolve fixture (regression) only.

### Typecheck — the main work
- Oracle anchors: `lib/typecheck.ml:2271-2278` — two arms,
  `EApp(f, EVar hint)` and `EApp(f, ELoc(_, EVar hint))` with `hint.[0]='@'`. Each
  sets `current_impl_hint := Some (substring-after-@)`, infers `f`, clears the
  hint. The pending hint is read at the method occurrence to narrow dispatch to
  the named impl. Ambiguity diagnostic `lib/typecheck.ml:1248` ("…use @ImplName to
  disambiguate"); `UnknownImplName` for a bad name.
- Native target: `compiler/types/typecheck.mdk:3701` `inferAppExpr` (the `match
  lamUnderLoc x` … else `inferApp …` arm). Plus `infer env (EApp f x)` dispatch at
  `:2745`.
- Native mirror plan:
  1. Add an `inferAppExpr` (or a guard in `infer (EApp …)`) case detecting `x =
     EVar h` / `ELoc(_, EVar h)` with `isHint h`. Strip the `@`, set a NEW
     module-level `currentImplHintRef : Ref (Option String)` (mirror
     `current_impl_hint`; reset by `resetState` like the other refs around
     `typecheck.mdk:1357`), `infer env f`, then clear. RETURN `infer env f`'s type
     (do NOT type the hint as an argument — it is dropped, exactly like the oracle).
  2. Thread the hint into the route stamp. The cleanest seam: at the point where a
     method occurrence's pending site is RECORDED (the `recordSite`/`pendingSites`
     machinery feeding `resolveSites`), capture `currentImplHintRef.value` into the
     site so `resolveSite` (`typecheck.mdk:5152`) can, when a hint is present,
     build `routeKey = implKeyTc iface tys (Some hintName)` for the matching impl
     instead of `keyForSite`. Concretely: extend the pending-site tuple (or stash a
     parallel hint on the site's `tagRef` capture) with `Option String`; in
     `resolveSite`'s `RKey` branch, if the site has a hint, look up the impl in
     `keyTable`/`buildKeyTable` whose `iface` + head match AND whose name = hint,
     take ITS `implKeyTc` key; if no such impl → push an `UnknownImplName`-style
     error.
  3. Ambiguity diagnostic: add native `AmbiguousImpl` ("Ambiguous: multiple impls
     of … — use @ImplName to disambiguate") so an UNHINTED ambiguous use is
     diagnosed. NOTE: native may currently route an unhinted ambiguous same-head
     site to the first matching key silently (the existing `keyForSite` C7 path
     only upgrades to canonical key on head COLLISION but still picks deterministi-
     cally). The oracle defers this to `check_method_usages` (lazy). For parity,
     stamping the hint is the priority; the unhinted-ambiguous diagnostic is a
     secondary parity item (gate `diff_compiler_errors`).
- Coherence/orphan exemption: coherence DONE (`:5557`). Orphan — audit whether
  native has an orphan-impl check; if yes, add `isSome name` skip mirroring
  `lib/typecheck.ml:4241`; if no native orphan check exists, nothing to do.

### Eval — verify, likely no change
- Oracle anchors: `lib/eval.ml:683-690` (`VNamedImpl(n, inner)` apply arm) + the
  variant `:37`, pp `:269`, tag `:588`, key-narrow `:595`. The oracle's hint arm
  passes an already-narrowed `VNamedImpl` through.
- Native: there is NO `VNamedImpl`. The named impl is a `VTypedImpl` whose `key`
  field = the named key. The route stamped by typecheck (step 2 above) carries
  that key; `methodAtNarrow … (RKey key _)` (`eval.mdk:865`) → `narrowMethod v key`
  → `pickByTag` selects the candidate with the matching key. So the named impl is
  reached by the EXISTING key-narrow path.
- The audit's old pointer `eval.mdk:746` (`@Name`→VUnit applied) is STALE: resolve
  now passes the hint through and the symptom moved to typecheck `unboundVarFresh`.
  The hint `EVar` should never reach eval as a value at all — typecheck's new arm
  DROPS it before the `EApp` survives into the marked/dict-passed tree. VERIFY:
  after the typecheck arm strips the hint arg, the residual marked tree applies the
  method directly to the real args (no stray `@hint` EApp). If the marker pass
  (`method_marker`-equivalent) runs on a tree that STILL contains the `@hint` EApp,
  add the hint-strip there too (mirror: the oracle drops it during inference, so
  the elaborated/dict-passed tree the eval driver sees has no hint node).
- ACTION: probably none beyond verification; if a stray hint node survives into
  eval, add an `EApp(f, EVar h)`-with-hint strip in the desugar/marker rewrite or
  in eval's `EApp` arm (resolve to `inner` of `f`, ignore the hint).

## 3. Dispatch-model interaction (the crux)

OCaml uses **value tagging**: `VNamedImpl(name, inner)` wraps the chosen impl, and
the apply arm + `candidate_key` carry the name through partial application.

Native uses **key-narrowing**: every impl is a `VTypedImpl t key pos seen inner`
whose `key` (built by `implKeyTc iface tys name`) ALREADY encodes the name. The
dispatch route `RKey key` selects the candidate by key. So:

> **Native mechanism choice: a STAMPED IMPL KEY, not a new value variant.**
> The `@hint` makes typecheck stamp `RKey (implKeyTc iface tys (Some name))` for
> the method occurrence. No `VNamedImpl`, no new `Route` constructor, no new
> `Value` constructor. This reuses `keyEntryOf`/`narrowMethod`/`pickByTag`
> verbatim and is the minimal, model-consistent port.

Why this is correct: the C7 work already proved native can route two same-head
impls to distinct keys via `implKeyTc` and have `narrowMethod` pick the right
`VTypedImpl` by `key`. A named hint is exactly the C7 case where the disambiguator
is the user-supplied name instead of the arg-type pattern. The infrastructure to
narrow-by-key is built; the hint just supplies the key.

Backend/emitter (`build`): slice-6 return-position dispatch lowers `RKey key` to a
direct call to the impl's lifted symbol `@mdk_impl_<key>_<method>` (or an if-chain
for `RDict`). Since the named key is a valid `RKey` produced by the same stamp,
the emit path should route it with no new code — BUT the impl-symbol naming must
include the name component of the key so the two same-head named impls lower to
DISTINCT symbols (mirror of the cross-module mangling discipline). VERIFY the
impl-symbol mangling keys off the full `implKeyTc` (with name), not the bare head
tag. If it keys off the bare head only, two named same-head impls collide at emit
→ add the name to the impl-symbol key. This is the one real backend risk.

## 4. Staging, gates, fixtures, risks

### Staging (each independently checkable)
- **S0 (verify baseline)** — confirm resolve passes the hint (it does);
  confirm the `Unbound` error is typecheck-origin (it is, `unboundVarFresh`).
- **S1 (typecheck infer arm)** — add `currentImplHintRef` + the `inferAppExpr`
  hint arm that drops the hint arg and infers `f`. After S1: `medaka check`
  should stop reporting `Unbound variable: @Additive` (no more spurious value
  lookup). Gate: `diff_compiler_typecheck`, `diff_compiler_check_json`,
  `diff_compiler_errors`.
- **S2 (route stamp)** — thread the hint into `resolveSite` so the method site
  gets `RKey (implKeyTc … (Some name))`. Add `UnknownImplName` for a bad hint.
  Gate: `diff_compiler_typecheck`, `diff_compiler_errors`.
- **S3 (eval verify)** — `medaka run` on the repro must print `7` then `12`.
  Gate: `diff_compiler_eval`, `diff_compiler_dict`. If a stray hint node survives,
  add the strip (marker/eval).
- **S4 (ambiguity diagnostic, parity)** — native `AmbiguousImpl` for an UNHINTED
  ambiguous use. Gate: `diff_compiler_errors`. Lower priority; can ship after S3.
- **S5 (build)** — `medaka build` on the repro; verify impl-symbol mangling
  includes the name. Gate: `diff_compiler_llvm`/`_build`, `selfcompile_fixpoint`.

### Gates
- `diff_compiler_resolve*` — should stay green throughout (resolve unchanged).
- `diff_compiler_typecheck` / `diff_compiler_errors` / `diff_compiler_check_json`
  — go from native-diverges to native-matches on the new fixtures (S1/S2/S4).
- `diff_compiler_eval` / `diff_compiler_dict` — S3.
- `diff_compiler_llvm` / `diff_compiler_build` + `selfcompile_fixpoint` — S5.
- `bootstrap_*` / fixpoint — the compiler self-compiles after each native edit.
  FOOTGUN (from memory): `FORCE_EMITTER_REBUILD=1 make medaka` after a
  graph/typecheck change; rebuild `./medaka` fresh before trusting `diff_native_cli`
  (stale-binary footgun).

### Fixtures (historical: at design time, mirrored `test/test_eval.ml:1106`
Phase-30 spec — `test/test_eval.ml` no longer exists, removed with `lib/`
2026-06-26; use it only as a behavior-spec reference for what to test, add
fixtures directly to the native `test/*_fixtures/` corpora instead)
- `combine @Additive 3 4` → 7; `combine @Multiplicative 3 4` → 12 (the
  `named_impl_src` cases + `@First` three-impl case).
- The typed-path regression (`t_named_additive_typed`) — ensures the `run`
  pipeline (mark → typecheck RKey-stamp → eval) dispatches, not just the untyped
  fallback. This is the case that catches a stamp-vs-eval mismatch.
- An `UnknownImplName` fixture (`combine @Nonexistent 3 4`) → error.
- An unhinted-ambiguous fixture (S4) → `AmbiguousImpl` ("use @ImplName…").
- Add to native gate corpora (`test_eval.ml`, which drove the now-removed OCaml
  oracle, is gone — native `test/*_fixtures/` is the only place fixtures live now).
  Note the `diff_fixtures` golden-add footgun (whole-corpus recapture) — prefer the
  smallest fixture set that exercises stamp + narrow + error.

### Risk register
- **R1 (main risk): dispatch-model seam.** The hint must reach `resolveSite` as a
  per-site `Option String`. The pending-site tuple plumbing is the delicate part —
  capture the hint at the RIGHT method occurrence (the `combine` site, not the
  enclosing `debug`/`println`). The oracle's `current_impl_hint` is a single
  mutable cell read by "the next method usage"; native must capture it at site
  RECORD time (when the method's `tagRef` is created during inference of `f`), then
  clear. Mis-scoping → the hint leaks to an unrelated method.
- **R2: impl-symbol collision at emit (build).** If impl symbols key off bare head
  tag, two named same-head impls collide. Mitigate: key off full `implKeyTc`.
- **R3: regress recent resolve work.** The just-added `standaloneValuesRef` /
  `AmbiguousOccurrence` use-time-ambiguity logic (commit 421a4bd) and `isHint`
  ordering in `checkVar` must stay intact — do NOT touch resolve. The port is
  typecheck+eval only, so resolve gates should not move.
- **R4: stray hint node into marker/eval.** If the marked/dict-passed tree still
  contains the `@hint` EApp, eval mis-applies. Mitigate per S3 verify-then-strip.
- **R5: unhinted-ambiguous divergence.** Native may silently pick first; oracle
  diagnoses lazily. Acceptable to defer to S4 — track as a known native/oracle
  divergence until then.

### `lib/` (frozen oracle)
NO edit. The oracle is complete; this is native catching up. The diff gates should
move from native-diverges to native-matches. If a gate reveals an oracle bug
(unlikely here), surface it — don't silently edit the frozen oracle.
