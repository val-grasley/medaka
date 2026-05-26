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

(* Single DoExpr: x must be monadic, so f's arg is constrained to m a *)
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
  "greet" "String -> Unit"

(* Transitive IO: calling an IO fn propagates the effect to its caller *)
let t_eff_transitive = assert_type
  "greet : String -> <IO> Unit\ngreet name = print name\n\
   welcome : String -> <IO> Unit\nwelcome name = greet name\n"
  "welcome" "String -> Unit"

(* Over-annotation is OK: declared <IO, Rand> but only performs <IO> *)
let t_eff_over_annotated = assert_type
  "f : <IO, Rand> Unit\nf = print \"hi\"\n" "f" "Unit"

(* Pipe into an effectful function: f : <IO> Unit;  f = "hello" |> print *)
let t_eff_pipe_io = assert_type
  "f : <IO> Unit\nf = \"hello\" |> print\n" "f" "Unit"

(* Compose of two pure functions — composed result is also pure *)
let t_eff_compose_pure = assert_type
  "inc x = x + 1\ndbl x = x * 2\nf = inc >> dbl\n" "f" "Int -> Int"

(* Error: unannotated function calls print → ImpureFunction *)
let e_eff_impure_no_annot = assert_err
  "f = print \"hi\"\n"

(* Error: function annotated as pure (no <...>) but calls print → EffectEscape *)
let e_eff_escape_annotated_pure = assert_err
  "f : String -> Unit\nf x = print x\n"

(* Error: annotated as <Rand> but performs <IO> → EffectEscape (extra: IO) *)
let e_eff_escape_wrong_effect = assert_err
  "f : <Rand> Unit\nf = print \"hi\"\n"

(* Error: IO effect escapes through a lambda body inside the unannotated fn *)
let e_eff_lambda_body_propagates = assert_err
  "bad = (x => print x) \"hi\"\n"

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

(* @Name hint in application position drops silently — method types correctly *)
let t_constraint_at_name_drop = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

f = eq @Eq 1 2
|}
  "f" "Bool"

(* Error: method called with a type that has no impl *)
let e_constraint_no_impl = assert_err
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

f = eq 1.0 2.0
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
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

check : String -> String -> Bool
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
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

neq : Eq a => a -> a -> Bool
neq x y = eq x y

bad = neq 1.0 2.0
|}

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
  "f" "Ref Int -> Unit"

(* set_ref with <Mut> annotation: String cell *)
let t_set_ref_mut_ok = assert_type
  "f : Ref String -> <Mut> Unit\nf r = set_ref r \"hi\"\n"
  "f" "Ref String -> Unit"

(* set_ref type mismatch: r : Ref Int, but passing String *)
let e_set_ref_type_mismatch = assert_err
  "r = Ref 5\nbad = set_ref r \"hello\"\n"

(* set_ref without <Mut> annotation → ImpureFunction *)
let e_set_ref_impure = assert_err
  "f : Ref Int -> Unit\nf r = set_ref r 0\n"

(* ── Phase 8.5: let mut + DoAssign ──────────────── *)

(* DoAssign on a let-mut binding succeeds *)
let t_do_assign_valid = assert_type
  "f =\n  do\n    let mut x = 5\n    x = 10\n    pure x\n"
  "f" "a Int"

(* DoAssign after DoBind *)
let t_do_assign_after_bind = assert_type
  "f opt =\n  do\n    let mut x = 0\n    y <- opt\n    x = y\n    pure x\n"
  "f" "a Int -> a Int"

(* DoAssign to an immutable binding → ImmutableAssignment *)
let e_do_assign_immutable = assert_err
  "bad =\n  do\n    let x = 5\n    x = 10\n    pure x\n"

(* DoAssign type mismatch: mut Int, assign String *)
let e_do_assign_type_mismatch = assert_err
  "bad =\n  do\n    let mut x = 5\n    x = \"hello\"\n    pure x\n"

(* DoAssign unbound variable → UnboundVar *)
let e_do_assign_unbound = assert_err
  "bad =\n  do\n    x = 10\n    pure 42\n"

(* do block ending with DoAssign → error *)
let e_do_assign_as_last = assert_err
  "bad =\n  do\n    let mut x = 5\n    x = 1\n"

(* ── Phase 28: DoFieldAssign ────────────────────── *)

let person_src = {|record Person
  name : String
  age  : Int

|}

(* Basic field assignment on a mutable record *)
let t_field_assign_valid = assert_type
  (person_src ^ {|go =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = 31
    pure p
|})
  "go" "a Person"

(* Multiple field assignments *)
let t_field_assign_multi = assert_type
  (person_src ^ {|go =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = 31
    p.name = "Bob"
    pure p
|})
  "go" "a Person"

(* Ref .value assignment *)
let t_ref_value_assign = assert_type
  {|go =
  do
    let mut r = Ref 0
    r.value = 42
    pure r.value
|}
  "go" "a Int"

(* Field assignment after reading the old value *)
let t_field_assign_read_back = assert_type
  (person_src ^ {|go =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = p.age + 1
    pure p.age
|})
  "go" "a Int"

(* Field assignment on immutable binding → ImmutableAssignment *)
let e_field_assign_immutable = assert_err
  (person_src ^ {|bad =
  do
    let p = Person { name = "Alice", age = 30 }
    p.age = 31
    pure p
|})

(* Unknown field → UnknownField *)
let e_field_assign_unknown_field = assert_err
  (person_src ^ {|bad =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.nosuchfield = 99
    pure p
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

(* extern with effect: caller without annotation → ImpureFunction *)
let e_extern_effect_impure = assert_err
  "extern myPrint : a -> <IO> Unit\nbad = myPrint 42\n"

(* extern with effect: caller with matching annotation → ok *)
let t_extern_effect_annotated = assert_type
  "extern myPrint : a -> <IO> Unit\nf : a -> <IO> Unit\nf x = myPrint x\n"
  "f" "a -> Unit"

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
  "f" "Unit -> String"

(* readFile: takes a String path, returns Result String String *)
let t_readFile_type = assert_type
  "f : String -> <IO> (Result String String)\nf p = readFile p\n"
  "f" "String -> Result String String"

(* effect propagation: function calling readFile picks up IO *)
let e_readFile_impure = assert_err
  "bad p = readFile p\n"

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
      test_case "pure fn no annotation"  `Quick t_eff_pure;
      test_case "IO with annotation"     `Quick t_eff_io_annotated;
      test_case "transitive IO"          `Quick t_eff_transitive;
      test_case "over-annotation ok"     `Quick t_eff_over_annotated;
      test_case "pipe into IO fn"        `Quick t_eff_pipe_io;
      test_case "compose pure"           `Quick t_eff_compose_pure;
      test_case "err: impure no annot"   `Quick e_eff_impure_no_annot;
      test_case "err: escape pure annot" `Quick e_eff_escape_annotated_pure;
      test_case "err: wrong effect"      `Quick e_eff_escape_wrong_effect;
      test_case "err: lambda propagates" `Quick e_eff_lambda_body_propagates;
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
      test_case "default method"         `Quick t_iface_default_method;
      test_case "@Name annotation"       `Quick t_iface_at_annotation;
      test_case "err: unknown interface" `Quick e_iface_unknown;
      test_case "err: missing method"    `Quick e_iface_missing_method;
      test_case "err: wrong type"        `Quick e_iface_wrong_type;
      test_case "err: extra method"      `Quick e_iface_extra_method;
      test_case "err: arity mismatch"    `Quick e_iface_arity;
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
    "constraint annotation syntax (Phase 20)", [
      test_case "basic annotation"             `Quick t_constraint_annot_basic;
      test_case "same type as unannotated"     `Quick t_constraint_annot_same_as_unannotated;
      test_case "multiple constraints"         `Quick t_constraint_annot_multi;
      test_case "call site impl found"         `Quick t_constraint_annot_call_site_ok;
      test_case "err: call site no impl"       `Quick e_constraint_annot_call_no_impl;
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
    "let mut / DoAssign", [
      test_case "assign valid"              `Quick t_do_assign_valid;
      test_case "assign after bind"         `Quick t_do_assign_after_bind;
      test_case "err: assign immutable"     `Quick e_do_assign_immutable;
      test_case "err: assign type mismatch" `Quick e_do_assign_type_mismatch;
      test_case "err: assign unbound"       `Quick e_do_assign_unbound;
      test_case "err: assign as last stmt"  `Quick e_do_assign_as_last;
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
      test_case "err: impure without annot" `Quick e_extern_effect_impure;
      test_case "effect annotated ok"       `Quick t_extern_effect_annotated;
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
      test_case "err: readFile impure"   `Quick e_readFile_impure;
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
  ]
