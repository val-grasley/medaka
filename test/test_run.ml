open Medaka_lib
open Eval

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at %d:%d"
                pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let capture_run src =
  let prog = parse src in
  let buf = Buffer.create 64 in
  output_hook := Buffer.add_string buf;
  (try ignore (eval_program prog)
   with e -> output_hook := print_string; raise e);
  output_hook := print_string;
  Buffer.contents buf

let assert_output src expected () =
  let actual = capture_run src in
  if actual <> expected then
    failwith (Printf.sprintf "Expected:\n%s\nGot:\n%s\n\nSource:\n%s"
                expected actual src)

let assert_run_err src () =
  match (try Some (capture_run src) with Eval_error _ -> None) with
  | None -> ()
  | Some out ->
    failwith (Printf.sprintf "Expected runtime error but got:\n%s\n\nSource:\n%s" out src)

(* Full pipeline: desugar → resolve → mark (Phase 69) → typecheck → eval.
   Unlike capture_run this runs the typechecker, which is what stamps each
   EMethodRef with its resolved impl key — required to exercise return-position
   and multi-parameter dispatch. *)
let capture_run_typed src =
  let prog = Desugar.desugar_program (parse src) in
  (match Resolve.resolve_program prog with
   | [] -> ()
   | (err, _) :: _ -> failwith ("resolve error: " ^ Resolve.pp_error err));
  (* Phase 84: two-pass elaboration, matching the run/test drivers — promotes a
     polymorphic-monad do-block's inferred Applicative so `pure` routes by the
     caller's monad.  (Single-pass programs collapse to one typecheck.) *)
  let (_marked, combined, _schemes, _warnings) = Elaborate.elaborate prog in
  let buf = Buffer.create 64 in
  output_hook := Buffer.add_string buf;
  (try ignore (eval_program ~prelude:false combined)
   with e -> output_hook := print_string; raise e);
  output_hook := print_string;
  Buffer.contents buf

let assert_output_typed src expected () =
  let actual = capture_run_typed src in
  if actual <> expected then
    failwith (Printf.sprintf "Expected:\n%s\nGot:\n%s\n\nSource:\n%s"
                expected actual src)

(* ── Phase 69: return-position dispatch ──────────────────────────────────── *)
(* `decode : Int -> a` discriminates on its RESULT type, which no argument
   carries.  Pre-Phase-69 the first registered impl always won (and `if <str>`
   would panic); now the typechecker's chosen impl is recorded per call site. *)
let t_return_position_dispatch = assert_output_typed
  {|interface Decode a where
  decode : Int -> a

impl Decode String where
  decode n = "S"

impl Decode Bool where
  decode n = n > 0

main : <IO> Unit
main =
  println (decode 1)
  if (decode 1 : Bool) then println "T" else println "F"
  if (decode 0 : Bool) then println "T" else println "F"
|}
  "S\nT\nF\n"

(* ── Phase 69: multi-parameter dispatch ──────────────────────────────────── *)
(* Both impls share the first type arg (Int), so the runtime arg tag can't tell
   them apart — selection must follow the result type the checker resolved. *)
let t_multiparam_dispatch = assert_output_typed
  {|interface Convert a b where
  convert : a -> b

impl Convert Int String where
  convert n = "str"

impl Convert Int Bool where
  convert n = n > 0

main : <IO> Unit
main =
  println (convert 5 : String)
  if (convert 5 : Bool) then println "T" else println "F"
|}
  "str\nT\n"

(* ── Phase 69.x: dictionary passing ──────────────────────────────────────── *)
(* `tag : Int -> a` discriminates on its result, which the helper `mk` is
   *polymorphic* over — the type is concrete only at `mk`'s call sites, not in
   `mk`'s body.  Pre-69.x the body's `tag` left its EMethodRef unstamped and the
   first impl always won (both calls would print the same impl's result); 69.x
   passes `mk` a runtime dictionary so each call routes to the impl the caller's
   annotation chose.  The argument to `tag` is an `Int` in both impls, so arg-tag
   dispatch genuinely cannot tell them apart — distinct output proves the dict. *)
let t_dict_polymorphic_helper = assert_output_typed
  {|interface Tag a where
  tag : Int -> a

impl Tag String where
  tag n = "S"

impl Tag Bool where
  tag n = n > 0

mk : Tag a => Int -> a
mk n = tag n

main : <IO> Unit
main =
  println (mk 5 : String)
  if (mk 5 : Bool) then println "T" else println "F"
|}
  "S\nT\n"

(* Transitive pass-through: `mk2` (constrained) calls `mk` (constrained), so
   `mk2`'s dictionary parameter must forward into `mk` (RDict route), without
   re-resolving at the inner site. *)
let t_dict_transitive = assert_output_typed
  {|interface Tag a where
  tag : Int -> a

impl Tag String where
  tag n = "S"

impl Tag Bool where
  tag n = n > 0

mk : Tag a => Int -> a
mk n = tag n

mk2 : Tag a => Int -> a
mk2 n = mk n

main : <IO> Unit
main =
  println (mk2 5 : String)
  if (mk2 5 : Bool) then println "T" else println "F"
|}
  "S\nT\n"

(* Phase 136: a `=>`-signed mutually-recursive pair threads its constraint dict
   through both members (pingEq forwards its Eq dict into pongEq and back), and
   the merged group is reused at two element types.  Guards the dict-passing
   interaction the merge could have broken — a stale dict-route var id would
   surface here as an unbound `$dict_…` at eval, not as a type error. *)
let t_mutual_rec_dict = assert_output_typed
  {|pingEq : Eq a => a -> Int -> Bool
pongEq : Eq a => a -> Int -> Bool
pingEq x 0 = True
pingEq x n = pongEq x (n - 1)
pongEq x 0 = x == x
pongEq x n = pingEq x (n - 1)

main : <IO> Unit
main =
  println (pingEq (3 : Int) 4)
  println (pingEq "hi" 2)
|}
  "True\nTrue\n"

(* Phase 69.x-e: method-level constraint dict (foldMap's `Monoid m`) routed at a
   *concrete* call site.  foldMap's default body resolves `empty` to the chosen
   Monoid impl via a dictionary (not arg-tag), so the user `Sum` monoid folds. *)
let t_foldmap_method_dict_concrete = assert_output_typed
  {|data Sum = MkSum Int

impl Semigroup Sum where
  append (MkSum a) (MkSum b) = MkSum (a + b)

impl Monoid Sum where
  empty = MkSum 0

unwrap (MkSum n) = n

main : <IO> Unit
main =
  let r = foldMap MkSum [1, 2, 3, 4]
  if unwrap r == 10 then println "OK" else println "BAD"
|}
  "OK\n"

(* Phase 69.x-e: method-level constraint dict routed *polymorphically*.  `combine`
   carries `Monoid m` and calls foldMap, so its dictionary forwards transitively
   into foldMap's method-level slot; two concrete call sites pick distinct
   monoids (Sum=10, Prod=24) from the same polymorphic body. *)
let t_foldmap_method_dict_polymorphic = assert_output_typed
  {|data Sum = MkSum Int
data Prod = MkProd Int

impl Semigroup Sum where
  append (MkSum a) (MkSum b) = MkSum (a + b)
impl Monoid Sum where
  empty = MkSum 0

impl Semigroup Prod where
  append (MkProd a) (MkProd b) = MkProd (a * b)
impl Monoid Prod where
  empty = MkProd 1

combine : Monoid m => (Int -> m) -> m
combine f = foldMap f [1, 2, 3, 4]

sumU (MkSum n) = n
prodU (MkProd n) = n

main : <IO> Unit
main =
  if sumU (combine MkSum) == 10 then println "S" else println "BAD"
  if prodU (combine MkProd) == 24 then println "P" else println "BAD"
|}
  "S\nP\n"

(* Phase 69.x-e: an *explicit* foldMap impl (not the default) coexists with the
   prelude default fallback.  dict_pass prepends the Monoid dict param to the
   explicit impl too, so eval's arg-tag dispatch positions shift by the dict
   arity — the `Pair` argument must still select the Pair impl, and `[..]` the
   List default. *)
let t_foldmap_explicit_impl_offset = assert_output_typed
  {|data Pair a = MkPair a a
data Sum = MkSum Int

impl Semigroup Sum where
  append (MkSum a) (MkSum b) = MkSum (a + b)
impl Monoid Sum where
  empty = MkSum 0

impl Foldable Pair where
  fold f acc (MkPair x y) = f (f acc x) y
  foldRight f acc (MkPair x y) = f x (f y acc)
  toList (MkPair x y) = [x, y]
  isEmpty _ = False
  length _ = 2
  foldMap f (MkPair x y) = append (f x) (f y)

unwrap (MkSum n) = n

main : <IO> Unit
main =
  if unwrap (foldMap MkSum (MkPair 3 4)) == 7 then println "P" else println "BAD"
  if unwrap (foldMap MkSum [1, 2, 3, 4]) == 10 then println "L" else println "BAD"
|}
  "P\nL\n"

(* Phase 96: a *nullary* return-position interface method (`empty`, `minBound`,
   `maxBound`) dispatched purely by its result type.  The typechecker stamps an
   RKey route correctly, but eval must strip the chosen impl's dispatch wrapper
   before the bare value (never applied) flows into the program — otherwise it
   leaks a VTypedImpl and downstream debug / pattern-match / append panic. *)
let t_nullary_empty_stdlib_monoid = assert_output_typed
  {|e : List Int
e = empty

main : <IO> Unit
main =
  println (debug e)
  println (debug (empty : List Int))
  println (debug (append (empty : List Int) [1, 2]))
|}
  "[]\n[]\n[1, 2]\n"

let t_nullary_empty_custom_monoid = assert_output_typed
  {|data Wrap = Wrap Int

impl Semigroup Wrap where
  append (Wrap a) (Wrap b) = Wrap (a + b)
impl Monoid Wrap where
  empty = Wrap 0

unwrap (Wrap n) = n

e : Wrap
e = empty

main : <IO> Unit
main =
  if unwrap e == 0 then println "OK" else println "BAD"
  if unwrap (append e (Wrap 5)) == 5 then println "OK" else println "BAD"
|}
  "OK\nOK\n"

(* Phase 103 facet (b): a nullary return-position method on a `requires`-bearing
   impl whose body is a bare constructor.  typecheck stamps res_impl_dicts for it
   (return-position + requires), but dict_pass adds no param (the body uses no
   dict), so eval used to over-apply the dict to the terminal value and error
   "no matching impl for dispatch".  It must now evaluate to the constructor. *)
let t_nullary_empty_requires = assert_output_typed
  {|interface MyOrd a where
  myCompare : a -> a -> Int
interface Sg a where
  appnd : a -> a -> a
interface Mn a requires Sg a where
  mt : a

data Tree k = Leaf | Node k

impl MyOrd Int where
  myCompare a b = 0
impl Sg (Tree k) requires MyOrd k where
  appnd a b = a
impl Mn (Tree k) requires MyOrd k where
  mt = Leaf

isLeaf Leaf = True
isLeaf (Node _) = False

t : Tree Int
t = mt

main : <IO> Unit
main =
  if isLeaf t then println "OK" else println "BAD"
|}
  "OK\n"

(* Phase 83/84 #5: structured/recursive instance dictionaries.  A recursive
   `requires` instance (`impl Default (List a) requires Default a where def =
   [def]`) used at a *nested* type needs a structured runtime dict that carries
   the element dict at every level — the flat `VDict of string` could only encode
   one impl key, so `def : List (List Int)` panicked "no matching impl".  Each
   level's `def` reads its dict's key (List impl) and forwards the dict's own
   `requires` (the inner element dict) into the body, unfolding until the base
   `Default Int`.  Single-level (`[0]`) is the prior working baseline; two- and
   three-level, plus a mixed Option/List nesting, exercise the recursion. *)
let t_nested_instance_dicts = assert_output_typed
  {|interface Default a where
  def : a

impl Default Int where
  def = 0

impl Default (List a) requires Default a where
  def = [def]

impl Default (Option a) requires Default a where
  def = Some def

main : <IO> Unit
main =
  println (def : List Int)
  println (def : List (List Int))
  println (def : List (List (List Int)))
  println (def : Option (List (Option Int)))
|}
  "[0]\n[[0]]\n[[[0]]]\nSome [Some 0]\n"

(* Both nullary Bounded methods, routed by a known result type.  (Stdlib Bounded
   impls are Phase 93; this defines a local one to exercise the dispatch.) *)
let t_nullary_bounded = assert_output_typed
  {|impl Bounded Bool where
  minBound = False
  maxBound = True

lo : Bool
lo = minBound
hi : Bool
hi = maxBound

main : <IO> Unit
main =
  println (debug lo)
  println (debug hi)
|}
  "False\nTrue\n"

(* Phase 93: the *stdlib* `Bounded Int` / `Bounded Char` impls (no local impl),
   each dispatched purely by an annotated result type.  `Char` bounds go through
   `charCode` to keep the result an Int (Debug Char isn't reachable here). *)
let t_nullary_bounded_int = assert_output_typed
  {|lo : Int
lo = minBound
hi : Int
hi = maxBound

main : <IO> Unit
main =
  println (debug (lo < hi))
|}
  "True\n"

let t_nullary_bounded_char = assert_output_typed
  {|main : <IO> Unit
main =
  println (debug (charCode (minBound : Char)))
  println (debug (charCode (maxBound : Char)))
|}
  "0\n1114111\n"

(* ── Phase 69.x-c: head-concrete (RHeadKey) dispatch ─────────────────────── *)
(* `wrap : a -> f a` discriminates on its result head `f`.  Inside `mkBox`, `f`
   is fixed to `Box` by the annotation but its arg is still free, so the site is
   head-concrete (not fully ground) — neither RKey nor RDict applies.  RHeadKey
   narrows by the impl's head tycon.  `Bag` is declared first and `wrap`'s arg
   carries no `f`, so arg-tag "first impl wins" would print `Bag` — distinct
   output proves head-key selection. *)
let t_head_key_dispatch = assert_output_typed
  {|data Box a = Box a deriving (Display)
data Bag a = Bag a deriving (Display)

interface Wrap f where
  wrap : a -> f a

impl Wrap Bag where
  wrap x = Bag x

impl Wrap Box where
  wrap x = Box x

mkBox : a -> Box a
mkBox x = wrap x

mkBag : a -> Bag a
mkBag x = wrap x

main : <IO> Unit
main =
  println (mkBox 5)
  println (mkBag 7)
|}
  "Box 5\nBag 7\n"

(* ── Phase 69.x-c: per-super dictionary passing ──────────────────────────── *)
(* `mk` is constrained on `Sub m` but its body calls `base`, a method of the
   *direct superinterface* `Base` (Sub requires Base).  `base : a -> f a` is
   return-position, so arg-tag dispatch can't pick the impl; the body needs a
   `Base m` dictionary.  Phase 69.x-c appends a super dict slot to `mk`'s
   constraints, so the caller supplies an honest `Base` dict and the inner `base`
   routes to it.  `Bag` impls are declared first, so without the super dict
   "first impl wins" would print `Bag`. *)
let t_super_dict_dispatch = assert_output_typed
  {|data Box a = Box a deriving (Display)
data Bag a = Bag a deriving (Display)

interface Base f where
  base : a -> f a

interface Sub f requires Base f where
  same : f a -> f a

impl Base Bag where
  base x = Bag x
impl Sub Bag where
  same x = x

impl Base Box where
  base x = Box x
impl Sub Box where
  same x = x

mk : Sub m => a -> m a
mk x = same (base x)

main : <IO> Unit
main =
  println (mk 5 : Box Int)
  println (mk 7 : Bag Int)
|}
  "Box 5\nBag 7\n"

(* ── Phase 111: println routes through Display; putStrLn (debug x) via Debug ── *)
(* `println` is now a Medaka fn over `display`, so a custom `Display` impl wins
   over the structural form — `<box 5>`, not `Box 5`.  `inspect` (in io.mdk)
   renders via `Debug` (`inspect x = putStrLn (debug x)`); the equivalent
   inline form `putStrLn (debug (Box 5))` with a `Debug` impl shows `Box 5`. *)
let t_println_display_vs_inspect = assert_output_typed
  {|data Box = Box Int

impl Display Box where
  display (Box n) = "<box \{n}>"

impl Debug Box where
  debug (Box n) = "Box \{n}"

main : <IO> Unit
main =
  println (Box 5)
  putStrLn (debug (Box 5))
|}
  "<box 5>\nBox 5\n"

(* ── Hello world ─────────────────────────────────────────────────────────── *)

let t_hello = assert_output
  {|main : <IO> Unit
main = println "Hello, world!"
|}
  "Hello, world!\n"

(* Phase 118: inline `then` branch with a multi-statement indented `else`
   block evaluates correctly on both branches. *)
let t_if_inline_then_block_else = assert_output
  {|classify x =
  if x > 0 then "pos"
  else
    let neg = "neg"
    neg

main : <IO> Unit
main =
  println (classify 5)
  println (classify (-3))
|}
  "pos\nneg\n"

(* Phase 122: else-less `if` runs the then-branch only when the condition holds
   and otherwise defaults to `()`, sequencing with following statements. *)
let t_if_elseless = assert_output
  {|g x =
  if x > 0 then println "pos"
  println "done"

main : <IO> Unit
main =
  g 5
  g (-1)
|}
  "pos\ndone\ndone\n"

let t_if_elseless_block = assert_output
  {|g x =
  if x > 0 then
    println "a"
    println "b"
  println "done"

main : <IO> Unit
main =
  g 5
  g (-1)
|}
  "a\nb\ndone\ndone\n"

(* ── Recursion + integer arithmetic ──────────────────────────────────────── *)

let t_factorial = assert_output
  {|factorial n =
  match n
    0 => 1
    n => n * factorial (n - 1)

main : <IO> Unit
main = println (factorial 10)
|}
  "3628800\n"

(* ── ADT construction, match, println ────────────────────────────────────── *)

let t_adt_match = assert_output
  {|data Color
  = Red
  | Green
  | Blue

name c =
  match c
    Red   => "red"
    Green => "green"
    Blue  => "blue"

main : <IO> Unit
main = println (name Green)
|}
  "green\n"

(* ── Multiple prints in a bare sequential block ──────────────────────────────
   Phase 99: imperative IO sequencing belongs in a bare indented block (EBlock),
   not a `do` block (`do` is now pure monadic sugar lowered to andThen/pure). *)

let t_multi_print = assert_output
  {|main : <IO> Unit
main =
  println "one"
  println "two"
  println "three"
|}
  "one\ntwo\nthree\n"

(* ── let mut + reassignment in a bare sequential block ──────────────────────── *)

let t_let_mut = assert_output
  {|main : <IO> Unit
main =
  let mut x = 0
  x = x + 1
  x = x + 1
  println x
|}
  "2\n"

(* ── Runtime error: non-exhaustive match ─────────────────────────────────── *)

let t_runtime_err = assert_run_err
  {|f n =
  match n
    1 => "one"
    2 => "two"

main : <IO> Unit
main = println (f 99)
|}

(* ── Phase 138: recursive value forced during its own definition ──────────── *)

(* A non-function self-recursive binding whose reference is *forced* while it is
   still being computed (`loop = ident loop` — `ident`'s strict argument
   re-looks-up `loop`) used to leak a raw OCaml `CamlinternalLazy.Undefined`
   fatal error.  It must now surface a proper Medaka `Eval_error` naming the
   binding and explaining the rule. *)
let str_contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  go 0

let recursive_value_force_src =
  {|ident x = x
loop = ident loop
main = println loop
|}

let t_recursive_value_force_err () =
  let src = recursive_value_force_src in
  match (try Some (capture_run src) with
         | Eval_error _ -> None
         | _ -> Some "<raw OCaml exception leaked>") with
  | None -> ()
  | Some out ->
    failwith (Printf.sprintf
      "Expected a Medaka Eval_error but got:\n%s\n\nSource:\n%s" out src)

(* Tighter: the diagnostic names the offending binding and the rule. *)
let t_recursive_value_force_msg () =
  let src = recursive_value_force_src in
  match (try ignore (capture_run src); None
         with Eval_error (msg, _) -> Some msg) with
  | Some msg
    when str_contains msg "loop"
      && str_contains msg "forced while it is being defined" -> ()
  | Some msg ->
    failwith (Printf.sprintf "Eval_error message missing expected text: %s" msg)
  | None -> failwith "Expected a runtime error but evaluation succeeded"

(* ── Phase 91: guard fall-through end-to-end ──────────────────────────────── *)

(* A guarded first clause whose guard fails falls through to a later pattern
   clause (Haskell semantics) instead of panicking "Non-exhaustive guards".
   Uses the typed path (capture_run_typed desugars; capture_run does not). *)
let t_guard_fallthrough = assert_output_typed
  {|tk n _
  | n <= 0 = []
tk _ [] = []
tk n (x :: xs) = x :: tk (n - 1) xs

main : <IO> Unit
main = println (debug (tk 2 [10, 20, 30, 40]))
|}
  "[10, 20]\n"

(* A single clause whose guards are exhausted (no later clause to fall through
   to) is still a runtime error — the fall-through signal reaches the boundary. *)
let assert_run_err_typed src () =
  match (try Some (capture_run_typed src) with Eval_error _ | Impl_no_match -> None) with
  | None -> ()
  | Some out ->
    failwith (Printf.sprintf "Expected runtime error but got:\n%s\n\nSource:\n%s" out src)

let t_guard_exhausted_err = assert_run_err_typed
  {|big x
  | x > 100 = "big"

main : <IO> Unit
main = println (big 5)
|}

(* ── String/Char kernel (Phase 75) ───────────────────────────────────────── *)

(* Smoke-tests each kernel extern.  Uses `println` (Display-based) via the
   typed pipeline — Display dispatch works correctly for all primitive types
   and the expected output is unquoted (matching Display semantics). *)
let t_string_kernel = assert_output_typed
  {|main : <IO> Unit
main =
  println (charCode 'A')
  println (charFromCode 66)
  println (charFromCode 55296)
  println (stringConcat ["ab", "cd", "ef"])
  println (stringCompare "abc" "abd")
  println (stringCompare "abc" "abc")
  println (stringCompare "abd" "abc")
  println (stringToFloat "3.5")
  println (stringToFloat "nope")
|}
  "65\nSome B\nNone\nabcdef\nLt\nEq\nGt\nSome 3.5\nNone\n"

(* Codepoint-vs-byte regression: "héllo→" is 6 codepoints but 9 UTF-8 bytes
   (é = 2 bytes, → = 3).  length / slice / index must count codepoints, and the
   Array Char bridge must round-trip. *)
let t_string_codepoint = assert_output_typed
  {|main : <IO> Unit
main =
  println (stringLength "héllo→")
  println (stringSlice 1 4 "héllo→")
  println (stringSlice 5 6 "héllo→")
  println (stringSlice 0 100 "héllo→")
  println (charCode '→')
  println (arrayLength (stringToChars "héllo→"))
  println (stringFromChars (stringToChars "héllo→") == "héllo→")
|}
  "6\néll\n→\nhéllo→\n8594\n6\nTrue\n"

(* Unicode classification + case folding (uucp).  Key case: ß is identity under
   the Char→Char charToUpper (a 1→N expansion it can't represent), but expands
   to SS under the String-level stringToUpper. *)
let t_string_unicode = assert_output_typed
  {|main : <IO> Unit
main =
  println (charIsAlpha 'é')
  println (charIsAlpha '7')
  println (charIsSpace ' ')
  println (charIsPunct '!')
  println (charToUpper 'é')
  println (charToUpper 'ß')
  println (stringToUpper "Straße")
  println (stringToLower "HÉLLO→")
|}
  "True\nFalse\nTrue\nTrue\nÉ\nß\nSTRASSE\nhéllo→\n"

(* stringIndexOf: host byte search reported as a *codepoint* index.  In
   "a→b→c" the second "→" is at codepoint 3 though its bytes start later; an
   absent needle is None; the empty needle is Some 0. *)
let t_string_index_of = assert_output
  {|main : <IO> Unit
main =
  println (stringIndexOf "→" "a→b→c")
  println (stringIndexOf "b→c" "a→b→c")
  println (stringIndexOf "z" "a→b→c")
  println (stringIndexOf "" "abc")
|}
  "Some 1\nSome 2\nNone\nSome 0\n"

(* Bracket slice `s.[lo..hi]` on a String is codepoint-based (Phase 75), not
   byte-based — "héllo→" has multibyte é and →.  Panics on OOB like arrays. *)
let t_string_bracket_slice = assert_output
  {|main : <IO> Unit
main =
  let s = "héllo→"
  println (s.[1..4])
  println (s.[0..=2])
  println (s.[5..6])
|}
  "éll\nhél\n→\n"

(* Phase 78a: a user module-level function may shadow a prelude *plain*
   function (here `count`, a standalone `DFunDef` in core.mdk).  Before the fix
   the user clause coalesced with the prelude clause and the program failed to
   type-check; now the user's `count` wins.  The second line confirms an
   untouched prelude method (`length`) still resolves — only the shadowed name
   is dropped from the prepended prelude. *)
let t_prelude_fn_shadow = assert_output_typed
  {|count : Int -> Int
count n = n + 1

main : <IO> Unit
main =
  if count 5 == 6 then println "OK" else println "BAD"
  if length [1, 2, 3] == 3 then println "OK" else println "BAD"
|}
  "OK\nOK\n"

(* Phase 78b: a user module-level function may shadow a prelude *interface
   method* (`length`, a Foldable method).  The user's `length` is renamed to an
   internal non-method name, so it type-checks and runs as an ordinary function
   even with a type the method could never have (`Int -> Int`); the prelude's
   Foldable methods (`isEmpty`, `toList`) still dispatch for List/Option. *)
let t_prelude_method_shadow = assert_output_typed
  {|length : Int -> Int
length n = n * 2

main : <IO> Unit
main =
  if length 3 == 6 then println "A" else println "X"
  if isEmpty [1] then println "X" else println "B"
  if toList (Some 5) == [5] then println "C" else println "X"
|}
  "A\nB\nC\n"

(* Bracket index `s.[i]` on a String is codepoint-based (Phase 77): returns the
   i-th codepoint as a Char, not the i-th byte.  "héllo→" has multibyte é (cp 1)
   and → (cp 5).  Parallels the array bracket; panics on OOB. *)
let t_string_bracket_index = assert_output
  {|main : <IO> Unit
main =
  let s = "héllo→"
  println (s.[0])
  println (s.[1])
  println (s.[5])
|}
  "h\né\n→\n"

(* `s.[i]` panics on out-of-bounds like the array bracket (codepoint count is
   6, so index 6 is past the end). *)
let t_string_bracket_index_oob = assert_run_err
  {|main : <IO> Unit
main =
  let s = "héllo→"
  println (s.[6])
|}

(* Phase 84: an unsignatured polymorphic-monad do-block dispatches its
   return-position `pure` by the caller's monad (was: arg-tag → List → panic). *)
let t_poly_monad_do = assert_output_typed
  {|f m = do
  x <- m
  pure x
main : <IO> Unit
main = match f (Some 5)
  Some v => println "ok"
  None => println "none"
|}
  "ok\n"

(* Phase 115 (#1): an *unsignatured* return-position wrapper (`mk n = tag n`,
   inferred `Tag a => Int -> a`) dispatches by the result type at each call site —
   not just the signatured form.  Phase 84's promotion only fired for `Applicative`;
   Phase 115 generalized it to any interface with a return-position method. *)
let t_infer_return_pos_wrapper = assert_output_typed
  {|interface Tag a where
  tag : Int -> a

impl Tag String where
  tag n = "S"

impl Tag Bool where
  tag n = n > 0

mk n = tag n

main : <IO> Unit
main =
  println (mk 5 : String)
  if (mk 5 : Bool) then println "T" else println "F"
|}
  "S\nT\n"

(* Phase 115 (#2): a *recursive* unsignatured return-position wrapper routes its
   own recursive call's dictionary (was: arg-tag → first impl → mis-dispatch /
   closure).  Matches the signatured form's behavior. *)
let t_infer_return_pos_recursive = assert_output_typed
  {|interface Tag a where
  tag : Int -> a

impl Tag String where
  tag n = "S"

impl Tag Bool where
  tag n = n > 0

mk n = if n <= 0 then tag 0 else mk (n - 1)

main : <IO> Unit
main =
  println (mk 3 : String)
  if (mk 3 : Bool) then println "T" else println "F"
|}
  "S\nF\n"

(* Phase 115 (#2): mutually-recursive unsignatured return-position wrappers route
   their cross-recursive dictionaries (single result type per program — polymorphic
   recursion at *two* types is a separate pre-existing limit, fails signatured too). *)
let t_infer_return_pos_mutual = assert_output_typed
  {|interface Tag a where
  tag : Int -> a

impl Tag String where
  tag n = "S"

impl Tag Bool where
  tag n = n > 0

ping n = if n <= 0 then tag 0 else pong (n - 1)
pong n = if n <= 0 then tag 1 else ping (n - 1)

main : <IO> Unit
main =
  if (ping 5 : Bool) then println "T" else println "F"
|}
  "T\n"

(* Phase 115 (#2): a *recursive* polymorphic-monad wrapper dispatches its
   return-position `pure` through its own recursive call — at two monads in one
   program (Phase 84 deferred the recursive case). *)
let t_poly_monad_recursive = assert_output_typed
  {|build n =
  if n <= 0 then pure [] else flatMap (rest => pure (n :: rest)) (build (n - 1))

main : <IO> Unit
main =
  println (build 3 : List (List Int))
  match (build 2 : Option (List Int))
    Some xs => println xs
    None => println "none"
|}
  "[[3, 2, 1]]\n[2, 1]\n"

(* Phase 115 (#3): a no-`<-` do-block (`do { pure x }`, ≡ `pure x`) is groundable
   only from surrounding context — when the result type is pinned (here by a
   use-site annotation) it dispatches correctly.  With no context it defaults to
   the first Applicative impl (List) by arg tag — an inherent ambiguity (the
   program names no monad), documented & accepted, not exercised here. *)
let t_no_bind_do_grounded = assert_output_typed
  {|f = do
  pure 5
main : <IO> Unit
main = match (f : Option Int)
  Some v => println "some"
  None => println "none"
|}
  "some\n"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

(* io Module 7 externs (the io.mdk helpers are exercised by run probes /
   stdlib; these pin the global externs through the typed pipeline). *)
let t_io_args_empty = assert_output_typed
  "main = println (args ())\n"
  "[]\n"

let t_io_getenv_unset = assert_output_typed
  "main = println (getEnv \"__MEDAKA_NOPE_XYZ__\")\n"
  "None\n"

(* ── Phase 121: point-free dispatched impl method bodies ─────────────────── *)
(* The prelude's `impl Foldable List` defines `toList = identity` point-free.
   Pre-Phase-121 this eagerly evaluated `identity` at impl-binding time — before
   the prelude's `identity` cell was filled — capturing the VUnit placeholder, so
   the VTypedImpl dispatch wrapper later applied `()` and panicked
   `applied non-function: ()`.  Eval now eta-expands a point-free argument-
   dispatched method body, deferring it to call time.  Exercises the prelude
   point-free body directly. *)
let t_pointfree_prelude_tolist = assert_output_typed
  {|main : <IO> Unit
main = println (toList [1, 2, 3])
|}
  "[1, 2, 3]\n"

(* A user impl whose point-free method body forward-references a helper defined
   later in the module: same eager-eval-too-early trap, now deferred. *)
let t_pointfree_impl_forward_ref = assert_output_typed
  {|interface Bar a where
  bar : a -> List a

impl Bar Int where
  bar = wrap

wrap x = [x, x]

main : <IO> Unit
main = println (bar 7)
|}
  "[7, 7]\n"

(* The eta-expansion must NOT fire for a nullary return-position method: `empty`
   has no argument to dispatch on, so it stays value-shaped and still resolves by
   result type. *)
let t_pointfree_nullary_empty_unaffected = assert_output_typed
  {|xs : List Int
xs = empty

main : <IO> Unit
main = println (length xs)
|}
  "0\n"

let () = Alcotest.run "Run"
  [("run", [
    "point-free prelude toList (Phase 121)", `Quick, t_pointfree_prelude_tolist;
    "point-free impl forward ref (Phase 121)", `Quick, t_pointfree_impl_forward_ref;
    "point-free nullary empty unaffected (Phase 121)", `Quick, t_pointfree_nullary_empty_unaffected;
    "io: args empty in test context", `Quick, t_io_args_empty;
    "io: getEnv unset is None",       `Quick, t_io_getenv_unset;
    "poly-monad do-block (Phase 84)", `Quick, t_poly_monad_do;
    "no-bind do grounded (Phase 115 #3)",           `Quick, t_no_bind_do_grounded;
    "inferred return-pos wrapper (Phase 115 #1)",   `Quick, t_infer_return_pos_wrapper;
    "inferred return-pos recursive (Phase 115 #2)", `Quick, t_infer_return_pos_recursive;
    "inferred return-pos mutual (Phase 115 #2)",    `Quick, t_infer_return_pos_mutual;
    "recursive poly-monad (Phase 115 #2)",          `Quick, t_poly_monad_recursive;
    "return-position dispatch", `Quick, t_return_position_dispatch;
    "multi-param dispatch",     `Quick, t_multiparam_dispatch;
    "head-key dispatch",        `Quick, t_head_key_dispatch;
    "super dict dispatch",      `Quick, t_super_dict_dispatch;
    "println Display vs inspect (Phase 111)", `Quick, t_println_display_vs_inspect;
    "dict polymorphic helper",  `Quick, t_dict_polymorphic_helper;
    "dict transitive",          `Quick, t_dict_transitive;
    "mutual rec dict (Phase 136)",        `Quick, t_mutual_rec_dict;
    "foldMap method dict (concrete)",    `Quick, t_foldmap_method_dict_concrete;
    "foldMap method dict (polymorphic)", `Quick, t_foldmap_method_dict_polymorphic;
    "foldMap explicit impl offset",      `Quick, t_foldmap_explicit_impl_offset;
    "nullary empty (stdlib Monoid)",     `Quick, t_nullary_empty_stdlib_monoid;
    "nullary empty (custom Monoid)",     `Quick, t_nullary_empty_custom_monoid;
    "nullary method on requires impl (Phase 103b)",    `Quick, t_nullary_empty_requires;
    "nested instance dicts (Phase 83/84 #5)",          `Quick, t_nested_instance_dicts;
    "nullary minBound/maxBound (Phase 96)", `Quick, t_nullary_bounded;
    "nullary Bounded Int (stdlib, Phase 93)",  `Quick, t_nullary_bounded_int;
    "nullary Bounded Char (stdlib, Phase 93)", `Quick, t_nullary_bounded_char;
    "if inline-then block-else (Phase 118)", `Quick, t_if_inline_then_block_else;
    "else-less if (Phase 122)",        `Quick, t_if_elseless;
    "else-less if block (Phase 122)",  `Quick, t_if_elseless_block;
    "hello world",   `Quick, t_hello;
    "factorial",     `Quick, t_factorial;
    "adt match",     `Quick, t_adt_match;
    "multi print",   `Quick, t_multi_print;
    "let mut",       `Quick, t_let_mut;
    "runtime error", `Quick, t_runtime_err;
    "recursive value force error (Phase 138)", `Quick, t_recursive_value_force_err;
    "recursive value force message (Phase 138)", `Quick, t_recursive_value_force_msg;
    "guard fall-through (Phase 91)", `Quick, t_guard_fallthrough;
    "guard exhausted error (Phase 91)", `Quick, t_guard_exhausted_err;
    "string kernel",      `Quick, t_string_kernel;
    "string codepoint",   `Quick, t_string_codepoint;
    "string indexOf",     `Quick, t_string_index_of;
    "string unicode",     `Quick, t_string_unicode;
    "string bracket slice", `Quick, t_string_bracket_slice;
    "string bracket index", `Quick, t_string_bracket_index;
    "string bracket index oob", `Quick, t_string_bracket_index_oob;
    "prelude fn shadow",    `Quick, t_prelude_fn_shadow;
    "prelude method shadow", `Quick, t_prelude_method_shadow;
  ])]
