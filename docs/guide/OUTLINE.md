# Medaka Guide — Outline

A high-level overview / quickstart aimed at people who already know how to
program. Goal: get a reader productive and able to read Medaka code fast.
We teach *Medaka's way*, not programming from first principles.

Structure: **Foundations** (1–3) → **Medaka's worldview** (4–6) →
**Medaka's bets** (7–8) → **Scaling up** (9–10).

---

## 0. Landing — "What is Medaka?"
Positioning in ~1 screen. Pitch, a 15-line taste example, who this is for,
map of the docs that follow.
- Introduce: the pitch; a personality example (ADT + match + pipe + interp +
  bare IO block), unexplained; "you know programming, we teach Medaka."
- Defer: everything.

## 1. Quickstart — "Your first program"
Working program running in the playground in five minutes.
- Introduce: `main = ...` entry point; **`main` must be a zero-arg value, not
  `main () = ...`** (silent no-op); `println`; comments.
- Defer: modules, types, structure.

## 2. Values, Bindings & Types — "The shape of an expression"
- Introduce: literals; `let ... in`; immutability by default; **`let mut`
  (mutation is opt-in and visible)**; annotations/signatures; **inference means
  you rarely write types, but signatures document**; everything-is-an-expression.
- Defer: `Ref`, `<Mut>` mechanics, constrained signatures.

## 3. Functions — "Defining and composing behavior"
- Introduce: definitions; **multiple clauses with pattern-matching heads**;
  guards (`| cond = ...`, `otherwise`); lambdas (`x y => body`, **not curried**);
  `where`; **pipe `|>`, compose `>> <<`, sections `(+1)`/`(2 * _)`, backtick infix**.
- Defer: `function` keyword (one sentence), point-free zealotry.

## 4. Data Modeling — "Types that describe your domain" *(centerpiece)*
- Introduce: `data` sum types (payloads, type params); `record`; **pattern
  matching as the eliminator**; **exhaustiveness checking**; `Option`/`Result`
  as the null/exception replacement; `deriving`; functional update `{ p | f = v }`.
- Defer: `newtype` (a paragraph), nested-update depth, exhaustiveness internals.

## 5. Interfaces — "Ad-hoc polymorphism, Medaka-style"
- Introduce: `interface` + `impl`; the working vocabulary (`Eq`/`Ord`/`Debug`/
  `Display`/`Num`); **constraints via `=>`**; default methods; conditional impls
  (`impl Eq (List a) requires Eq a`); how `deriving` connects here.
- Introduce lightly: named instances (`@Additive`), `requires` at interface site.
- Defer: dict-passing internals, coherence, higher-kinded interfaces, `default impl`.

## 6. Working with Data — "Collections and the standard library"
- Introduce: `List` vs `Array` (when to reach for which); `Map`/`Set` + literals;
  strings + **interpolation `\{ }` tied to `Display`**; workhorse combinators
  (`map`/`filter`/`fold`) idiomatically with pipes; ranges. A "how do I..." cluster.
- Defer: `hash_map`/`mut_array`/`json`/`byteparser` etc. (link out); Foldable theory.

## 7. Effects & IO — "Doing things in the world" *(the signature chapter)*
Lead with the surprise.
- Introduce: **imperative IO is a bare indented block, not `do`** (IO is not a
  monad here); `let mut`, reassignment, `<Mut>`; **effect rows `<IO>`,
  `<Clock, IO>`** as the "what can this touch" contract; capabilities at a high
  level. Contrast with Haskell `IO a` and with unrestricted side effects.
- Defer: custom `effect` labels, capability platform, effect variables/open rows.

## 8. `do` and Monads — "Chaining computations that might fail or accumulate"
Deliberately AFTER effects, so `do` is never mistaken for "how you do IO."
- Introduce: `do` over `Option`/`Result` (short-circuit chains); `<-`; `pure`;
  "`do` abstracts over any monad."
- Defer: writing your own monad, laws, `Async`.

## 9. Modules & Projects — "Organizing a real codebase"
- Introduce: `import` forms; `export` / `public export` / abstract export;
  `medaka.toml` + layout; `medaka new`.
- Defer: re-export subtleties, cross-package module identity.

## 10. Tooling & Workflow — "The batteries"
- Introduce: `fmt`, `lint`, `check`, `test` (**doctests + `prop` tests**), `repl`;
  how these map to the playground. Doctests get a real example.
- Defer: `build`/backend/LLVM/WasmGC (appendix at most).

---

## Cross-cutting notes
- Chapters **4 and 7** carry the guide — over-invest there, keep the rest lean.
- Hold the **7-before-8** ordering: un-fuse IO from `do` in that order.
- Consider a **running example** threading 4–8 (one domain: todo/expense/parser).
- Use **"coming from X" sidebars** (Haskell/Rust/TS one-liners) to skip
  first-principles prose.
- **Out of scope** (link, don't teach): backends, dict-passing internals,
  exhaustiveness algorithm, layout formal rules, capability platform, custom
  effects, `Async`, higher-kinded interfaces, full stdlib list, `Ref` internals.
- **Gotcha callouts** where they arise: `main` must be a value (1); multi-arg
  lambdas aren't curried (3); `<-` forbidden in bare blocks (7/8); indentation
  is significant (1).
