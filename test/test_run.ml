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
  let prog = Method_marker.mark_with_prelude prog in
  ignore (Typecheck.check_program prog);
  (* Phase 69.x-c: dict-pass the marked prelude together with user code (the
     same marked_prelude object typecheck filled refs on), then eval without
     re-prepending. *)
  let combined = Method_marker.marked_prelude @ prog in
  let combined = Dict_pass.run combined in
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

(* ── Phase 69.x-c: head-concrete (RHeadKey) dispatch ─────────────────────── *)
(* `wrap : a -> f a` discriminates on its result head `f`.  Inside `mkBox`, `f`
   is fixed to `Box` by the annotation but its arg is still free, so the site is
   head-concrete (not fully ground) — neither RKey nor RDict applies.  RHeadKey
   narrows by the impl's head tycon.  `Bag` is declared first and `wrap`'s arg
   carries no `f`, so arg-tag "first impl wins" would print `Bag` — distinct
   output proves head-key selection. *)
let t_head_key_dispatch = assert_output_typed
  {|data Box a = Box a
data Bag a = Bag a

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
  {|data Box a = Box a
data Bag a = Bag a

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

(* ── Hello world ─────────────────────────────────────────────────────────── *)

let t_hello = assert_output
  {|main : <IO> Unit
main = println "Hello, world!"
|}
  "Hello, world!\n"

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

(* ── Multiple prints in a do-block ───────────────────────────────────────── *)

let t_multi_print = assert_output
  {|main : <IO> Unit
main =
  do
    println "one"
    println "two"
    println "three"
|}
  "one\ntwo\nthree\n"

(* ── let mut + DoAssign reassignment ─────────────────────────────────────── *)

let t_let_mut = assert_output
  {|main : <IO> Unit
main =
  do
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

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () = Alcotest.run "Run"
  [("run", [
    "return-position dispatch", `Quick, t_return_position_dispatch;
    "multi-param dispatch",     `Quick, t_multiparam_dispatch;
    "head-key dispatch",        `Quick, t_head_key_dispatch;
    "super dict dispatch",      `Quick, t_super_dict_dispatch;
    "dict polymorphic helper",  `Quick, t_dict_polymorphic_helper;
    "dict transitive",          `Quick, t_dict_transitive;
    "foldMap method dict (concrete)",    `Quick, t_foldmap_method_dict_concrete;
    "foldMap method dict (polymorphic)", `Quick, t_foldmap_method_dict_polymorphic;
    "foldMap explicit impl offset",      `Quick, t_foldmap_explicit_impl_offset;
    "hello world",   `Quick, t_hello;
    "factorial",     `Quick, t_factorial;
    "adt match",     `Quick, t_adt_match;
    "multi print",   `Quick, t_multi_print;
    "let mut",       `Quick, t_let_mut;
    "runtime error", `Quick, t_runtime_err;
  ])]
