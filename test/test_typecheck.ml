open Medaka_lib
open Typecheck

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                pos.Lexing.pos_lnum
                (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                src)

let check src =
  try Ok (fst (check_program (Desugar.desugar_program (parse src))))
  with Type_error (e, _) -> Error e

(* assert_warns: expect at least one exhaustiveness/redundancy warning *)
let assert_warns src () =
  match
    (try Some (snd (check_program (Desugar.desugar_program (parse src))))
     with Type_error _ -> None)
  with
  | None ->
    failwith ("Expected warnings but got a type error.\nSource:\n" ^ src)
  | Some [] ->
    failwith ("Expected warnings but got none.\nSource:\n" ^ src)
  | Some _ -> ()

(* assert_no_warns: expect zero exhaustiveness/redundancy warnings *)
let assert_no_warns src () =
  match
    (try Some (snd (check_program (Desugar.desugar_program (parse src))))
     with Type_error _ -> None)
  with
  | None ->
    failwith ("Expected no warnings but got a type error.\nSource:\n" ^ src)
  | Some [] -> ()
  | Some ws ->
    failwith (Printf.sprintf
      "Expected no warnings, got %d.\nWarnings:\n  %s\n\nSource:\n%s"
      (List.length ws) (String.concat "\n  " ws) src)

(* assert_warns_msg: expect at least one warning containing the substring *)
let contains_substr haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  if nn = 0 then true
  else if hn < nn then false
  else
    let rec check i =
      if i + nn > hn then false
      else if String.sub haystack i nn = needle then true
      else check (i + 1)
    in
    check 0

let assert_warns_msg substr src () =
  let ws =
    try snd (check_program (Desugar.desugar_program (parse src)))
    with Type_error (e, _) ->
      failwith ("Expected warnings but got a type error: " ^ pp_error e)
  in
  if not (List.exists (fun w -> contains_substr w substr) ws) then
    failwith (Printf.sprintf
      "Expected warning containing %S.\nGot warnings:\n  %s\n\nSource:\n%s"
      substr (String.concat "\n  " ws) src)

(* assert_type src name expected — check that `name` in `src` types as `expected` *)
let assert_type src name expected () =
  match check src with
  | Error e ->
    failwith (Printf.sprintf "Expected program to type-check, but got error:\n  %s\n\nSource:\n%s"
                (pp_error e) src)
  | Ok env ->
    let actual =
      try pp_scheme (List.assoc name env)
      with Not_found ->
        failwith (Printf.sprintf "Name %s not in env. Env contains: %s"
                    name
                    (String.concat ", " (List.map fst env)))
    in
    if actual <> expected then
      failwith (Printf.sprintf
        "Expected type for %s:\n  %s\nGot:\n  %s\n\nSource:\n%s"
        name expected actual src)

(* assert_err src — check that src fails to type-check *)
let assert_err src () =
  match check src with
  | Error _ -> ()
  | Ok env ->
    let summary = String.concat ", "
      (List.map (fun (n, s) -> n ^ " : " ^ pp_scheme s) env) in
    failwith (Printf.sprintf
      "Expected type error, but program type-checked.\n\nEnv: %s\n\nSource:\n%s"
      summary src)

(* ── Basic types ────────────────────────────────── *)

let t_const_int    = assert_type "x = 42\n"     "x" "Int"
let t_const_str    = assert_type "x = \"hi\"\n" "x" "String"
let t_const_bool   = assert_type "x = True\n"   "x" "Bool"
let t_const_unit   = assert_type "x = ()\n"     "x" "Unit"

(* ── Function inference ─────────────────────────── *)

let t_identity   = assert_type "id x = x\n"           "id"   "a -> a"
let t_const_fn   = assert_type "const x _ = x\n"      "const" "a -> b -> a"
let t_multi_param_lam = assert_type "f = x y => x + y\n" "f" "a -> a -> a"
let t_double     = assert_type "double x = x + x\n"   "double" "a -> a"
let t_inc        = assert_type "inc x = x + 1\n"      "inc"  "Int -> Int"
let t_apply      = assert_type "apply f x = f x\n"    "apply" "(a -> b) -> a -> b"
let t_compose    = assert_type "compose f g x = f (g x)\n"  "compose"
                     "(a -> b) -> (c -> a) -> c -> b"

(* ── Operator sections ──────────────────────────── *)

let t_section_add  = assert_type "f = (+1)\n"      "f"  "Int -> Int"
let t_section_mul  = assert_type "f = (*2)\n"      "f"  "Int -> Int"
let t_section_cmp  = assert_type "f = (>0)\n"      "f"  "Int -> Bool"
let t_section_map  = assert_type
  "result = map (+5) [1, 2, 3]\n" "result" "List Int"

(* ── Left operator sections ─────────────────────── *)

let t_left_section_mul    = assert_type "f = (2 * _)\n"   "f" "Int -> Int"
let t_left_section_sub    = assert_type "f = (10 - _)\n"  "f" "Int -> Int"
let t_left_section_cmp    = assert_type "f = (0 < _)\n"   "f" "Int -> Bool"
let t_left_section_map    = assert_type
  "result = map (2 * _) [1, 2, 3]\n" "result" "List Int"
let t_left_section_filter = assert_type
  "result = filter (0 < _) [1, -1, 2, -2]\n" "result" "List Int"

(* ── Bare operator sections ─────────────────────── *)

let t_bare_section_plus  = assert_type "f : Int -> Int -> Int\nf = (+)\n"  "f" "Int -> Int -> Int"
let t_bare_section_minus = assert_type "f : Int -> Int -> Int\nf = (-)\n"  "f" "Int -> Int -> Int"
let t_bare_section_mul   = assert_type "f : Int -> Int -> Int\nf = (*)\n"  "f" "Int -> Int -> Int"
let t_bare_section_eq    = assert_type "f : Int -> Int -> Bool\nf = (==)\n" "f" "Int -> Int -> Bool"
let t_bare_section_cons  = assert_type "f : Int -> List Int -> List Int\nf = (::)\n"
  "f" "Int -> List Int -> List Int"
let t_bare_section_append = assert_type "f : String -> String -> String\nf = (++)\n"
  "f" "String -> String -> String"
let t_bare_section_fold = assert_type
  "result = fold (+) 0 [1, 2, 3]\n" "result" "Int"

(* ── Polymorphism in use ────────────────────────── *)

let t_use_id_twice = assert_type
  "id x = x\nresult = id (id 5)\n" "result" "Int"

let t_id_at_two_types = assert_type
  {|id x = x
a = id 5
b = id "hi"
|} "a" "Int"

let t_id_at_two_types_b = assert_type
  {|id x = x
a = id 5
b = id "hi"
|} "b" "String"

(* ── If-then-else ───────────────────────────────── *)

let t_if = assert_type
  "abs x = if x < 0 then -x else x\n" "abs" "Int -> Int"

(* ── Type signatures ────────────────────────────── *)

let t_sig_simple = assert_type
  "f : Int -> Int\nf x = x + 1\n" "f" "Int -> Int"

let t_sig_poly = assert_type
  "id : a -> a\nid x = x\n" "id" "a -> a"

(* ── Recursion ──────────────────────────────────── *)

let t_factorial = assert_type
  "fact n = if n == 0 then 1 else n * fact (n - 1)\n"
  "fact" "Int -> Int"

let t_mutual_rec = assert_type
  {|isEven n = if n == 0 then True else isOdd (n - 1)
isOdd n = if n == 0 then False else isEven (n - 1)
|} "isEven" "Int -> Bool"

(* ── ADTs and pattern matching ──────────────────── *)

let t_option_default = assert_type
  {|withDefault d opt =
  match opt
    Some x => x
    None => d
|} "withDefault" "a -> Option a -> a"

let t_some_int = assert_type
  "x = Some 5\n" "x" "Option Int"

let t_user_adt = assert_type
  {|data Tree a
  | Leaf
  | Node (Tree a) a (Tree a)

singleton x = Node Leaf x Leaf
|} "singleton" "a -> Tree a"

let t_size = assert_type
  {|data Tree a
  | Leaf
  | Node (Tree a) a (Tree a)

size t =
  match t
    Leaf => 0
    Node l _ r => 1 + size l + size r
|} "size" "Tree a -> Int"

(* ── Lists ──────────────────────────────────────── *)

let t_list_int = assert_type "xs = [1, 2, 3]\n" "xs" "List Int"

let t_list_empty = assert_type "xs = []\n" "xs" "List a"

let t_length = assert_type
  {|len xs =
  match xs
    [] => 0
    _ :: rest => 1 + len rest
|} "len" "List a -> Int"

let t_map = assert_type
  {|map f xs =
  match xs
    [] => []
    x :: rest => f x :: map f rest
|} "map" "(a -> b) -> List a -> List b"

(* ── Tuples ─────────────────────────────────────── *)

let t_swap = assert_type
  {|swap p =
  match p
    (a, b) => (b, a)
|} "swap" "(a, b) -> (b, a)"

let t_pair = assert_type "p = (1, \"hello\")\n" "p" "(Int, String)"

(* ── Let-polymorphism ───────────────────────────── *)

let t_let_poly = assert_type
  {|f = let id = (x => x) in (id 5, id "hi")
|} "f" "(Int, String)"

(* ── Errors ─────────────────────────────────────── *)

let e_int_plus_string  = assert_err "x = 5 + \"hi\"\n"
let e_if_non_bool      = assert_err "x = if 5 then 1 else 0\n"
let e_branches_differ  = assert_err "x = if True then 1 else \"hi\"\n"
let e_apply_non_fn     = assert_err "x = 5 1\n"
let e_unbound          = assert_err "f = y\n"
let e_unknown_ctor     = assert_err "f = Banana 5\n"
let e_pattern_mismatch = assert_err
  {|f x =
  match x
    Some y => y
    True => 0
|}
let e_recursive_mismatch = assert_err
  {|bad n = if n == 0 then "zero" else bad (n - 1) + 1
|}
let e_sig_mismatch = assert_err
  "f : Int -> Int\nf x = x + \"hi\"\n"

(* ── Records ────────────────────────────────────── *)

(* Basic monomorphic record: create and access *)
let t_rec_create = assert_type
  {|record Point
  x : Int
  y : Int

origin = Point { x = 0, y = 0 }
|} "origin" "Point"

let t_rec_create_pun = assert_type
  {|record Point
  x : Int
  y : Int

make x y = Point { x, y }
|} "make" "Int -> Int -> Point"

let t_rec_access = assert_type
  {|record Point
  x : Int
  y : Int

getX p = p.x
|} "getX" "Point -> Int"

(* Field access returns the correct type *)
let t_rec_access_string = assert_type
  {|record Person
  name : String
  age : Int

getName p = p.name
|} "getName" "Person -> String"

(* Record update preserves the type *)
let t_rec_update = assert_type
  {|record Point
  x : Int
  y : Int

moveRight p = { p | x = p.x + 1 }
|} "moveRight" "Point -> Point"

(* Multi-level nested record update preserves the outermost type *)
let t_rec_update_multi_level = assert_type
  {|record Country
  code : String
record Address
  country : Country
record Person
  name : String
  address : Address

updateCode p = { p | address.country.code = "US" }
|} "updateCode" "Person -> Person"

(* Polymorphic record *)
let t_rec_poly_create = assert_type
  {|record Pair a b
  first : a
  second : b

swap p = Pair { first = p.second, second = p.first }
|} "swap" "Pair a b -> Pair b a"

(* Polymorphic record — access *)
let t_rec_poly_access = assert_type
  {|record Box a
  value : a

unbox b = b.value
|} "unbox" "Box a -> a"

(* Multiple fields accessed and used *)
let t_rec_multi_access = assert_type
  {|record Point
  x : Int
  y : Int

distance p = p.x * p.x + p.y * p.y
|} "distance" "Point -> Int"

(* Record used inside a function, return type inferred from field *)
let t_rec_in_fn = assert_type
  {|record Rect
  width : Int
  height : Int

area r = r.width * r.height
|} "area" "Rect -> Int"

(* ── Record errors ──────────────────────────────── *)

(* Field access on wrong type: type sig says String, but .x expects Point *)
let e_rec_wrong_type = assert_err
  {|record Point
  x : Int
  y : Int

bad : String -> Int
bad n = n.x
|}

(* Missing field in creation *)
let e_rec_missing_field = assert_err
  {|record Point
  x : Int
  y : Int

p = Point { x = 1 }
|}

(* Unknown field in creation *)
let e_rec_unknown_field_create = assert_err
  {|record Point
  x : Int
  y : Int

p = Point { x = 1, y = 2, z = 3 }
|}

(* Unknown field access *)
let e_rec_unknown_field_access = assert_err
  {|record Point
  x : Int
  y : Int

bad p = p.z
|}

(* Type mismatch in field value *)
let e_rec_field_type_mismatch = assert_err
  {|record Point
  x : Int
  y : Int

bad = Point { x = "hello", y = 0 }
|}

(* Record update with wrong field type *)
let e_rec_update_type_mismatch = assert_err
  {|record Point
  x : Int
  y : Int

bad p = { p | x = "nope" }
|}

(* ── Do notation ───────────────────────────────────── *)

(* Single DoExpr in a `do` block: a do-block ALWAYS introduces a per-block
   monad tyvar (post split of EDo into EBlock/EDo). So `do x` types x as `m a`. *)
let t_do_single_expr = assert_type
  "f x =\n  do\n    x\n"
  "f" "a b -> a b"

(* DoBind then pure: monad is left abstract (works for any monad) *)
let t_do_bind_pure = assert_type
  "addOne opt =\n  do\n    x <- opt\n    pure (x + 1)\n"
  "addOne" "a Int -> a Int"

(* Two binds then pure *)
let t_do_two_binds = assert_type
  "f a b =\n  do\n    x <- a\n    y <- b\n    pure (x + y)\n"
  "f" "a b -> a b -> a b"

(* DoLet: plain binding inside a do block, no monadic wrapping *)
let t_do_let = assert_type
  "f opt =\n  do\n    x <- opt\n    let y = x + 1\n    pure y\n"
  "f" "a Int -> a Int"

(* pure alone: wrap any value in any monad *)
let t_do_pure = assert_type
  "wrap x =\n  do\n    pure x\n"
  "wrap" "a -> b a"

(* pure after bind: identity for any monad *)
let t_do_pure_after_bind = assert_type
  "identity opt =\n  do\n    x <- opt\n    pure x\n"
  "identity" "a b -> a b"

(* Tuple destructuring in a DoBind *)
let t_do_tuple_bind = assert_type
  "f opt =\n  do\n    (x, y) <- opt\n    pure (x + y)\n"
  "f" "a (b, b) -> a b"

(* DoExpr in the middle: value is discarded but must still be monadic *)
let t_do_skip_middle = assert_type
  "f opt1 opt2 =\n  do\n    x <- opt1\n    opt2\n    pure x\n"
  "f" "a b -> a c -> a b"

(* Top-level do block with a concrete monad (Option) *)
let t_do_toplevel = assert_type
  "result =\n  do\n    x <- Some 10\n    pure (x * 2)\n"
  "result" "Option Int"

(* DoLet with a local function *)
let t_do_let_fn = assert_type
  "f opt =\n  do\n    x <- opt\n    let double n = n + n\n    pure (double x)\n"
  "f" "a b -> a b"

(* Error: mixing two different monads *)
let e_do_mixed_monads = assert_err
  "bad x =\n  do\n    a <- Some x\n    b <- Ok a\n    pure b\n"

(* Error: binding a non-monadic value (Int is not m a) *)
let e_do_bind_non_monad = assert_err
  "bad =\n  do\n    x <- 42\n    pure x\n"

(* Error: DoExpr that is not monadic (print returns Unit, not m a) *)
let e_do_non_monadic_expr = assert_err
  "bad opt =\n  do\n    x <- opt\n    print x\n    pure x\n"

(* ── Regression tests for indented-body / non-monadic do (Phase 45.5) ─────
   Before the EDo `has_bind` split, these all failed with "Type mismatch:
   X vs a b" because the parser lowers any multi-stmt function body to
   EDo, and EDo forced every DoExpr to unify with `m a`. *)

(* Indented function body: two let-bindings followed by an Int expression.
   Should type as `f : Int -> Int`. *)
let t_indented_body_lets = assert_type
  {|f x =
  let a = x + 1
  let b = a + 1
  b
|}
  "f" "Int -> Int"

(* Single let in an indented body. *)
let t_indented_body_single_let = assert_type
  {|f x =
  let a = x + 1
  a
|}
  "f" "Int -> Int"

(* Top-level `x = (let a = ..; let b = ..; expr)` indented. *)
let t_indented_toplevel_lets = assert_type
  {|x =
  let a = 3
  let b = 4
  a + b
|}
  "x" "Int"

(* Polymorphic let-binding inside an indented body used at two distinct
   types — proves the inner let IS being generalized.  `id 5` pins the
   second element to Int, but x is left free, so the type is `a -> (a, Int)`
   rather than `Int -> (Int, Int)`. *)
let t_indented_body_poly_let = assert_type
  {|f x =
  let id y = y
  (id x, id 5)
|}
  "f" "a -> (a, Int)"

(* `do { println; println }` is NOT valid under the EBlock/EDo split.  `do`
   is now monad-only: every DoExpr must unify with `m a`.  `println` returns
   Unit, not `m a`, so this is rejected.  Effectful sequencing should use a
   bare block (no `do` keyword) instead. *)
let e_do_seq_no_bind_now_fails = assert_err
  {|main : <IO> Unit
main = do
  println "one"
  println "two"
|}

(* Non-do indented function body with two effectful calls (parses as EDo
   under the hood via stmts_to_expr).  Same expected type as above. *)
let t_indented_body_effectful_seq = assert_type
  {|main : <IO> Unit
main =
  println "one"
  println "two"
|}
  "main" "Unit"

(* ── Pipe and compose operators ─────────────────── *)

(* x |> f  :  (a -> b) -> a -> b  from caller's perspective, but as an expr
   it's just b.  The top-level def `r = 42 |> inc` should be Int. *)
let t_pipe_int = assert_type
  "inc x = x + 1\nr = 42 |> inc\n" "r" "Int"

let t_pipe_string = assert_type
  "r = \"hello\" |> (x => x)\n" "r" "String"

let t_pipe_chain = assert_type
  "inc x = x + 1\ndbl x = x * 2\nr = 3 |> inc |> dbl\n" "r" "Int"

(* f >> g  :  (a -> b) -> (b -> c) -> (a -> c) *)
let t_compose_right = assert_type
  "inc x = x + 1\ndbl x = x * 2\nf = inc >> dbl\n" "f" "Int -> Int"

(* f << g  :  (b -> c) -> (a -> b) -> (a -> c) *)
let t_compose_left = assert_type
  "inc x = x + 1\ndbl x = x * 2\nf = dbl << inc\n" "f" "Int -> Int"

let t_compose_chain = assert_type
  "inc x = x + 1\ndbl x = x * 2\nneg x = 0 - x\nf = inc >> dbl >> neg\n" "f" "Int -> Int"

(* polymorphic compose: id >> inc should give Int -> Int *)
let t_compose_poly = assert_type
  "inc x = x + 1\nf = (x => x) >> inc\n" "f" "Int -> Int"

(* error: pipe type mismatch — Int |> (String -> Bool) *)
let e_pipe_type_mismatch = assert_err
  "f s = s == \"hi\"\nr = 42 |> f\n"

(* error: compose type mismatch — Int->Int >> String->Bool *)
let e_compose_type_mismatch = assert_err
  "inc x = x + 1\nf s = s == \"hi\"\nr = inc >> f\n"

(* ── Effect tracking ─────────────────────────────── *)

(* Pure function — no annotation, no effects: fine *)
let t_eff_pure = assert_type
  "add x y = x + y\n" "add" "a -> a -> a"

(* IO function with correct annotation *)
let t_eff_io_annotated = assert_type
  "greet : String -> <IO> Unit\ngreet name = print name\n"
  "greet" "String -> <IO> Unit"

(* Transitive IO: calling an IO fn propagates the effect to its caller *)
let t_eff_transitive = assert_type
  "greet : String -> <IO> Unit\ngreet name = print name\n\
   welcome : String -> <IO> Unit\nwelcome name = greet name\n"
  "welcome" "String -> <IO> Unit"

(* Over-annotation is OK: declared <IO, Rand> but only performs <IO> *)
let t_eff_over_annotated = assert_type
  "f : <IO, Rand> Unit\nf = print \"hi\"\n" "f" "Unit"

(* Pipe into an effectful function: f : <IO> Unit;  f = "hello" |> print *)
let t_eff_pipe_io = assert_type
  "f : <IO> Unit\nf = \"hello\" |> print\n" "f" "Unit"

(* Compose of two pure functions — composed result is also pure *)
let t_eff_compose_pure = assert_type
  "inc x = x + 1\ndbl x = x * 2\nf = inc >> dbl\n" "f" "Int -> Int"

(* Unannotated function calls print → effect inferred, no error *)
let t_eff_infer_io = assert_type
  "f = print \"hi\"\n" "f" "Unit"

(* Error: function annotated as pure (no <...>) but calls print → EffectEscape *)
let e_eff_escape_annotated_pure = assert_err
  "f : String -> Unit\nf x = print x\n"

(* Regression: a `Iface a =>` constraint in front of an effectful
   signature must not hide the effect from declared_effects.  Before
   the fix, this errored with "declared with <> but also performs
   <Mut>" because TyConstrained wasn't unwrapped during effect lookup. *)
(* The pretty-printer drops the `Ord a =>` prefix in the inferred
   type; what matters here is that the function typechecks at all. *)
let t_eff_constrained_signature = assert_type
  "f : Ord a => Array a -> <Mut> Unit\nf arr = arraySetUnsafe 0 (arrayGetUnsafe 0 arr) arr\n"
  "f" "Array a -> <Mut> Unit"

(* Error: annotated as <Rand> but performs <IO> → EffectEscape (extra: IO) *)
let e_eff_escape_wrong_effect = assert_err
  "f : <Rand> Unit\nf = print \"hi\"\n"

(* IO effect inferred through a lambda body in an unannotated fn — no error *)
let t_eff_infer_lambda = assert_type
  "bad = (x => print x) \"hi\"\n" "bad" "Unit"

(* HOF: passing effectful function — effect inferred, no error *)
let t_eff_infer_hof = assert_type
  "runWith f = f ()\nbad = runWith print\n" "bad" "Unit"

(* HOF: transitive alias of effectful function — effect inferred, no error *)
let t_eff_infer_hof_alias = assert_type
  "runWith f = f ()\np = print\nbad = runWith p\n" "bad" "Unit"

(* Escape via inferred callee: annotated pure fn calls unannotated IO fn → EffectEscape *)
let e_eff_escape_via_inferred = assert_err
  "helper x = print x\nf : String -> Unit\nf x = helper x\n"

(* HOF: pure callback — no error *)
let t_hof_pure_arg = assert_type
  "runWith f = f ()\nresult = runWith (x => x)\n"
  "result" "Unit"

(* ── Interfaces ─────────────────────────────────── *)

(* Interface method is bound with the right polymorphic type *)
let t_iface_method_type = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool
|}
  "eq" "a -> a -> Bool"

(* Impl type-checks successfully *)
let t_iface_impl_ok = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y
|}
  "eq" "a -> a -> Bool"

(* Method is usable in a top-level function *)
let t_iface_method_use = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

f x y = eq x y
|}
  "f" "a -> a -> Bool"

(* Zero-param interface — just type-checks without errors *)
let t_iface_zero_param = assert_type
  {|interface Printable where
  defaultSep : String
|}
  "defaultSep" "String"

(* Multi-method interface *)
let t_iface_multi_method = assert_type
  {|interface Show a where
  show : a -> String
  showList : List a -> String

impl Show Int where
  show x = "int"
  showList xs = "list"
|}
  "show" "a -> String"

(* Polymorphic impl — Show for Option *)
let t_iface_poly_impl = assert_type
  {|interface Show a where
  show : a -> String

impl Show Int where
  show x = "int"

impl Show Bool where
  show x = "bool"
|}
  "show" "a -> String"

(* Higher-kinded interface — MyMappable f (named distinctly from the prelude's
   Mappable so the prelude's existing impls don't conflict with the test's
   different method name). *)
let t_iface_hkt = assert_type
  {|interface MyMappable f where
  fmap : (a -> b) -> f a -> f b
|}
  "fmap" "(a -> b) -> c a -> c b"

(* Named impl — impl_name (lowercase per parser grammar) is stored, no type error.
   The parser uses IDENT for the impl name so it must be lowercase.
   Uses MyMonoid to avoid clashing with the prelude's Monoid. *)
let t_iface_named_impl = assert_type
  {|interface MyMonoid a where
  mempty : a
  mappend : a -> a -> a

impl additive of MyMonoid Int where
  mempty = 0
  mappend x y = x + y
|}
  "mempty" "a"

(* Default impl — interface with a default; an impl that omits the default method
   compiles without a MissingMethod error.  We verify the interface itself type-checks
   and the non-default method is bound. *)
let t_iface_default_method = assert_type
  {|interface Container f where
  empty : f a
  isEmpty x = False

impl Container List where
  empty = []
|}
  "empty" "a b"

(* @Name annotation type-checks as Unit — it's a disambiguation hint and does
   not affect the method's type; a program that mentions @Name compiles. *)
let t_iface_at_annotation = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

annot = @Eq
|}
  "annot" "Unit"

(* Error: impl references an unknown interface *)
let e_iface_unknown = assert_err
  {|impl Unknown Int where
  foo x = x
|}

(* Error: impl is missing a required method (parser requires at least one method,
   so we provide a wrong method name — the type checker catches the extra/missing) *)
let e_iface_missing_method = assert_err
  {|interface Eq a where
  eq : a -> a -> Bool
  lt : a -> a -> Bool

impl Eq Int where
  eq x y = x == y
|}

(* Error: impl method body has the wrong type *)
let e_iface_wrong_type = assert_err
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x + y
|}

(* Error: impl provides a method not in the interface *)
let e_iface_extra_method = assert_err
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y
  bogus x = x
|}

(* Error: impl provides wrong number of type args *)
let e_iface_arity = assert_err
  {|interface Pair a b where
  swap : (a, b) -> (b, a)

impl Pair Int where
  swap p = p
|}

(* ── Phase 33: where on interface default method bodies ── *)

(* Default method body with a where helper type-checks *)
let t_iface_default_where =
  assert_type
    {|interface Greeter a where
  greet : a -> String
  describe x = label ++ greet x where
    label = "item: "

impl Greeter Int where
  greet _ = "an int"
|}
    "describe" "a -> String"

(* Impl that omits a default method with a where helper compiles *)
let t_iface_default_where_omit =
  assert_type
    {|interface Greeter a where
  greet : a -> String
  describe x = label ++ greet x where
    label = "item: "

impl Greeter Int where
  greet _ = "an int"
|}
    "greet" "a -> String"

(* Type error in default body's where helper is caught *)
let e_iface_default_where_type_error =
  assert_err
    {|interface Broken a where
  method : a -> Int
  badDefault x = helper x where
    helper y = y + "oops"
|}

(* ── Phase 4.2: constraint checking at call sites ── *)

(* Method called with a concrete type that has a matching impl — no error *)
let t_constraint_single_impl = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

f = eq 1 2
|}
  "f" "Bool"

(* Method used polymorphically: type param stays unresolved — check is skipped *)
let t_constraint_polymorphic = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

f x y = eq x y
|}
  "f" "a -> a -> Bool"

(* Zero-param interface: no constraint check needed *)
let t_constraint_zero_param = assert_type
  {|interface Printable where
  sep : String

f = sep
|}
  "f" "String"

(* Multiple impls, one marked default — default is selected without error at a concrete type *)
let t_constraint_default_impl = assert_type
  {|interface MyMonoid a where
  mempty : a
  mappend : a -> a -> a

default impl additive of MyMonoid Int where
  mempty = 0
  mappend x y = x + y

impl multiplicative of MyMonoid Int where
  mempty = 1
  mappend x y = x * y

f : Int
f = mempty
|}
  "f" "Int"

(* Polymorphic impl (Option a) matches a call on Option Int *)
let t_constraint_poly_impl = assert_type
  {|interface Show a where
  show : a -> String

impl Show (Option a) where
  show x = "option"

f x = show (Some x)
|}
  "f" "a -> String"

(* @Name hint in application position selects the named impl — method types correctly *)
let t_constraint_at_name_drop = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl MyEq of Eq Int where
  eq x y = x == y

f = eq @MyEq 1 2
|}
  "f" "Bool"

(* ── Phase 32: named impls, @Name selection, coherence ── *)

(* UPPER-named impl type-checks; its methods resolve correctly *)
let t_named_impl_upper = assert_type
  {|interface Combine a where
  empty : a
  combine : a -> a -> a

impl Additive of Combine Int where
  empty = 0
  combine x y = x + y

f : Int
f = empty
|}
  "f" "Int"

(* @Name hint selects the named impl among multiple candidates *)
let t_at_name_selects_named_impl = assert_type
  {|interface Combine a where
  empty : a
  combine : a -> a -> a

impl Additive of Combine Int where
  empty = 0
  combine x y = x + y

impl Multiplicative of Combine Int where
  empty = 1
  combine x y = x * y

f : Int
f = combine @Additive 2 3
|}
  "f" "Int"

(* @Name on a plain (non-method) function is silently ignored *)
let t_at_name_on_non_method = assert_type
  {|id x = x

f = id @Whatever 42
|}
  "f" "Int"

(* Two impls with one marked default resolve without @Name hint *)
let t_default_impl_wins_no_hint = assert_type
  {|interface Combine a where
  empty : a
  combine : a -> a -> a

impl Additive of Combine Int where
  empty = 0
  combine x y = x + y

default impl Multiplicative of Combine Int where
  empty = 1
  combine x y = x * y

f : Int
f = empty
|}
  "f" "Int"

(* Error: @Name hint names an impl that doesn't exist *)
let e_at_name_unknown = assert_err
  {|interface Combine a where
  empty : a
  combine : a -> a -> a

impl Additive of Combine Int where
  empty = 0
  combine x y = x + y

f : Int
f = combine @NoSuchImpl 2 3
|}

(* Error: two default impls for the same (iface, type) pair *)
let e_multiple_default_impls = assert_err
  {|interface Combine a where
  empty : a
  combine : a -> a -> a

default impl Additive of Combine Int where
  empty = 0
  combine x y = x + y

default impl Multiplicative of Combine Int where
  empty = 1
  combine x y = x * y

f : Int
f = empty
|}

(* Error: two anonymous, non-default impls partially overlap — `(List a)` and
   `(List Int)` can both match a `List Int`, with no `default` or `@Name` to
   pick one (Phase 68 coherence). *)
let e_overlapping_anon_impls = assert_err
  {|interface Tag a where
  tag : a -> Int

impl Tag (List a) where
  tag xs = 0

impl Tag (List Int) where
  tag xs = 1
|}

(* Error: two anonymous impls for the identical head type. *)
let e_overlapping_dup_impls = assert_err
  {|interface Tag a where
  tag : a -> Int

impl Tag Int where
  tag x = 0

impl Tag Int where
  tag x = 1
|}

(* OK: marking the more general impl `default` blesses the specialization —
   `(List Int)` overrides the `(List a)` fallback (Phase 68). *)
let t_default_blesses_specialization = assert_type
  {|interface Tag a where
  tag : a -> Int

default impl Tag (List a) where
  tag xs = 0

impl Tag (List Int) where
  tag xs = 1

f : Int
f = tag [1, 2, 3]
|}
  "f" "Int"

(* OK: disjoint multi-arg heads don't overlap — `Conv Int String` and
   `Conv Int Bool` agree on arg 1 but not arg 2, so no single type matches both. *)
let t_disjoint_multiparam_no_overlap = assert_type
  {|interface Conv a b where
  conv : a -> b

impl Conv Int String where
  conv x = "n"

impl Conv Int Bool where
  conv x = True

f : String
f = conv 1
|}
  "f" "String"

(* Error: method called with a type that has no impl *)
let e_constraint_no_impl = assert_err
  {|data Blob = Blob

f = eq Blob Blob
|}

(* Error: method called on a type entirely absent from the impl registry *)
let e_constraint_missing_impl = assert_err
  {|interface Show a where
  show : a -> String

g = show True
|}

(* Error: multiple non-default impls, no disambiguation, at a concrete type *)
let e_constraint_ambiguous = assert_err
  {|interface Monoid a where
  mempty : a
  mappend : a -> a -> a

impl additive of Monoid Int where
  mempty = 0
  mappend x y = x + y

impl multiplicative of Monoid Int where
  mempty = 1
  mappend x y = x * y

f : Int
f = mempty
|}

(* Error: method used in a function whose return type is made concrete
   downstream, and there is no matching impl *)
let e_constraint_concrete_in_context = assert_err
  {|data Blob = Blob

check : Blob -> Blob -> Bool
check x y = eq x y
|}

(* ── Phase 20: constraint annotation syntax ──────── *)

(* Function with Eq a => annotation type-checks and gets the right type *)
let t_constraint_annot_basic = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

neq : Eq a => a -> a -> Bool
neq x y = eq x y
|}
  "neq" "a -> a -> Bool"

(* The annotated function infers the same type it would without the annotation *)
let t_constraint_annot_same_as_unannotated = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

neq : Eq a => a -> a -> Bool
neq x y = eq x y

check = neq 1 2
|}
  "check" "Bool"

(* Multiple constraints in one annotation — uses non-builtin interface names *)
let t_constraint_annot_multi = assert_type
  {|interface MyEq a where
  myeq : a -> a -> Bool

interface MyOrd a where
  mylt : a -> a -> Bool

impl MyEq Int where
  myeq x y = x == y

impl MyOrd Int where
  mylt x y = x < y

f : (MyEq a, MyOrd a) => a -> a -> Bool
f x y = myeq x y && mylt x y
|}
  "f" "a -> a -> Bool"

(* Calling a constrained fn with a type that has a matching impl — OK *)
let t_constraint_annot_call_site_ok = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

neq : Eq a => a -> a -> Bool
neq x y = eq x y

result = neq 1 2
|}
  "result" "Bool"

(* Error: calling a constrained fn with a type that has no matching impl *)
let e_constraint_annot_call_no_impl = assert_err
  {|data Blob = Blob

neq : Eq a => a -> a -> Bool
neq x y = not (eq x y)

bad = neq Blob Blob
|}

(* ── Method-level constraint annotations ─────────── *)

(* An interface method may declare extra constraints on locally-quantified
   tyvars beyond the interface's own type parameters. *)
let t_method_extra_constraint = assert_type
  {|interface MySemi a where
  combine : a -> a -> a

interface MyZero a requires MySemi a where
  zero : a

impl MySemi Int where
  combine x y = x + y

impl MyZero Int where
  zero = 0

interface Bag t where
  reduce : MyZero m => (a -> m) -> t a -> m

impl Bag List where
  reduce f xs = match xs
    []      => zero
    (x::ys) => combine (f x) (reduce f ys)

f = reduce (x => x) [1, 2, 3]
|}
  "f" "Int"

(* Calling a method whose extra constraint cannot be satisfied is rejected. *)
let e_method_extra_constraint_no_impl = assert_err
  {|interface MySemi a where
  combine : a -> a -> a

interface MyZero a requires MySemi a where
  zero : a

impl MySemi Int where
  combine x y = x + y

impl MyZero Int where
  zero = 0

interface Bag t where
  reduce : MyZero m => (a -> m) -> t a -> m

impl Bag List where
  reduce f xs = match xs
    []      => zero
    (x::ys) => combine (f x) (reduce f ys)

bad = reduce (x => x) [True, False]
|}

(* A method with extra constraint and a default impl works end-to-end. *)
let t_method_extra_constraint_default = assert_type
  {|interface MySemi a where
  combine : a -> a -> a

interface MyZero a requires MySemi a where
  zero : a

impl MySemi Int where
  combine x y = x + y

impl MyZero Int where
  zero = 0

interface Bag t where
  reduce : MyZero m => (a -> m) -> t a -> m
  collapse : MyZero a => t a -> a

  collapse xs = reduce (x => x) xs

impl Bag List where
  reduce f xs = match xs
    []      => zero
    (x::ys) => combine (f x) (reduce f ys)

f = collapse [1, 2, 3]
|}
  "f" "Int"

(* ── Exhaustiveness / redundancy ────────────────── *)

(* Option: both arms *)
let w_option_both = assert_no_warns {|
f x = match x
  Some v => v
  None   => 0
|}

(* Option: missing None *)
let w_option_missing_none = assert_warns {|
f x = match x
  Some v => v
|}

(* Option: missing Some *)
let w_option_missing_some = assert_warns {|
f : Option Int -> Int
f x = match x
  None => 0
|}

(* Bool: both arms *)
let w_bool_both = assert_no_warns {|
f x = match x
  True  => 1
  False => 0
|}

(* Bool: only True *)
let w_bool_missing_false = assert_warns {|
f x = match x
  True => 1
|}

(* Single wildcard covers everything *)
let w_wildcard = assert_no_warns {|
f x = match x
  _ => 0
|}

(* Int literals without wildcard: non-exhaustive *)
let w_int_no_wildcard = assert_warns {|
f x = match x
  1 => "one"
  2 => "two"
|}

(* Int literals with wildcard: exhaustive *)
let w_int_with_wildcard = assert_no_warns {|
f x = match x
  1 => "one"
  2 => "two"
  _ => "other"
|}

(* Redundant: duplicate arm *)
let w_redundant_dup = assert_warns {|
f x = match x
  None   => 0
  None   => 1
  Some v => v
|}

(* Redundant: wildcard then another arm *)
let w_redundant_after_wild = assert_warns {|
f x = match x
  _      => 0
  Some v => v
|}

(* Redundant: ctor arm after wildcard *)
let w_redundant_ctor_after_wild = assert_warns {|
f x = match x
  _    => 0
  None => 1
|}

(* User ADT: all constructors covered *)
let w_adt_all = assert_no_warns {|
data Color = Red | Green | Blue

f x = match x
  Red   => 0
  Green => 1
  Blue  => 2
|}

(* User ADT: missing one constructor *)
let w_adt_missing = assert_warns {|
data Color = Red | Green | Blue

f x = match x
  Red   => 0
  Green => 1
|}

(* List: [] and x::_ *)
let w_list_exhaustive = assert_no_warns {|
f xs = match xs
  []     => 0
  x :: _ => x
|}

(* List: [] only *)
let w_list_missing_cons = assert_warns {|
f xs = match xs
  [] => 0
|}

(* Guarded arm: guard may fail, so non-exhaustive without fallback *)
let w_guarded_non_exhaustive = assert_warns {|
f x = match x
  Some v if v > 0 => v
|}

(* Nested: Some(Some _) | Some None | None — fully exhaustive *)
let w_nested_exhaustive = assert_no_warns {|
f x = match x
  Some (Some v) => v
  Some None     => 0
  None          => 0
|}

(* Nested: Some(Some _) | None — missing Some None *)
let w_nested_missing = assert_warns {|
f x = match x
  Some (Some v) => v
  None          => 0
|}

(* Tuple: single arm with wildcard fields — always exhaustive *)
let w_tuple_exhaustive = assert_no_warns {|
f x = match x
  (a, b) => a + b
|}

(* ── Phase 8.5: Ref type ────────────────────────── *)

(* Ref 5 constructs a Ref Int *)
let t_ref_int = assert_type "r = Ref 5\n" "r" "Ref Int"

(* Ref "hi" constructs a Ref String *)
let t_ref_string = assert_type "r = Ref \"hi\"\n" "r" "Ref String"

(* (Ref r).value reads back the contents — polymorphic *)
let t_ref_value_poly = assert_type "f r = (Ref r).value\n" "f" "a -> a"

(* Ref Int read: r = Ref 5; v = r.value : Int *)
let t_ref_value_read = assert_type "r = Ref 5\nv = r.value\n" "v" "Int"

(* Nested Ref: Ref (Ref 0) : Ref (Ref Int) *)
let t_ref_nested = assert_type "r = Ref (Ref 0)\n" "r" "Ref (Ref Int)"

(* set_ref with <Mut> annotation: Int cell *)
let t_set_ref_type = assert_type
  "f : Ref Int -> <Mut> Unit\nf r = set_ref r 10\n"
  "f" "Ref Int -> <Mut> Unit"

(* set_ref with <Mut> annotation: String cell *)
let t_set_ref_mut_ok = assert_type
  "f : Ref String -> <Mut> Unit\nf r = set_ref r \"hi\"\n"
  "f" "Ref String -> <Mut> Unit"

(* set_ref type mismatch: r : Ref Int, but passing String *)
let e_set_ref_type_mismatch = assert_err
  "r = Ref 5\nbad = set_ref r \"hello\"\n"

(* set_ref without <Mut> annotation: annotated pure fn → EffectEscape *)
let e_set_ref_impure = assert_err
  "f : Ref Int -> Unit\nf r = set_ref r 0\n"

(* ── Phase 8.5: let mut + DoAssign ──────────────── *)

(* Assign on a let-mut binding succeeds — in a bare sequential block.
   After EBlock/EDo split, `let mut` and reassignment live in EBlock, not `do`. *)
let t_do_assign_valid = assert_type
  "f : <Mut> Int\nf =\n  let mut x = 5\n  x = 10\n  x\n"
  "f" "Int"

(* let mut inside a `do` block is now an error *)
let e_let_mut_in_do = assert_err
  "f =\n  do\n    let mut x = 5\n    x = 10\n    pure x\n"

(* Reassignment inside a `do` block is now an error *)
let e_assign_in_do = assert_err
  "f opt =\n  do\n    y <- opt\n    y = 0\n    pure y\n"

(* Assign to an immutable binding → ImmutableAssignment, inside a bare block *)
let e_do_assign_immutable = assert_err
  "bad =\n  let x = 5\n  x = 10\n  x\n"

(* Assign type mismatch: mut Int, assign String, inside a bare block *)
let e_do_assign_type_mismatch = assert_err
  "bad =\n  let mut x = 5\n  x = \"hello\"\n  x\n"

(* Assign unbound variable → UnboundVar, inside a bare block *)
let e_do_assign_unbound = assert_err
  "bad =\n  x = 10\n  42\n"

(* Bare block ending with assignment → error *)
let e_do_assign_as_last = assert_err
  "bad =\n  let mut x = 5\n  x = 1\n"

(* ── let mut: only inside a bare block, not in expression context ─── *)

let e_let_mut_outside_do = assert_err
  "f x = let mut n = x in n\n"

let e_let_mut_inline_expr = assert_err
  "r = let mut x = 0 in x + 1\n"

let e_let_mut_with_annotation = assert_err
  "f x = let mut n : Int = x in n\n"

(* let mut inside a bare block is valid *)
let t_let_mut_in_block_ok = assert_type
  "f =\n  let mut x = 5\n  x = 10\n  x\n"
  "f" "Int"

(* `<-` outside a `do` block (i.e. in a bare block) is an error *)
let e_bind_outside_do = assert_err
  "bad opt =\n  x <- opt\n  x\n"

(* Mixed: a bare-block function body that locally uses `do` for monadic chaining. *)
let t_mixed_block_with_inner_do = assert_type
  {|f opt =
  let mut x = 0
  let r = do
    y <- opt
    pure y
  r
|}
  "f" "a b -> a b"

(* ── Phase 28: DoFieldAssign ────────────────────── *)

let person_src = {|record Person
  name : String
  age  : Int

|}

(* Basic field assignment on a mutable record — in a bare block now. *)
let t_field_assign_valid = assert_type
  (person_src ^ {|go : <Mut> Person
go =
  let mut p = Person { name = "Alice", age = 30 }
  p.age = 31
  p
|})
  "go" "Person"

(* Multiple field assignments — bare block. *)
let t_field_assign_multi = assert_type
  (person_src ^ {|go : <Mut> Person
go =
  let mut p = Person { name = "Alice", age = 30 }
  p.age = 31
  p.name = "Bob"
  p
|})
  "go" "Person"

(* Ref .value assignment — bare block. *)
let t_ref_value_assign = assert_type
  {|go : <Mut> Int
go =
  let mut r = Ref 0
  r.value = 42
  r.value
|}
  "go" "Int"

(* Field assignment after reading the old value — bare block. *)
let t_field_assign_read_back = assert_type
  (person_src ^ {|go : <Mut> Int
go =
  let mut p = Person { name = "Alice", age = 30 }
  p.age = p.age + 1
  p.age
|})
  "go" "Int"

(* Field assignment on immutable binding → ImmutableAssignment, bare block. *)
let e_field_assign_immutable = assert_err
  (person_src ^ {|bad =
  let p = Person { name = "Alice", age = 30 }
  p.age = 31
  p
|})

(* Unknown field → UnknownField, bare block. *)
let e_field_assign_unknown_field = assert_err
  (person_src ^ {|bad =
  let mut p = Person { name = "Alice", age = 30 }
  p.nosuchfield = 99
  p
|})

(* Type mismatch: field is Int, assign String *)
let e_field_assign_type_mismatch = assert_err
  (person_src ^ {|bad =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = "wrong"
    pure p
|})

(* Field assignment as last stmt → error *)
let e_field_assign_as_last = assert_err
  (person_src ^ {|bad =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = 31
|})

(* ── Extern declarations ────────────────────────── *)

(* extern with concrete type: add 1 2 should type as Int *)
let t_extern_concrete = assert_type
  "extern add : Int -> Int -> Int\nresult = add 1 2\n"
  "result" "Int"

(* extern with polymorphic type: id 42 should be Int *)
let t_extern_poly = assert_type
  "extern id : a -> a\nresult = id 42\n"
  "result" "Int"

(* extern constant: used in an expression *)
let t_extern_constant = assert_type
  "extern zero : Int\nresult = zero + 1\n"
  "result" "Int"

(* extern with effect: caller without annotation → effect inferred, no error *)
let t_eff_infer_extern = assert_type
  "extern myPrint : a -> <IO> Unit\nbad = myPrint 42\n" "bad" "Unit"

(* extern with effect: caller with matching annotation → ok *)
let t_extern_effect_annotated = assert_type
  "extern myPrint : a -> <IO> Unit\nf : a -> <IO> Unit\nf x = myPrint x\n"
  "f" "a -> <IO> Unit"

(* ── Collection literal tests ───────────────────── *)

let t_map_string_int = assert_type
  "m = Map { \"a\" => 1, \"b\" => 2 }\n"
  "m" "Map String Int"

let t_map_int_bool = assert_type
  "m = Map { 1 => True, 2 => False }\n"
  "m" "Map Int Bool"

let t_set_int = assert_type
  "s = Set { 1, 2, 3 }\n"
  "s" "Set Int"

let t_set_string = assert_type
  "s = Set { \"a\", \"b\" }\n"
  "s" "Set String"

let e_map_key_mismatch = assert_err
  "m = Map { 1 => true, \"x\" => false }\n"

let e_map_val_mismatch = assert_err
  "m = Map { \"a\" => 1, \"b\" => True }\n"

let e_set_type_mismatch = assert_err
  "s = Set { 1, \"two\" }\n"

(* ── Phase 17: polymorphic arithmetic / comparison / modulo ───── *)

(* Float arithmetic via Num *)
let t_float_add = assert_type "x = 1.5 + 2.0\n" "x" "Float"
let t_float_mul = assert_type "x = 1.5 * 2.0\n" "x" "Float"
let t_int_add_regression = assert_type "x = 1 + 2\n" "x" "Int"

(* Polymorphic equality unchanged *)
let t_float_eq = assert_type "x = 1.5 == 2.0\n" "x" "Bool"
let t_string_eq = assert_type "x = \"a\" == \"b\"\n" "x" "Bool"

(* Comparison via Ord — now works on Float and String *)
let t_string_lt = assert_type "x = \"a\" < \"b\"\n" "x" "Bool"
let t_float_lt  = assert_type "x = 1.5 < 2.0\n"  "x" "Bool"

(* Modulo — Int only *)
let t_int_mod = assert_type "x = 5 % 2\n" "x" "Int"

(* Errors *)
let e_string_num = assert_err "x = \"a\" + \"b\"\n"
let e_int_float_mismatch = assert_err "x = 1 + 1.5\n"
let e_float_mod = assert_err "x = 5.0 % 2.0\n"

(* ── Phase 18: runtime.mdk externs ─────────────── *)

(* readLine is in initial_env via runtime.mdk; annotated caller is ok *)
let t_readLine_type = assert_type
  "f : Unit -> <IO> String\nf u = readLine u\n"
  "f" "Unit -> <IO> String"

(* readFile: takes a String path, returns Result String String *)
let t_readFile_type = assert_type
  "f : String -> <IO> (Result String String)\nf p = readFile p\n"
  "f" "String -> <IO> Result String String"

(* effect propagation: function calling readFile infers IO, no error *)
let t_readFile_infer = assert_type
  "bad p = readFile p\n" "bad" "String -> Result String String"

(* extern with uppercase name (Ref constructor) accepted by parser *)
let t_extern_upper = assert_type
  "extern Blorp : Int -> Blorp\nx = Blorp\n"
  "x" "Int -> Blorp"

(* ── Deriving (Phase 19) ─────────────────────────── *)

(* deriving Eq on a simple enum: eq on concrete Color values type-checks *)
let t_derive_eq_enum = assert_type
  {|
interface Eq a where
  eq : a -> a -> Bool
data Color = Red | Green | Blue deriving (Eq)
f = eq Red Green
|}
  "f" "Bool"

(* deriving Eq on a data type with fields *)
let t_derive_eq_fields = assert_type
  {|
interface Eq a where
  eq : a -> a -> Bool
impl Eq Int where
  eq x y = x == y
data Pair = Pair Int Int deriving (Eq)
f = eq (Pair 1 2) (Pair 3 4)
|}
  "f" "Bool"

(* deriving Show on an enum: show on concrete value type-checks *)
let t_derive_show_enum = assert_type
  {|
interface Show a where
  show : a -> String
data Dir = North | South | East | West deriving (Show)
f = show North
|}
  "f" "String"

(* deriving Show on a type with fields *)
let t_derive_show_fields = assert_type
  {|
interface Show a where
  show : a -> String
impl Show Int where
  show x = "int"
data Box = Box Int deriving (Show)
f = show (Box 42)
|}
  "f" "String"

(* deriving Ord on a simple enum: compare on concrete values type-checks *)
let t_derive_ord_enum = assert_type
  {|
interface Eq a where
  eq : a -> a -> Bool
data Ordering = Lt | Eq | Gt
interface Ord a where
  compare : a -> a -> Ordering
data Priority = Low | Medium | High deriving (Ord)
f = compare Low High
|}
  "f" "Ordering"

(* deriving multiple interfaces at once *)
let t_derive_multi = assert_type
  {|
interface Eq a where
  eq : a -> a -> Bool
interface Show a where
  show : a -> String
data Suit = Clubs | Diamonds | Hearts | Spades deriving (Eq, Show)
useEq = eq Clubs Diamonds
useShow = show Hearts
|}
  "useEq" "Bool"

(* deriving Eq on a record: eq on concrete record values type-checks *)
let t_derive_eq_record = assert_type
  {|
interface Eq a where
  eq : a -> a -> Bool
impl Eq Int where
  eq x y = x == y
record Point
  x : Int
  y : Int
deriving (Eq)
p1 = Point { x = 1, y = 2 }
p2 = Point { x = 3, y = 4 }
f = eq p1 p2
|}
  "f" "Bool"

(* ── Top-level function guards ──────────────────── *)

let t_guard_int_to_string = assert_type {|
classify n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"
r = classify 5
|} "r" "String"

let t_guard_int_to_int = assert_type {|
abs_val n
  | n < 0 = 0 - n
  | True = n
r = abs_val (-3)
|} "r" "Int"

let e_guard_body_mismatch = assert_err {|
f x
  | x > 0 = 1
  | True = "oops"
|}

(* Pattern-bind guard: the bound var is typed from the scrutinee and is
   usable in later qualifiers and the body. *)
let t_pguard_bind_scopes = assert_type {|
classify o
  | Some y <- o, y > 0 = y
  | otherwise          = 0
r = classify (Some 5)
|} "r" "Int"

(* Ill-typed: comparing the bound String against an Int must be rejected. *)
let e_pguard_bind_mismatch = assert_err {|
f o
  | Some y <- o, y > 0 = y
r : Option String -> Int
r = f
|}

(* ── Type alias tests ─────────────────────────────── *)

let t_alias_simple =
  assert_type
    "type Name = String\ngreet : Name -> String\ngreet n = n\n"
    "greet" "String -> String"

let t_alias_param =
  assert_type
    "type Wrapper a = Option a\nunwrap : Wrapper a -> a -> a\nunwrap w d = match w\n  Some x => x\n  None => d\n"
    "unwrap" "Option a -> a -> a"

let t_alias_pair =
  assert_type
    "type Pair a b = (a, b)\nfst : Pair a b -> a\nfst (x, _) = x\n"
    "fst" "(a, b) -> a"

let t_alias_in_annot =
  assert_type
    "type Name = String\ngreet x = (x : Name)\n"
    "greet" "String -> String"

(* ── Newtype tests ──────────────────────────────── *)

let t_newtype_ctor_type =
  assert_type
    "newtype UserId = UserId Int\nmk n = UserId n\n"
    "mk" "Int -> UserId"

let t_newtype_distinct =
  assert_err
    "newtype UserId = UserId Int\nf : UserId -> Int\nf x = x\n"

let t_newtype_param =
  assert_type
    "newtype Wrapper a = Wrap a\nmk x = Wrap x\n"
    "mk" "a -> Wrapper a"

let t_newtype_pattern_match =
  assert_type
    "newtype UserId = UserId Int\nunwrap (UserId n) = n\n"
    "unwrap" "UserId -> Int"

(* ── Phase 26: Type alias / newtype coverage ─────── *)

let e_alias_recursive =
  assert_err
    "type Loop = Loop\nf x = (x : Loop)\n"

let e_alias_mutual_recursive =
  assert_err
    "type A = B\ntype B = A\nf x = (x : A)\n"

let t_newtype_deriving_num_type =
  assert_type
    "newtype Dist = Dist Int deriving (Num)\nadd_dists : Dist -> Dist -> Dist\nadd_dists a b = add a b\n"
    "add_dists" "Dist -> Dist -> Dist"

(* ── Phase 22: Semigroup / Monoid ────────────────── *)

let t_list_semigroup =
  assert_type "x = [1,2] ++ [3,4]\n" "x" "List Int"

let t_string_semigroup =
  assert_type {|x = "hello" ++ " world"
|} "x" "String"

let t_user_semigroup =
  assert_type
    {|interface Semigroup a where
    append : a -> a -> a
data Sum = Sum Int
impl Semigroup Sum where
    append (Sum a) (Sum b) = Sum (a + b)
x : Sum
x = Sum 1 ++ Sum 2
|}
    "x" "Sum"

let e_no_semigroup =
  assert_err
    {|interface Semigroup a where
    append : a -> a -> a
data Foo = Foo Int
x = Foo 1 ++ Foo 2
|}

let t_monoid_string_empty =
  assert_type
    {|interface MySemigroup a where
    append : a -> a -> a
interface MyMonoid a requires MySemigroup a where
    empty : a
impl MyMonoid String where
    empty = ""
x : String
x = empty
|}
    "x" "String"

(* ── String interpolation ───────────────────────── *)

let t_interp_type =
  assert_type
    "name = \"Alice\"\nx = \"Hello, \\{name}!\"\n"
    "x" "String"

let t_interp_string_hole =
  assert_type
    "greeting = \"hi\"\nx = \"\\{greeting} world\"\n"
    "x" "String"

let t_interp_empty_ok =
  assert_type
    "a = \"start\"\nb = \"end\"\nx = \"\\{a}\\{b}\"\n"
    "x" "String"

let e_interp_int_in_hole =
  assert_err "x = \"value: \\{42}\"\n"

(* ── Local let-rec (Phase 27) ───────────────────── *)

let t_let_rec_factorial =
  assert_type
    "result = let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact 5\n"
    "result" "Int"

let t_let_rec_acc =
  (* Accumulator-style tail recursion *)
  assert_type
    "result = let go acc n = if n <= 0 then acc else go (acc + n) (n - 1) in go 0 5\n"
    "result" "Int"

let t_let_rec_diverge =
  (* let f x = f x is well-typed: a -> b *)
  assert_type
    "result = let loop x = loop x in loop\n"
    "result" "a -> b"

let t_let_nonrec_val =
  (* let x = expr (no args) stays non-recursive; x refers to outer scope *)
  assert_type
    "x = 10\nresult = let x = x + 1 in x\n"
    "result" "Int"

let t_where_helper_rec =
  (* where-bound helper can call itself *)
  assert_type
    {|sumTo n = go 0 n where
    go acc k = if k <= 0 then acc else go (acc + k) (k - 1)
result = sumTo 5
|} "result" "Int"

(* ── Where clauses (Phase 25) ───────────────────── *)

let t_where_simple_type =
  assert_type {|r = double 5 where
    double x = x * 2
|} "r" "Int"

let t_where_mutual_type =
  assert_type {|r = isEven 4 where
    isEven n = if n == 0 then True else isOdd (n - 1)
    isOdd  n = if n == 0 then False else isEven (n - 1)
|} "r" "Bool"

let t_where_polymorphic =
  assert_type {|r = myId 42 where
  myId x = x
|} "r" "Int"

let e_where_type_mismatch =
  assert_err {|r = helper 5 where
    helper x = x + "oops"
|}

(* ── Record patterns (Phase 31) ─────────────────── *)

let record_person = "record Person\n  name : String\n  age : Int\n"

let t_rec_pat_pun_type =
  assert_type
    (record_person ^ "f p =\n  match p\n    Person { name } => name\n")
    "f" "Person -> String"

let t_rec_pat_explicit_type =
  assert_type
    (record_person ^ "f p =\n  match p\n    Person { age = 30 } => 1\n    Person { ... } => 0\n")
    "f" "Person -> Int"

let t_rec_pat_poly =
  assert_type
    ("record Box a\n  value : a\n" ^
     "getVal b =\n  match b\n    Box { value } => value\n")
    "getVal" "Box a -> a"

let e_rec_pat_type_mismatch =
  assert_err
    (record_person ^ "f p =\n  match p\n    Person { name = 42 } => 0\n    Person { ... } => 1\n")

let e_rec_pat_unknown_record =
  assert_err "f p =\n  match p\n    Ghost { x } => x\n"

(* ── if let / let else (Phase 38) ─────────────────── *)

let t_if_let_match =
  assert_type
    {|f opt =
  if let Some x = opt then x + 1 else 0
|}
    "f" "Option Int -> Int"

let t_if_let_no_match =
  assert_type
    {|f s =
  if let "yes" = s then True else False
|}
    "f" "String -> Bool"

let e_if_let_branch_mismatch =
  assert_err
    {|f opt =
  if let Some x = opt then x + 1 else "fallback"
|}

let t_let_else_bind =
  assert_type
    {|f opt =
  do
    _ <- Some ()
    let Some x = opt else pure 0
    pure (x + 1)
|}
    "f" "Option Int -> Option Int"

let e_let_else_last_stmt =
  assert_err
    {|f opt =
  do
    let Some x = opt else pure 0
|}

(* ── Named-field variants (Phase 39) ────────────── *)

let named_event =
  "data Event\n  | Click { x : Int, y : Int }\n  | Scroll Int\n"

let t_named_ctor_create =
  assert_type
    (named_event ^ "v = Click { x = 1, y = 2 }\n")
    "v" "Event"

let t_named_ctor_pat_pun =
  assert_type
    (named_event ^ "getX e =\n  match e\n    Click { x, y } => x\n    Scroll _ => 0\n")
    "getX" "Event -> Int"

let t_named_ctor_mixed =
  assert_type
    (named_event ^ "f e =\n  match e\n    Click { x } => x\n    Scroll n => n\n")
    "f" "Event -> Int"

let e_named_ctor_missing_field =
  assert_err (named_event ^ "v = Click { x = 1 }\n")

let e_named_ctor_wrong_field_type =
  assert_err (named_event ^ "v = Click { x = \"bad\", y = 2 }\n")

(* ── Range literals (Phase 40) ───────────────────── *)

let t_range_list_type =
  assert_type "r = [1..10]\n" "r" "List Int"

let t_range_list_inclusive_type =
  assert_type "r = [1..=10]\n" "r" "List Int"

let t_range_array_type =
  assert_type "r = [|0..5|]\n" "r" "Array Int"

let t_range_array_inclusive_type =
  assert_type "r = [|1..=100|]\n" "r" "Array Int"

let t_range_pat_int_type =
  assert_type
    "classify n =\n  match n\n    1..9 => \"single\"\n    _ => \"other\"\n"
    "classify" "Int -> String"

let t_range_pat_char_type =
  assert_type
    "isLower c =\n  match c\n    'a'..='z' => True\n    _ => False\n"
    "isLower" "Char -> Bool"

let e_range_list_non_int =
  assert_err "r = [True..False]\n"

(* ── prop declarations (Phase 42) ───────────────────── *)

let t_prop_int_param =
  assert_no_warns
    {|prop "identity_add" (x : Int) =
  x + 0 == x
|}

let t_prop_bool_param =
  assert_no_warns
    {|prop "double_neg" (b : Bool) =
  not (not b) == b
|}

let t_prop_list_param =
  assert_no_warns
    {|prop "length_ge_zero" (xs : List Int) =
  length xs >= 0
|}

let e_prop_body_not_bool =
  assert_err
    {|prop "bad_body" (x : Int) =
  x + 1
|}

(* ── function keyword (Phase 44) ────────────────────── *)

let t_function_option =
  assert_type
    {|f =
  function
    None => 0
    Some x => x
|}
    "f" "Option Int -> Int"

let t_function_bool =
  assert_type
    {|f =
  function
    True => 1
    False => 0
|}
    "f" "Bool -> Int"

let t_function_as_arg =
  assert_type
    {|xs : List (Option Int)
xs = []
fromOpt =
  function
    None => 0
    Some x => x
r = map fromOpt xs
|}
    "r" "List Int"

(* ── Declaration attributes (Phase 49) ─────────── *)

let t_deprecated_warns = assert_warns_msg "is deprecated" {|
@deprecated "use bar instead"
foo x = x
main = foo 1
|}

let t_deprecated_still_typechecks = assert_type {|
@deprecated "use bar instead"
foo x = x
|} "foo" "a -> a"

let t_must_use_warns = assert_warns_msg "unused (marked @must_use)" {|
compute2 : Int -> Int
@must_use
compute2 x = x

main =
  compute2 42
  0
|}

let t_inline_no_error = assert_no_warns {|
@inline
double x = x + x
|}

let t_no_warn_non_deprecated = assert_no_warns {|
foo x = x
main = foo 1
|}

(* ── Phase 52: Eq/Num/Ord wiring to operators ───── *)

(* == on a type with Eq impl type-checks to Bool *)
let t_eq52_builtin_eq = assert_type
  "f = 1 == 2\n"
  "f" "Bool"

(* == on String (prelude Eq String) type-checks *)
let t_eq52_string_eq = assert_type
  "f = \"hello\" == \"world\"\n"
  "f" "Bool"

(* == on custom type without Eq impl raises NoImplFound *)
let e_eq52_no_impl = assert_err
  {|data Blob = Blob
f = Blob == Blob
|}

(* custom impl Num type-checks without error *)
let t_eq52_custom_num = assert_type
  {|interface Num2 a where
  add2 : a -> a -> a

data MyNum = MyNum Int

impl Num2 MyNum where
  add2 (MyNum a) (MyNum b) = MyNum (a + b)

f x y = add2 x y
|}
  "f" "a -> a -> a"

(* + on a user-defined Num type type-checks *)
let t_eq52_custom_num_plus = assert_type
  {|data MyNum = MyNum Int

impl Num MyNum where
  add a b = a
  sub a b = a
  mul a b = a
  div a b = a
  negate a = a
  abs a = a
  signum a = MyNum 0
  fromInt _ = MyNum 0

f : MyNum -> MyNum -> MyNum
f a b = a + b
|}
  "f" "MyNum -> MyNum -> MyNum"

(* != on a non-Eq type also raises NoImplFound *)
let e_eq52_neq_no_impl = assert_err
  {|data Blob = Blob
f = Blob != Blob
|}

(* ── Phase 57: let rec ──────────────────────────── *)

let t_letrec_fact = assert_type
  "let rec fact = n => if n == 0 then 1 else n * fact (n - 1)\n"
  "fact" "Int -> Int"

let t_letrec_mutual = assert_type
  "let rec is_even = n => if n == 0 then True else is_odd (n - 1)\n\
   with is_odd = n => if n == 0 then False else is_even (n - 1)\n"
  "is_even" "Int -> Bool"

(* `let rec` value with non-lambda RHS is rejected. *)
let e_letrec_nonfn_arith = assert_err
  "let rec x = x + 1\n"

let e_letrec_cyclic_cons = assert_err
  "let rec ones = 1 :: ones\n"

(* ── Runner ─────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Typecheck" [
    "literals", [
      test_case "Int"    `Quick t_const_int;
      test_case "String" `Quick t_const_str;
      test_case "Bool"   `Quick t_const_bool;
      test_case "Unit"   `Quick t_const_unit;
    ];
    "function inference", [
      test_case "identity"            `Quick t_identity;
      test_case "const"               `Quick t_const_fn;
      test_case "double"              `Quick t_double;
      test_case "inc"                 `Quick t_inc;
      test_case "apply"               `Quick t_apply;
      test_case "compose"             `Quick t_compose;
      test_case "multi-param lambda"  `Quick t_multi_param_lam;
    ];
    "operator sections", [
      test_case "(+1)"                `Quick t_section_add;
      test_case "(*2)"                `Quick t_section_mul;
      test_case "(>0)"                `Quick t_section_cmp;
      test_case "map (+5) list"       `Quick t_section_map;
    ];
    "left operator sections", [
      test_case "(2 * _)"             `Quick t_left_section_mul;
      test_case "(10 - _)"            `Quick t_left_section_sub;
      test_case "(0 < _)"             `Quick t_left_section_cmp;
      test_case "map (2 * _) list"    `Quick t_left_section_map;
      test_case "filter (0 < _) list" `Quick t_left_section_filter;
    ];
    "bare operator sections", [
      test_case "(+)"                 `Quick t_bare_section_plus;
      test_case "(-)"                 `Quick t_bare_section_minus;
      test_case "(*)"                 `Quick t_bare_section_mul;
      test_case "(==)"                `Quick t_bare_section_eq;
      test_case "(::)"                `Quick t_bare_section_cons;
      test_case "(++)"                `Quick t_bare_section_append;
      test_case "fold (+) 0 list"     `Quick t_bare_section_fold;
    ];
    "polymorphism", [
      test_case "id twice"            `Quick t_use_id_twice;
      test_case "id @ Int"            `Quick t_id_at_two_types;
      test_case "id @ String"         `Quick t_id_at_two_types_b;
      test_case "let-poly"            `Quick t_let_poly;
    ];
    "control flow", [
      test_case "if"                  `Quick t_if;
    ];
    "type sigs", [
      test_case "monomorphic"         `Quick t_sig_simple;
      test_case "polymorphic"         `Quick t_sig_poly;
    ];
    "recursion", [
      test_case "factorial"           `Quick t_factorial;
      test_case "mutual"              `Quick t_mutual_rec;
      test_case "let rec fact"        `Quick t_letrec_fact;
      test_case "let rec mutual"      `Quick t_letrec_mutual;
      test_case "err: let rec non-fn"      `Quick e_letrec_nonfn_arith;
      test_case "err: let rec cyclic cons" `Quick e_letrec_cyclic_cons;
    ];
    "ADTs", [
      test_case "default opt"         `Quick t_option_default;
      test_case "Some Int"            `Quick t_some_int;
      test_case "user Tree"           `Quick t_user_adt;
      test_case "Tree size"           `Quick t_size;
    ];
    "lists", [
      test_case "list of Int"         `Quick t_list_int;
      test_case "empty list"          `Quick t_list_empty;
      test_case "length"              `Quick t_length;
      test_case "map"                 `Quick t_map;
    ];
    "tuples", [
      test_case "pair"                `Quick t_pair;
      test_case "swap"                `Quick t_swap;
    ];
    "errors", [
      test_case "Int + String"        `Quick e_int_plus_string;
      test_case "if non-bool"         `Quick e_if_non_bool;
      test_case "branches differ"     `Quick e_branches_differ;
      test_case "apply non-fn"        `Quick e_apply_non_fn;
      test_case "unbound var"         `Quick e_unbound;
      test_case "unknown ctor"        `Quick e_unknown_ctor;
      test_case "pat type mismatch"   `Quick e_pattern_mismatch;
      test_case "recursive mismatch"  `Quick e_recursive_mismatch;
      test_case "sig mismatch"        `Quick e_sig_mismatch;
    ];
    "records", [
      test_case "create monomorphic"  `Quick t_rec_create;
      test_case "create pun"          `Quick t_rec_create_pun;
      test_case "access Int field"    `Quick t_rec_access;
      test_case "access String field" `Quick t_rec_access_string;
      test_case "update"              `Quick t_rec_update;
      test_case "update multi-level"  `Quick t_rec_update_multi_level;
      test_case "poly create"         `Quick t_rec_poly_create;
      test_case "poly access"         `Quick t_rec_poly_access;
      test_case "multi-field access"  `Quick t_rec_multi_access;
      test_case "field in fn"         `Quick t_rec_in_fn;
      test_case "err: wrong type"     `Quick e_rec_wrong_type;
      test_case "err: missing field"  `Quick e_rec_missing_field;
      test_case "err: unknown in create" `Quick e_rec_unknown_field_create;
      test_case "err: unknown access" `Quick e_rec_unknown_field_access;
      test_case "err: field type mismatch" `Quick e_rec_field_type_mismatch;
      test_case "err: update type mismatch" `Quick e_rec_update_type_mismatch;
    ];
    "effects", [
      test_case "pure fn no annotation"     `Quick t_eff_pure;
      test_case "IO with annotation"        `Quick t_eff_io_annotated;
      test_case "transitive IO"             `Quick t_eff_transitive;
      test_case "over-annotation ok"        `Quick t_eff_over_annotated;
      test_case "pipe into IO fn"           `Quick t_eff_pipe_io;
      test_case "compose pure"              `Quick t_eff_compose_pure;
      test_case "infer IO no annot"         `Quick t_eff_infer_io;
      test_case "infer lambda effect"       `Quick t_eff_infer_lambda;
      test_case "err: escape pure annot"    `Quick e_eff_escape_annotated_pure;
      test_case "constrained sig keeps effect" `Quick t_eff_constrained_signature;
      test_case "err: wrong effect"         `Quick e_eff_escape_wrong_effect;
      test_case "infer HOF effectful arg"   `Quick t_eff_infer_hof;
      test_case "infer HOF alias"           `Quick t_eff_infer_hof_alias;
      test_case "err: escape via inferred"  `Quick e_eff_escape_via_inferred;
      test_case "HOF pure arg ok"           `Quick t_hof_pure_arg;
    ];
    "pipe and compose", [
      test_case "pipe Int"               `Quick t_pipe_int;
      test_case "pipe String"            `Quick t_pipe_string;
      test_case "pipe chain"             `Quick t_pipe_chain;
      test_case "compose >>"            `Quick t_compose_right;
      test_case "compose <<"            `Quick t_compose_left;
      test_case "compose chain"          `Quick t_compose_chain;
      test_case "compose poly"           `Quick t_compose_poly;
      test_case "err: pipe mismatch"     `Quick e_pipe_type_mismatch;
      test_case "err: compose mismatch"  `Quick e_compose_type_mismatch;
    ];
    "do notation", [
      test_case "single expr"            `Quick t_do_single_expr;
      test_case "indented body: lets+expr" `Quick t_indented_body_lets;
      test_case "indented body: 1 let"    `Quick t_indented_body_single_let;
      test_case "indented toplevel lets"  `Quick t_indented_toplevel_lets;
      test_case "indented body: poly let" `Quick t_indented_body_poly_let;
      test_case "do seq, no bind (now errors)"  `Quick e_do_seq_no_bind_now_fails;
      test_case "indented effectful seq"  `Quick t_indented_body_effectful_seq;
      test_case "bind + pure"            `Quick t_do_bind_pure;
      test_case "two binds"              `Quick t_do_two_binds;
      test_case "let in do"              `Quick t_do_let;
      test_case "pure"                   `Quick t_do_pure;
      test_case "pure after bind"        `Quick t_do_pure_after_bind;
      test_case "tuple bind"             `Quick t_do_tuple_bind;
      test_case "skip middle expr"       `Quick t_do_skip_middle;
      test_case "top level Option"       `Quick t_do_toplevel;
      test_case "let fn in do"           `Quick t_do_let_fn;
      test_case "err: mixed monads"      `Quick e_do_mixed_monads;
      test_case "err: bind non-monad"    `Quick e_do_bind_non_monad;
      test_case "err: non-monadic expr"  `Quick e_do_non_monadic_expr;
    ];
    "interfaces", [
      test_case "method type"            `Quick t_iface_method_type;
      test_case "impl ok"                `Quick t_iface_impl_ok;
      test_case "method use"             `Quick t_iface_method_use;
      test_case "zero-param interface"   `Quick t_iface_zero_param;
      test_case "multi-method"           `Quick t_iface_multi_method;
      test_case "poly impl"              `Quick t_iface_poly_impl;
      test_case "HKT"                    `Quick t_iface_hkt;
      test_case "named impl"             `Quick t_iface_named_impl;
      test_case "default method"             `Quick t_iface_default_method;
      test_case "@Name annotation"           `Quick t_iface_at_annotation;
      test_case "default method where"       `Quick t_iface_default_where;
      test_case "default method where omit"  `Quick t_iface_default_where_omit;
      test_case "err: unknown interface"     `Quick e_iface_unknown;
      test_case "err: missing method"        `Quick e_iface_missing_method;
      test_case "err: wrong type"            `Quick e_iface_wrong_type;
      test_case "err: extra method"          `Quick e_iface_extra_method;
      test_case "err: arity mismatch"        `Quick e_iface_arity;
      test_case "err: default where type"    `Quick e_iface_default_where_type_error;
    ];
    "constraint checking", [
      test_case "single impl"            `Quick t_constraint_single_impl;
      test_case "polymorphic skip"       `Quick t_constraint_polymorphic;
      test_case "zero-param skip"        `Quick t_constraint_zero_param;
      test_case "default impl"           `Quick t_constraint_default_impl;
      test_case "poly impl match"        `Quick t_constraint_poly_impl;
      test_case "@Name drop"             `Quick t_constraint_at_name_drop;
      test_case "err: no impl"           `Quick e_constraint_no_impl;
      test_case "err: missing impl"      `Quick e_constraint_missing_impl;
      test_case "err: ambiguous"         `Quick e_constraint_ambiguous;
      test_case "err: concrete context"  `Quick e_constraint_concrete_in_context;
    ];
    "named impls and @Name selection (Phase 32)", [
      test_case "UPPER named impl"          `Quick t_named_impl_upper;
      test_case "@Name selects named impl"  `Quick t_at_name_selects_named_impl;
      test_case "@Name on non-method"       `Quick t_at_name_on_non_method;
      test_case "default impl wins"         `Quick t_default_impl_wins_no_hint;
      test_case "err: unknown @Name"        `Quick e_at_name_unknown;
      test_case "err: multiple defaults"    `Quick e_multiple_default_impls;
    ];
    "impl coherence (Phase 68)", [
      test_case "err: overlapping anon impls"   `Quick e_overlapping_anon_impls;
      test_case "err: duplicate anon impls"     `Quick e_overlapping_dup_impls;
      test_case "default blesses specialization" `Quick t_default_blesses_specialization;
      test_case "disjoint multiparam ok"        `Quick t_disjoint_multiparam_no_overlap;
    ];
    "constraint annotation syntax (Phase 20)", [
      test_case "basic annotation"             `Quick t_constraint_annot_basic;
      test_case "same type as unannotated"     `Quick t_constraint_annot_same_as_unannotated;
      test_case "multiple constraints"         `Quick t_constraint_annot_multi;
      test_case "call site impl found"         `Quick t_constraint_annot_call_site_ok;
      test_case "err: call site no impl"       `Quick e_constraint_annot_call_no_impl;
    ];
    "method-level constraints", [
      test_case "extra constraint resolves"    `Quick t_method_extra_constraint;
      test_case "default body uses constraint" `Quick t_method_extra_constraint_default;
      test_case "err: no impl for extra"       `Quick e_method_extra_constraint_no_impl;
    ];
    "exhaustiveness", [
      test_case "Option both arms"          `Quick w_option_both;
      test_case "Option missing None"       `Quick w_option_missing_none;
      test_case "Option missing Some"       `Quick w_option_missing_some;
      test_case "Bool both arms"            `Quick w_bool_both;
      test_case "Bool missing False"        `Quick w_bool_missing_false;
      test_case "wildcard covers all"       `Quick w_wildcard;
      test_case "Int literals no wildcard"  `Quick w_int_no_wildcard;
      test_case "Int literals with wildcard"`Quick w_int_with_wildcard;
      test_case "redundant duplicate arm"   `Quick w_redundant_dup;
      test_case "redundant after wildcard"  `Quick w_redundant_after_wild;
      test_case "redundant ctor after wild" `Quick w_redundant_ctor_after_wild;
      test_case "ADT all ctors covered"     `Quick w_adt_all;
      test_case "ADT missing constructor"   `Quick w_adt_missing;
      test_case "List exhaustive"           `Quick w_list_exhaustive;
      test_case "List missing cons"         `Quick w_list_missing_cons;
      test_case "guarded non-exhaustive"    `Quick w_guarded_non_exhaustive;
      test_case "nested fully exhaustive"   `Quick w_nested_exhaustive;
      test_case "nested missing branch"     `Quick w_nested_missing;
      test_case "tuple exhaustive"          `Quick w_tuple_exhaustive;
    ];
    "Ref type", [
      test_case "Ref Int"                   `Quick t_ref_int;
      test_case "Ref String"                `Quick t_ref_string;
      test_case "value read poly"           `Quick t_ref_value_poly;
      test_case "value read concrete"       `Quick t_ref_value_read;
      test_case "nested Ref"                `Quick t_ref_nested;
      test_case "set_ref type"              `Quick t_set_ref_type;
      test_case "set_ref Mut ok"            `Quick t_set_ref_mut_ok;
      test_case "err: set_ref mismatch"     `Quick e_set_ref_type_mismatch;
      test_case "err: set_ref impure"       `Quick e_set_ref_impure;
    ];
    "let mut / Assign", [
      test_case "assign valid (bare block)"  `Quick t_do_assign_valid;
      test_case "err: let mut in `do`"       `Quick e_let_mut_in_do;
      test_case "err: assign in `do`"        `Quick e_assign_in_do;
      test_case "err: assign immutable"      `Quick e_do_assign_immutable;
      test_case "err: assign type mismatch"  `Quick e_do_assign_type_mismatch;
      test_case "err: assign unbound"        `Quick e_do_assign_unbound;
      test_case "err: assign as last stmt"   `Quick e_do_assign_as_last;
      test_case "err: let mut in inline let" `Quick e_let_mut_outside_do;
      test_case "err: let mut inline expr"   `Quick e_let_mut_inline_expr;
      test_case "err: let mut with annot"    `Quick e_let_mut_with_annotation;
      test_case "let mut in bare block ok"   `Quick t_let_mut_in_block_ok;
      test_case "err: `<-` outside `do`"     `Quick e_bind_outside_do;
      test_case "mixed: block w/ inner do"   `Quick t_mixed_block_with_inner_do;
    ];
    "field assignment (Phase 28)", [
      test_case "record field valid"              `Quick t_field_assign_valid;
      test_case "multiple fields"                 `Quick t_field_assign_multi;
      test_case "Ref .value assign"               `Quick t_ref_value_assign;
      test_case "read back assigned field"        `Quick t_field_assign_read_back;
      test_case "err: immutable record"           `Quick e_field_assign_immutable;
      test_case "err: unknown field"              `Quick e_field_assign_unknown_field;
      test_case "err: type mismatch"              `Quick e_field_assign_type_mismatch;
      test_case "err: field assign as last stmt"  `Quick e_field_assign_as_last;
    ];
    "extern declarations", [
      test_case "concrete type"             `Quick t_extern_concrete;
      test_case "polymorphic type"          `Quick t_extern_poly;
      test_case "constant"                  `Quick t_extern_constant;
      test_case "infer effect no annot"      `Quick t_eff_infer_extern;
      test_case "effect annotated ok"        `Quick t_extern_effect_annotated;
    ];
    "collection literals", [
      test_case "map String Int"         `Quick t_map_string_int;
      test_case "map Int Bool"           `Quick t_map_int_bool;
      test_case "set Int"                `Quick t_set_int;
      test_case "set String"             `Quick t_set_string;
      test_case "err: map key mismatch"  `Quick e_map_key_mismatch;
      test_case "err: map val mismatch"  `Quick e_map_val_mismatch;
      test_case "err: set type mismatch" `Quick e_set_type_mismatch;
    ];
    "polymorphic ops (Phase 17)", [
      test_case "Float add"              `Quick t_float_add;
      test_case "Float mul"              `Quick t_float_mul;
      test_case "Int add regression"     `Quick t_int_add_regression;
      test_case "Float eq"               `Quick t_float_eq;
      test_case "String eq"              `Quick t_string_eq;
      test_case "String lt"              `Quick t_string_lt;
      test_case "Float lt"               `Quick t_float_lt;
      test_case "Int mod"                `Quick t_int_mod;
      test_case "err: String Num"        `Quick e_string_num;
      test_case "err: Int+Float mismatch" `Quick e_int_float_mismatch;
      test_case "err: Float mod"         `Quick e_float_mod;
    ];
    "runtime.mdk externs (Phase 18)", [
      test_case "readLine type"          `Quick t_readLine_type;
      test_case "readFile type"          `Quick t_readFile_type;
      test_case "readFile infer IO"       `Quick t_readFile_infer;
      test_case "extern uppercase name"  `Quick t_extern_upper;
    ];
    "deriving (Phase 19)", [
      test_case "Eq enum"                `Quick t_derive_eq_enum;
      test_case "Eq with fields"         `Quick t_derive_eq_fields;
      test_case "Show enum"              `Quick t_derive_show_enum;
      test_case "Show with fields"       `Quick t_derive_show_fields;
      test_case "Ord enum"               `Quick t_derive_ord_enum;
      test_case "multi-derive"           `Quick t_derive_multi;
      test_case "Eq record"              `Quick t_derive_eq_record;
    ];
    "top-level function guards", [
      test_case "Int -> String"           `Quick t_guard_int_to_string;
      test_case "Int -> Int"              `Quick t_guard_int_to_int;
      test_case "err: body type mismatch" `Quick e_guard_body_mismatch;
      test_case "pattern-bind scopes"      `Quick t_pguard_bind_scopes;
      test_case "err: bind type mismatch"  `Quick e_pguard_bind_mismatch;
    ];
    "type aliases", [
      test_case "simple alias"           `Quick t_alias_simple;
      test_case "parametric alias"       `Quick t_alias_param;
      test_case "pair alias"             `Quick t_alias_pair;
      test_case "alias in annotation"    `Quick t_alias_in_annot;
      test_case "err: recursive alias"           `Quick e_alias_recursive;
      test_case "err: mutually recursive aliases" `Quick e_alias_mutual_recursive;
    ];
    "newtype declarations", [
      test_case "constructor type"       `Quick t_newtype_ctor_type;
      test_case "distinct from wrapped"  `Quick t_newtype_distinct;
      test_case "parametric newtype"     `Quick t_newtype_param;
      test_case "pattern match unwrap"   `Quick t_newtype_pattern_match;
      test_case "deriving Num typechecks" `Quick t_newtype_deriving_num_type;
    ];
    "Semigroup / Monoid (Phase 22)", [
      test_case "List ++ List"           `Quick t_list_semigroup;
      test_case "String ++ String"       `Quick t_string_semigroup;
      test_case "user-defined Semigroup" `Quick t_user_semigroup;
      test_case "err: missing Semigroup" `Quick e_no_semigroup;
      test_case "Monoid String empty"    `Quick t_monoid_string_empty;
    ];
    "string interpolation", [
      test_case "result is String"         `Quick t_interp_type;
      test_case "string hole ok"           `Quick t_interp_string_hole;
      test_case "no holes plain"           `Quick t_interp_empty_ok;
      test_case "err: Int in hole"         `Quick e_interp_int_in_hole;
    ];
    "local let-rec (Phase 27)", [
      test_case "self-recursive factorial" `Quick t_let_rec_factorial;
      test_case "accumulator tail-rec"     `Quick t_let_rec_acc;
      test_case "diverging self-call"      `Quick t_let_rec_diverge;
      test_case "non-recursive val unchanged" `Quick t_let_nonrec_val;
      test_case "where helper self-rec"    `Quick t_where_helper_rec;
    ];
    "where clauses (Phase 25)", [
      test_case "simple helper type"       `Quick t_where_simple_type;
      test_case "mutual recursion type"    `Quick t_where_mutual_type;
      test_case "polymorphic helper"       `Quick t_where_polymorphic;
      test_case "err: type mismatch"       `Quick e_where_type_mismatch;
    ];
    "record patterns (Phase 31)", [
      test_case "pun infers field type"    `Quick t_rec_pat_pun_type;
      test_case "explicit + rest"          `Quick t_rec_pat_explicit_type;
      test_case "polymorphic record"       `Quick t_rec_pat_poly;
      test_case "err: type mismatch"       `Quick e_rec_pat_type_mismatch;
      test_case "err: unknown record"      `Quick e_rec_pat_unknown_record;
    ];
    "if let / let else (Phase 38)", [
      test_case "if let match"             `Quick t_if_let_match;
      test_case "if let no match"          `Quick t_if_let_no_match;
      test_case "err: branch type mismatch" `Quick e_if_let_branch_mismatch;
      test_case "let else bind"            `Quick t_let_else_bind;
      test_case "err: let else last stmt"  `Quick e_let_else_last_stmt;
    ];
    "named-field variants (Phase 39)", [
      test_case "construction"             `Quick t_named_ctor_create;
      test_case "pattern pun"              `Quick t_named_ctor_pat_pun;
      test_case "mixed positional+named"   `Quick t_named_ctor_mixed;
      test_case "err: missing field"       `Quick e_named_ctor_missing_field;
      test_case "err: wrong field type"    `Quick e_named_ctor_wrong_field_type;
    ];
    "range literals (Phase 40)", [
      test_case "list half-open : List Int"   `Quick t_range_list_type;
      test_case "list inclusive : List Int"   `Quick t_range_list_inclusive_type;
      test_case "array half-open : Array Int" `Quick t_range_array_type;
      test_case "array inclusive : Array Int" `Quick t_range_array_inclusive_type;
      test_case "pattern int in match"        `Quick t_range_pat_int_type;
      test_case "pattern char in match"       `Quick t_range_pat_char_type;
      test_case "err: non-int range bounds"   `Quick e_range_list_non_int;
    ];
    "prop declarations (Phase 42)", [
      test_case "Int param"           `Quick t_prop_int_param;
      test_case "Bool param"          `Quick t_prop_bool_param;
      test_case "List param"          `Quick t_prop_list_param;
      test_case "err: body not Bool"  `Quick e_prop_body_not_bool;
    ];
    "function keyword (Phase 44)", [
      test_case "Option Int -> Int"   `Quick t_function_option;
      test_case "Bool -> Int"         `Quick t_function_bool;
      test_case "used as map arg"     `Quick t_function_as_arg;
    ];
    "declaration attributes (Phase 49)", [
      test_case "@deprecated emits warning"        `Quick t_deprecated_warns;
      test_case "@deprecated fn still type-checks" `Quick t_deprecated_still_typechecks;
      test_case "@must_use discard warns"          `Quick t_must_use_warns;
      test_case "@inline no error"                 `Quick t_inline_no_error;
      test_case "non-deprecated no warning"        `Quick t_no_warn_non_deprecated;
    ];
    "Eq/Num/Ord wiring (Phase 52)", [
      test_case "== on Int is Bool"                `Quick t_eq52_builtin_eq;
      test_case "== on String is Bool"             `Quick t_eq52_string_eq;
      test_case "err: == on no-Eq type"            `Quick e_eq52_no_impl;
      test_case "err: != on no-Eq type"            `Quick e_eq52_neq_no_impl;
      test_case "custom interface impl ok"         `Quick t_eq52_custom_num;
      test_case "custom Num impl with + operator"  `Quick t_eq52_custom_num_plus;
    ];
  ]
