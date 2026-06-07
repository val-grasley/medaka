open Medaka_lib
open Resolve

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

let resolve src = resolve_program (parse src)

let assert_ok src () =
  let errs = resolve src in
  if errs <> [] then
    failwith (Printf.sprintf "Expected no errors, got:\n  %s\n\nSource:\n%s"
                (String.concat "\n  " (List.map (fun (e, _) -> pp_error e) errs))
                src)

let assert_err pred src () =
  let errs = resolve src in
  if not (List.exists (fun (e, _) -> pred e) errs) then
    failwith (Printf.sprintf
      "Expected matching error, got:\n  %s\n\nSource:\n%s"
      (String.concat "\n  " (List.map (fun (e, _) -> pp_error e) errs))
      src)

(* ── Error matchers ─────────────────────────── *)

let unbound n        = function UnboundVariable x     -> x = n | _ -> false
let unknown_type n   = function UnknownType x         -> x = n | _ -> false
let unknown_ctor n   = function UnknownConstructor x  -> x = n | _ -> false
let unknown_effect n = function UnknownEffect x       -> x = n | _ -> false
let unknown_field n  = function UnknownField x        -> x = n | _ -> false
let field_not_in n r = function FieldNotInRecord (x, y) -> x = n && y = r | _ -> false
let duplicate n      = function DuplicateDefinition (_, x) -> x = n | _ -> false
let extern_with_body n = function ExternWithBody x -> x = n | _ -> false
let question_misplaced     = function QuestionMisplaced -> true | _ -> false

(* ── Valid programs ─────────────────────────── *)

let v_simple    = assert_ok "f x = x + 1\n"
let v_recursive = assert_ok "fact n = if n == 0 then 1 else n * fact (n - 1)\n"
let v_let       = assert_ok "f = let x = 5 in x + 1\n"
let v_let_chain = assert_ok "f = let x = 5 in let y = x + 1 in x + y\n"
let v_lambda    = assert_ok "apply = (x => x + 1) 5\n"
let v_nested    = assert_ok "f x = let g y = x + y in g 10\n"
let v_nested_multi = assert_ok "f x = let g y z = x + y + z in g 10 20\n"

let v_match = assert_ok
{|f opt =
  match opt
    Some x => x
    None => 0
|}

let v_match_with_data = assert_ok
{|data Tree
  = Leaf
  | Node Tree Tree

size t =
  match t
    Node l r => 1 + size l + size r
    Leaf => 0
|}

let v_do = assert_ok
{|foo = 5
bar x = x

result =
  do
    x <- foo
    y <- bar x
    pure (x + y)
|}

let v_use = assert_ok "import utils.greet\nf = greet\n"

let v_use_group = assert_ok "import list.{map, filter}\nf = map\n"

let v_record_create = assert_ok
{|record Person
  name : String
  age : Int

alice = Person { name = "Alice", age = 30 }
|}

let v_field_access = assert_ok
{|record Person
  name : String

get p = p.name
|}

let v_effect = assert_ok "readline : Unit -> <IO> String\nreadline = readline\n"

let v_typevars = assert_ok "id : a -> a\nid x = x\n"

let v_shadowing = assert_ok "f x = let x = x + 1 in x\n"

let v_multi_clause = assert_ok
{|fact : Int -> Int
fact 0 = 1
fact n = n * fact (n - 1)
|}

(* ── Errors ─────────────────────────────────── *)

let e_unbound        = assert_err (unbound "y") "f x = y\n"
let e_unbound_top    = assert_err (unbound "undefined") "f = undefined\n"
let e_unknown_type   = assert_err (unknown_type "Foo") "f : Foo -> Int\nf x = x\n"
let e_unknown_effect = assert_err (unknown_effect "Banana") "f : Int -> <Banana> Int\nf x = x\n"
(* Phase 146 gap 2: a user `effect Foo` decl registers the label so `<Foo>` resolves. *)
let v_effect_decl = assert_ok "effect Banana\nf : Int -> <Banana> Int\nf x = x\n"
let v_effect_decl_export = assert_ok "export effect KV\nf : Int -> <KV> Int\nf x = x\n"

let e_duplicate_data =
  assert_err (duplicate "Foo") "data Foo = A\ndata Foo = B\n"

let e_duplicate_ctor =
  assert_err (duplicate "X") "data A = X\ndata B = X\n"

let e_unknown_ctor_pat =
  assert_err (unknown_ctor "Other") "f (Other x) = x\n"

let e_unbound_in_arm = assert_err (unbound "y")
{|f opt =
  match opt
    Some x => y
    None => 0
|}

let e_unbound_in_let =
  assert_err (unbound "z") "f = let x = z in x\n"

let e_unknown_type_in_record =
  assert_err (unknown_type "Foo")
{|record Bag
  contents : Foo
|}

let e_unknown_ctor_create =
  (* Person isn't a declared record type *)
  assert_err (unknown_type "Person") "f = Person { name = \"Alice\" }\n"

let e_unbound_infix =
  assert_err (unbound "myop") "f x y = x `myop` y\n"

(* ── Record field resolution errors ─────────── *)

(* Field in record create doesn't belong to the named record *)
let e_field_not_in_record =
  assert_err (field_not_in "age" "Point")
{|record Point
  x : Int
  y : Int

record Person
  name : String
  age : Int

bad = Point { x = 0, y = 0, age = 99 }
|}

(* Unknown field in record creation *)
let e_unknown_field_in_create =
  assert_err (unknown_field "z")
{|record Point
  x : Int
  y : Int

bad = Point { x = 0, y = 0, z = 1 }
|}

(* Unknown field in record update *)
let e_unknown_field_in_update =
  assert_err (unknown_field "z")
{|record Point
  x : Int
  y : Int

bad p = { p | z = 1 }
|}

(* Phase 72: with shared field names the resolver can no longer pin the
   receiver's record type from a field name, so a cross-record update is no
   longer rejected at resolve time — both `x` and `name` are known fields. The
   inconsistency is now caught by the type checker (see test_typecheck's
   e_rec_cross_record_update). Resolution should succeed here. *)
let v_cross_record_update_resolves =
  assert_ok
{|record Point
  x : Int
  y : Int

record Person
  name : String

bad p = { p | x = 0, name = "Alice" }
|}

(* Phase 72: two records may share a field name; construction and pattern
   resolution accept the field for either owner. *)
let v_shared_field_create =
  assert_ok
{|record Point
  x : Int

record Vec
  x : Float

a = Point { x = 1 }
b = Vec { x = 2.0 }
|}

let v_shared_field_pattern =
  assert_ok
{|record Point
  x : Int

record Vec
  x : Float

getp (Point { x = v }) = v
|}

(* ── Extern declarations ─────────────────────── *)

let v_extern_basic = assert_ok "extern foo : Int -> Int\nbar = foo 5\n"

let v_extern_effect = assert_ok "extern myPrint : a -> <IO> Unit\nf x = myPrint x\n"

let v_extern_constant = assert_ok "extern pi : Float\narea r = pi * r * r\n"

let e_extern_with_body =
  assert_err (extern_with_body "foo") "extern foo : Int\nfoo = 5\n"

let e_extern_unknown_type =
  assert_err (unknown_type "Banana") "extern f : Banana -> Int\n"

let e_extern_unknown_effect =
  assert_err (unknown_effect "Warp") "extern f : Int -> <Warp> Unit\n"

(* ── Constraint annotation tests ────────────── *)

let unknown_iface n = function UnknownInterface x -> x = n | _ -> false

let v_constraint_known_iface =
  assert_ok
    "interface MyEq a where\n  myeq : a -> a -> Bool\n\nmyneq : MyEq a => a -> a -> Bool\nmyneq x y = myeq x y\n"

let e_constraint_unknown_iface =
  assert_err (unknown_iface "Bogus")
    "f : Bogus a => a -> Bool\nf x = True\n"

(* ── requires / super constraint name validation (Phase 67) ───── *)

let e_impl_requires_unknown_iface =
  assert_err (unknown_iface "Bogus")
    "interface MyEq a where\n  myeq : a -> a -> Bool\n\nimpl MyEq (List a) requires Bogus a where\n  myeq x y = True\n"

let e_interface_super_unknown_iface =
  assert_err (unknown_iface "Bogus")
    "interface Foo a requires Bogus a where\n  foo : a -> a\n"

let v_impl_requires_known_iface =
  assert_ok
    "interface MyEq a where\n  myeq : a -> a -> Bool\n\nimpl MyEq (List a) requires MyEq a where\n  myeq x y = True\n"

let v_interface_super_known_iface =
  assert_ok
    "interface MyEq a where\n  myeq : a -> a -> Bool\n\ninterface MyOrd a requires MyEq a where\n  mycompare : a -> a -> Bool\n"

(* ── @Impl disambiguation hints (Phase 86) ───── *)

(* `@Additive` is a method-dispatch hint, not a value reference — resolve must
   not flag it as an unbound variable. Unknown hint names are validated later
   by typecheck (UnknownImplName), so resolve simply accepts any @-prefixed
   occurrence. *)
let v_at_impl_hint =
  assert_ok
    "interface Combine a where\n  combine : a -> a -> a\n\nimpl Additive of Combine Int where\n  combine x y = x + y\n\nr = combine @Additive 3 4\n"

(* Standalone @Name occurrence reaches resolve through the same EVar path. *)
let v_at_hint_standalone =
  assert_ok "r = @Foo\n"

(* Methods declared in core.mdk's interfaces must be in scope in user
   files even when no impl in core provides them — bare interface
   defaults count.  Regression test for the resolver gap that left
   `max`/`min`/`debug` unbound (see project_resolver_prelude_methods.md). *)
let v_prelude_method_max_in_scope =
  assert_ok "result = max 3 5\n"

let v_prelude_method_min_in_scope =
  assert_ok "result = min 3 5\n"

let v_prelude_method_show_in_scope =
  assert_ok "result = debug 42\n"

(* Methods that already had core-provided impls should still resolve —
   guard against the fix accidentally double-seeding and breaking these. *)
let v_prelude_method_eq_in_scope =
  assert_ok "result = eq 3 3\n"

let v_prelude_method_compare_in_scope =
  assert_ok "result = compare 3 5\n"

(* ── Type alias tests ────────────────────────── *)

let v_alias_simple =
  assert_ok "type Name = String\ngreet : Name -> String\ngreet n = n\n"

let v_alias_param =
  assert_ok "type Wrapper a = Option a\n"

let v_alias_typevar_ok =
  assert_ok "type Pair a b = (a, b)\n"

let e_alias_unknown_type =
  assert_err (unknown_type "Bogus")
    "type Foo = Bogus\n"

let e_alias_duplicate =
  assert_err (duplicate "Foo")
    "type Foo = String\ntype Foo = Int\n"

(* ── Newtype tests ───────────────────────────── *)

let v_newtype_simple =
  assert_ok "newtype UserId = UserId Int\n"

let v_newtype_param =
  assert_ok "newtype Wrapper a = Wrap a\n"

let e_newtype_unknown_type =
  assert_err (unknown_type "Bogus")
    "newtype Foo = Foo Bogus\n"

let e_newtype_duplicate =
  assert_err (duplicate "Foo")
    "newtype Foo = Foo Int\nnewtype Foo = Foo String\n"

(* `?` is only legal as the RHS of a `let` binding.  Misplaced uses survive
   the desugar pass and are flagged here. *)
let e_question_in_arith =
  assert_err question_misplaced
    "f = (Ok 5 ?) + 1\n"

let e_question_in_arg =
  assert_err question_misplaced
    "f = Ok (5 ?)\n"

(* ── Phase 57: let rec ──────────────────────── *)

let nonrec_value_let n = function NonRecursiveValueLet x -> x = n | _ -> false

let v_letrec_inline = assert_ok
  "f = let rec fact = n => if n == 0 then 1 else n * fact (n - 1) in fact 5\n"

let v_letrec_top = assert_ok
  "let rec fact = n => if n == 0 then 1 else n * fact (n - 1)\n\
   main = fact 5\n"

let v_letrec_mutual_top = assert_ok
  "let rec is_even = n => if n == 0 then True else is_odd (n - 1)\n\
   with is_odd = n => if n == 0 then False else is_even (n - 1)\n\
   main = is_even 4\n"

let e_let_value_self_ref =
  assert_err (nonrec_value_let "x")
    "f = let x = x + 1 in x\n"

(* ── Cross-module effect export (Phase 146) ─── *)

let resolve_module_chain srcs =
  let parse_src src =
    Lexer.reset ();
    Parser.program Lexer.token (Lexing.from_string src)
  in
  let rec go known = function
    | [] -> (known, [])
    | (id, src) :: rest ->
      let prog = parse_src src in
      let (exp, errs) = resolve_module known id prog in
      let (all_exps, all_errs) = go (exp :: known) rest in
      (all_exps, errs @ all_errs)
  in
  snd (go [] srcs)

(* exported effect label is visible in importing module *)
let v_effect_cross_module = fun () ->
  let errs = resolve_module_chain [
    ("effect_a", "export effect Fetch\n");
    ("effect_b", "import effect_a\nf : Unit -> <Fetch> Unit\nf _ = ()\n");
  ] in
  if errs <> [] then
    failwith (Printf.sprintf "Expected no errors, got: %s"
      (String.concat "; " (List.map (fun (e, _) -> pp_error e) errs)))

(* private effect not exported → UnknownEffect in importer *)
let e_effect_cross_module_private = fun () ->
  let errs = resolve_module_chain [
    ("effect_a", "effect Fetch\n");
    ("effect_b", "import effect_a\nf : Unit -> <Fetch> Unit\nf _ = ()\n");
  ] in
  if not (List.exists (fun (e, _) -> unknown_effect "Fetch" e) errs) then
    failwith (Printf.sprintf "Expected UnknownEffect Fetch, got: %s"
      (String.concat "; " (List.map (fun (e, _) -> pp_error e) errs)))

(* ── Test runner ─────────────────────────────── *)

let () =
  let open Alcotest in
  run "Resolve" [
    "valid programs", [
      test_case "simple"            `Quick v_simple;
      test_case "recursive"         `Quick v_recursive;
      test_case "let"               `Quick v_let;
      test_case "let chain"         `Quick v_let_chain;
      test_case "lambda"            `Quick v_lambda;
      test_case "nested closure"    `Quick v_nested;
      test_case "nested multi-arg"  `Quick v_nested_multi;
      test_case "match"             `Quick v_match;
      test_case "match with data"   `Quick v_match_with_data;
      test_case "do block"          `Quick v_do;
      test_case "use brings name"   `Quick v_use;
      test_case "use group"         `Quick v_use_group;
      test_case "record create"     `Quick v_record_create;
      test_case "field access"      `Quick v_field_access;
      test_case "shared field create"  `Quick v_shared_field_create;
      test_case "shared field pattern" `Quick v_shared_field_pattern;
      test_case "cross-record update resolves" `Quick v_cross_record_update_resolves;
      test_case "effect type"       `Quick v_effect;
      test_case "effect decl registers label" `Quick v_effect_decl;
      test_case "export effect decl"          `Quick v_effect_decl_export;
      test_case "type vars OK"      `Quick v_typevars;
      test_case "shadowing OK"      `Quick v_shadowing;
      test_case "multi-clause fn"   `Quick v_multi_clause;
      test_case "let rec inline"          `Quick v_letrec_inline;
      test_case "let rec top-level"       `Quick v_letrec_top;
      test_case "let rec mutual top"      `Quick v_letrec_mutual_top;
    ];
    "errors", [
      test_case "unbound local"        `Quick e_unbound;
      test_case "unbound top-level"    `Quick e_unbound_top;
      test_case "unknown type"         `Quick e_unknown_type;
      test_case "unknown effect"       `Quick e_unknown_effect;
      test_case "duplicate type"       `Quick e_duplicate_data;
      test_case "duplicate ctor"       `Quick e_duplicate_ctor;
      test_case "unknown ctor in pat"  `Quick e_unknown_ctor_pat;
      test_case "unbound in match arm" `Quick e_unbound_in_arm;
      test_case "unbound in let RHS"   `Quick e_unbound_in_let;
      test_case "unknown type in rec"  `Quick e_unknown_type_in_record;
      test_case "unknown rec type"     `Quick e_unknown_ctor_create;
      test_case "unbound infix"        `Quick e_unbound_infix;
      test_case "field not in record"  `Quick e_field_not_in_record;
      test_case "unknown field create" `Quick e_unknown_field_in_create;
      test_case "unknown field update" `Quick e_unknown_field_in_update;
      test_case "? in arith"           `Quick e_question_in_arith;
      test_case "? in fn arg"          `Quick e_question_in_arg;
      test_case "let value self-ref"   `Quick e_let_value_self_ref;
    ];
    "extern declarations", [
      test_case "basic ok"            `Quick v_extern_basic;
      test_case "with effect ok"      `Quick v_extern_effect;
      test_case "constant ok"         `Quick v_extern_constant;
      test_case "err: with body"      `Quick e_extern_with_body;
      test_case "err: unknown type"   `Quick e_extern_unknown_type;
      test_case "err: unknown effect" `Quick e_extern_unknown_effect;
    ];
    "constraint annotations", [
      test_case "known iface ok"       `Quick v_constraint_known_iface;
      test_case "err: unknown iface"   `Quick e_constraint_unknown_iface;
    ];
    "requires / super constraints", [
      test_case "impl requires known ok"   `Quick v_impl_requires_known_iface;
      test_case "interface super known ok" `Quick v_interface_super_known_iface;
      test_case "err: impl requires unknown"   `Quick e_impl_requires_unknown_iface;
      test_case "err: interface super unknown" `Quick e_interface_super_unknown_iface;
      test_case "@impl hint resolves ok"   `Quick v_at_impl_hint;
      test_case "@hint standalone ok"      `Quick v_at_hint_standalone;
    ];
    "prelude methods in user scope", [
      test_case "max ok"     `Quick v_prelude_method_max_in_scope;
      test_case "min ok"     `Quick v_prelude_method_min_in_scope;
      test_case "debug ok"    `Quick v_prelude_method_show_in_scope;
      test_case "eq still ok" `Quick v_prelude_method_eq_in_scope;
      test_case "compare still ok" `Quick v_prelude_method_compare_in_scope;
    ];
    "type aliases", [
      test_case "simple alias ok"      `Quick v_alias_simple;
      test_case "parametric alias ok"  `Quick v_alias_param;
      test_case "typevar alias ok"     `Quick v_alias_typevar_ok;
      test_case "err: unknown type"    `Quick e_alias_unknown_type;
      test_case "err: duplicate"       `Quick e_alias_duplicate;
    ];
    "newtype declarations", [
      test_case "simple newtype ok"    `Quick v_newtype_simple;
      test_case "parametric newtype ok" `Quick v_newtype_param;
      test_case "err: unknown type"    `Quick e_newtype_unknown_type;
      test_case "err: duplicate"       `Quick e_newtype_duplicate;
    ];
    "string interpolation", [
      test_case "bound var ok"          `Quick (assert_ok "name = \"Alice\"\nx = \"hello \\{name}!\"\n");
      test_case "err: unbound in hole"  `Quick (assert_err (unbound "missing") "x = \"hi \\{missing}!\"\n");
    ];
    "record patterns", [
      test_case "pun ok" `Quick (assert_ok
        "record Person\n  name : String\n  age : Int\nf p =\n  match p\n    Person { name } => name\n");
      test_case "explicit ok" `Quick (assert_ok
        "record Person\n  name : String\n  age : Int\nf p =\n  match p\n    Person { name = \"Alice\" } => 0\n");
      test_case "err: unknown record type" `Quick (assert_err (unknown_type "Ghost")
        "f p =\n  match p\n    Ghost { name } => name\n");
      test_case "err: unknown field" `Quick (assert_err (unknown_field "missing")
        "record Person\n  name : String\nf p =\n  match p\n    Person { missing } => 0\n");
      test_case "err: field from other record" `Quick (assert_err (field_not_in "age" "Person")
        "record Person\n  name : String\nrecord Dog\n  age : Int\nf p =\n  match p\n    Person { age } => 0\n");
    ];
    "cross-module effect export (Phase 146)", [
      test_case "exported effect visible in importer"     `Quick v_effect_cross_module;
      test_case "private effect not visible in importer"  `Quick e_effect_cross_module_private;
    ];
  ]
