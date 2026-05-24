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
  try Ok (check_program (parse src))
  with Type_error e -> Error e

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

let t_identity   = assert_type "id x = x\n"           "id"   "'a -> 'a"
let t_const_fn   = assert_type "const x _ = x\n"      "const" "'a -> 'b -> 'a"
let t_double     = assert_type "double x = x + x\n"   "double" "Int -> Int"
let t_inc        = assert_type "inc x = x + 1\n"      "inc"  "Int -> Int"
let t_apply      = assert_type "apply f x = f x\n"    "apply" "('a -> 'b) -> 'a -> 'b"
let t_compose    = assert_type "compose f g x = f (g x)\n"  "compose"
                     "('a -> 'b) -> ('c -> 'a) -> 'c -> 'b"

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
  "id : a -> a\nid x = x\n" "id" "'a -> 'a"

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
|} "withDefault" "'a -> Option 'a -> 'a"

let t_some_int = assert_type
  "x = Some 5\n" "x" "Option Int"

let t_user_adt = assert_type
  {|data Tree a
  | Leaf
  | Node (Tree a) a (Tree a)

singleton x = Node Leaf x Leaf
|} "singleton" "'a -> Tree 'a"

let t_size = assert_type
  {|data Tree a
  | Leaf
  | Node (Tree a) a (Tree a)

size t =
  match t
    Leaf => 0
    Node l _ r => 1 + size l + size r
|} "size" "Tree 'a -> Int"

(* ── Lists ──────────────────────────────────────── *)

let t_list_int = assert_type "xs = [1, 2, 3]\n" "xs" "List Int"

let t_list_empty = assert_type "xs = []\n" "xs" "List 'a"

let t_length = assert_type
  {|len xs =
  match xs
    [] => 0
    _ :: rest => 1 + len rest
|} "len" "List 'a -> Int"

let t_map = assert_type
  {|map f xs =
  match xs
    [] => []
    x :: rest => f x :: map f rest
|} "map" "('a -> 'b) -> List 'a -> List 'b"

(* ── Tuples ─────────────────────────────────────── *)

let t_swap = assert_type
  {|swap p =
  match p
    (a, b) => (b, a)
|} "swap" "('a, 'b) -> ('b, 'a)"

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
|} "swap" "Pair 'a 'b -> Pair 'b 'a"

(* Polymorphic record — access *)
let t_rec_poly_access = assert_type
  {|record Box a
  value : a

unbox b = b.value
|} "unbox" "Box 'a -> 'a"

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
  "f" "'a 'b -> 'a 'b"

(* DoBind then pure: monad is left abstract (works for any monad) *)
let t_do_bind_pure = assert_type
  "addOne opt =\n  do\n    x <- opt\n    pure (x + 1)\n"
  "addOne" "'a Int -> 'a Int"

(* Two binds then pure *)
let t_do_two_binds = assert_type
  "f a b =\n  do\n    x <- a\n    y <- b\n    pure (x + y)\n"
  "f" "'a Int -> 'a Int -> 'a Int"

(* DoLet: plain binding inside a do block, no monadic wrapping *)
let t_do_let = assert_type
  "f opt =\n  do\n    x <- opt\n    let y = x + 1\n    pure y\n"
  "f" "'a Int -> 'a Int"

(* pure alone: wrap any value in any monad *)
let t_do_pure = assert_type
  "wrap x =\n  do\n    pure x\n"
  "wrap" "'a -> 'b 'a"

(* pure after bind: identity for any monad *)
let t_do_pure_after_bind = assert_type
  "identity opt =\n  do\n    x <- opt\n    pure x\n"
  "identity" "'a 'b -> 'a 'b"

(* Tuple destructuring in a DoBind *)
let t_do_tuple_bind = assert_type
  "f opt =\n  do\n    (x, y) <- opt\n    pure (x + y)\n"
  "f" "'a (Int, Int) -> 'a Int"

(* DoExpr in the middle: value is discarded but must still be monadic *)
let t_do_skip_middle = assert_type
  "f opt1 opt2 =\n  do\n    x <- opt1\n    opt2\n    pure x\n"
  "f" "'a 'b -> 'a 'c -> 'a 'b"

(* Top-level do block with a concrete monad (Option) *)
let t_do_toplevel = assert_type
  "result =\n  do\n    x <- Some 10\n    pure (x * 2)\n"
  "result" "Option Int"

(* DoLet with a local function *)
let t_do_let_fn = assert_type
  "f opt =\n  do\n    x <- opt\n    let double n = n + n\n    pure (double x)\n"
  "f" "'a Int -> 'a Int"

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
  "add x y = x + y\n" "add" "Int -> Int -> Int"

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
  "eq" "'a -> 'a -> Bool"

(* Impl type-checks successfully *)
let t_iface_impl_ok = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y
|}
  "eq" "'a -> 'a -> Bool"

(* Method is usable in a top-level function *)
let t_iface_method_use = assert_type
  {|interface Eq a where
  eq : a -> a -> Bool

impl Eq Int where
  eq x y = x == y

f x y = eq x y
|}
  "f" "'a -> 'a -> Bool"

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
  "show" "'a -> String"

(* Polymorphic impl — Show for Option *)
let t_iface_poly_impl = assert_type
  {|interface Show a where
  show : a -> String

impl Show Int where
  show x = "int"

impl Show Bool where
  show x = "bool"
|}
  "show" "'a -> String"

(* Higher-kinded interface — Mappable f *)
let t_iface_hkt = assert_type
  {|interface Mappable f where
  fmap : (a -> b) -> f a -> f b
|}
  "fmap" "('a -> 'b) -> 'c 'a -> 'c 'b"

(* Named impl — impl_name (lowercase per parser grammar) is stored, no type error.
   The parser uses IDENT for the impl name so it must be lowercase. *)
let t_iface_named_impl = assert_type
  {|interface Monoid a where
  mempty : a
  mappend : a -> a -> a

impl additive of Monoid Int where
  mempty = 0
  mappend x y = x + y
|}
  "mempty" "'a"

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
  "empty" "'a 'b"

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
  ]
