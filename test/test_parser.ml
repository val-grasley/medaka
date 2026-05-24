open Medaka_lib
open Ast

(* ── Parse helpers ───────────────────────────────────── *)

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  let prog =
    try Parser.program Lexer.token lexbuf
    with
    | Parser.Error ->
      let pos = lexbuf.Lexing.lex_curr_p in
      failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                  pos.Lexing.pos_lnum
                  (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                  src)
  in
  Ast.strip_locs_program prog

let pp_decl d =
  match d with
  | DTypeSig (n, t)    -> Printf.sprintf "DTypeSig(%s, %s)" n (Ast.pp_ty t)
  | DFunDef (n, ps, e) -> Printf.sprintf "DFunDef(%s, [%s], %s)" n
                            (String.concat "; " (List.map Ast.pp_pat ps))
                            (Ast.pp_expr e)
  | DData (n, _, _)    -> Printf.sprintf "DData(%s, ...)" n
  | DRecord (n, _, _)  -> Printf.sprintf "DRecord(%s, ...)" n
  | DInterface { iface_name; _ } -> Printf.sprintf "DInterface(%s)" iface_name
  | DImpl { iface_name; _ }      -> Printf.sprintf "DImpl(%s)" iface_name
  | DUse (pub, _)      -> Printf.sprintf "DUse(pub=%b, ...)" pub
  | DExtern (n, t)    -> Printf.sprintf "DExtern(%s, %s)" n (Ast.pp_ty t)

let parse_one src =
  match parse src with
  | [decl] -> decl
  | decls  ->
    failwith (Printf.sprintf "expected 1 decl, got %d:\n  %s"
                (List.length decls)
                (String.concat "\n  " (List.map pp_decl decls)))

let parse_expr src =
  match parse_one ("v = " ^ src ^ "\n") with
  | DFunDef (_, [], e) -> e
  | d -> failwith (Printf.sprintf "expected fun def, got: %s" (pp_decl d))

let _ = pp_decl  (* silence unused warning until tests use it *)

(* ── Type signature tests ────────────────────────────── *)

let test_typesig_simple () =
  match parse_one "add : Int -> Int -> Int\n" with
  | DTypeSig ("add", TyFun (TyCon "Int", TyFun (TyCon "Int", TyCon "Int"))) -> ()
  | _ -> failwith "wrong"

let test_typesig_typevar () =
  match parse_one "id : a -> a\n" with
  | DTypeSig ("id", TyFun (TyVar "a", TyVar "a")) -> ()
  | _ -> failwith "wrong"

let test_typesig_effect () =
  match parse_one "readFile : String -> <IO> String\n" with
  | DTypeSig ("readFile", TyFun (TyCon "String", TyEffect (["IO"], TyCon "String"))) -> ()
  | _ -> failwith "wrong"

let test_typesig_multieffect () =
  match parse_one "fetch : String -> <Async, IO> String\n" with
  | DTypeSig ("fetch", TyFun (TyCon "String", TyEffect (["Async"; "IO"], TyCon "String"))) -> ()
  | _ -> failwith "wrong"

let test_typesig_typeapp () =
  match parse_one "head : List a -> Option a\n" with
  | DTypeSig ("head", TyFun (TyApp (TyCon "List", TyVar "a"),
                             TyApp (TyCon "Option", TyVar "a"))) -> ()
  | _ -> failwith "wrong"

(* ── Function definition tests ──────────────────────── *)

let test_fundef_simple () =
  match parse_one "answer = 42\n" with
  | DFunDef ("answer", [], ELit (LInt 42)) -> ()
  | _ -> failwith "wrong"

let test_fundef_with_arg () =
  match parse_one "double x = x + x\n" with
  | DFunDef ("double", [PVar "x"], EBinOp ("+", EVar "x", EVar "x")) -> ()
  | _ -> failwith "wrong"

let test_fundef_pattern_lit () =
  match parse_one "factorial 0 = 1\n" with
  | DFunDef ("factorial", [PLit (LInt 0)], ELit (LInt 1)) -> ()
  | _ -> failwith "wrong"

let test_fundef_wildcard () =
  match parse_one "const x _ = x\n" with
  | DFunDef ("const", [PVar "x"; PWild], EVar "x") -> ()
  | _ -> failwith "wrong"

let test_fundef_cons_pattern () =
  match parse_one "head (x::_) = x\n" with
  | DFunDef ("head", [PCons (PVar "x", PWild)], EVar "x") -> ()
  | _ -> failwith "wrong"

let test_fundef_constructor_pattern () =
  match parse_one "unwrap (Some x) = x\n" with
  | DFunDef ("unwrap", [PCon ("Some", [PVar "x"])], EVar "x") -> ()
  | _ -> failwith "wrong"

(* ── Expression tests ────────────────────────────────── *)

let test_expr_lambda () =
  match parse_expr "x => x + 1\n" with
  | ELam ([PVar "x"], EBinOp ("+", EVar "x", ELit (LInt 1))) -> ()
  | _ -> failwith "wrong"

let test_expr_lambda_multi_arg () =
  match parse_expr "(x, y) => x + y\n" with
  | ELam ([PTuple [PVar "x"; PVar "y"]], EBinOp ("+", EVar "x", EVar "y")) -> ()
  | _ -> failwith "wrong"

let test_expr_let () =
  match parse_expr "let x = 5 in x + 1\n" with
  | ELet (false, PVar "x", ELit (LInt 5), EBinOp ("+", EVar "x", ELit (LInt 1))) -> ()
  | _ -> failwith "wrong"

let test_expr_let_mut () =
  match parse_expr "let mut x = 5 in x\n" with
  | ELet (true, PVar "x", ELit (LInt 5), EVar "x") -> ()
  | _ -> failwith "wrong"

let test_expr_let_fn_one_arg () =
  (* let f x = x + 1 in f 5  ⇒  let f = (x => x + 1) in f 5 *)
  match parse_expr "let f x = x + 1 in f 5\n" with
  | ELet (false, PVar "f",
          ELam ([PVar "x"], EBinOp ("+", EVar "x", ELit (LInt 1))),
          EApp (EVar "f", ELit (LInt 5))) -> ()
  | _ -> failwith "wrong"

let test_expr_let_fn_multi_arg () =
  (* let g x y = x + y in g 1 2  ⇒  let g = (x => y => x + y) in g 1 2 *)
  match parse_expr "let g x y = x + y in g 1 2\n" with
  | ELet (false, PVar "g",
          ELam ([PVar "x"],
                ELam ([PVar "y"], EBinOp ("+", EVar "x", EVar "y"))),
          EApp (EApp (EVar "g", ELit (LInt 1)), ELit (LInt 2))) -> ()
  | _ -> failwith "wrong"

let test_expr_if () =
  match parse_expr "if x > 0 then x else 0\n" with
  | EIf (EBinOp (">", EVar "x", ELit (LInt 0)), EVar "x", ELit (LInt 0)) -> ()
  | _ -> failwith "wrong"

let test_expr_application () =
  match parse_expr "f x y\n" with
  | EApp (EApp (EVar "f", EVar "x"), EVar "y") -> ()
  | _ -> failwith "wrong"

let test_expr_infix_backtick () =
  match parse_expr "x `div` y\n" with
  | EInfix ("div", EVar "x", EVar "y") -> ()
  | _ -> failwith "wrong"

let test_expr_list_literal () =
  match parse_expr "[1, 2, 3]\n" with
  | EListLit [ELit (LInt 1); ELit (LInt 2); ELit (LInt 3)] -> ()
  | _ -> failwith "wrong"

let test_expr_array_literal () =
  match parse_expr "[|1, 2, 3|]\n" with
  | EArrayLit [ELit (LInt 1); ELit (LInt 2); ELit (LInt 3)] -> ()
  | _ -> failwith "wrong"

let test_expr_tuple () =
  match parse_expr "(1, \"hello\")\n" with
  | ETuple [ELit (LInt 1); ELit (LString "hello")] -> ()
  | _ -> failwith "wrong"

let test_expr_field_access () =
  match parse_expr "person.name\n" with
  | EFieldAccess (EVar "person", "name") -> ()
  | _ -> failwith "wrong"

let test_expr_record_create () =
  match parse_expr "Person { name = \"Alice\", age = 30 }\n" with
  | ERecordCreate ("Person", [("name", ELit (LString "Alice")); ("age", ELit (LInt 30))]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_update () =
  match parse_expr "{ p | age = 31 }\n" with
  | ERecordUpdate (EVar "p", [("age", ELit (LInt 31))]) -> ()
  | _ -> failwith "wrong"

let test_expr_type_annot () =
  match parse_expr "x : Int\n" with
  | EAnnot (EVar "x", TyCon "Int") -> ()
  | _ -> failwith "wrong"

let test_expr_index () =
  match parse_expr "arr[0]\n" with
  | EIndex (EVar "arr", ELit (LInt 0)) -> ()
  | _ -> failwith "wrong"

(* ── Match expression tests ──────────────────────────── *)

let test_match_basic () =
  let src = {|
f x =
  match x
    0 => "zero"
    _ => "nonzero"
|} in
  match parse_one src with
  | DFunDef ("f", [PVar "x"],
      EMatch (EVar "x", [
        (PLit (LInt 0), None, ELit (LString "zero"));
        (PWild, None, ELit (LString "nonzero"));
      ])) -> ()
  | _ -> failwith "wrong"

let test_match_with_guard () =
  let src = {|
sign x =
  match x
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
|} in
  match parse_one src with
  | DFunDef ("sign", [PVar "x"],
      EMatch (EVar "x", [
        (PVar "n", Some (EBinOp (">", EVar "n", ELit (LInt 0))), ELit (LInt 1));
        (PVar "n", Some (EBinOp ("<", EVar "n", ELit (LInt 0))), EUnOp ("-", ELit (LInt 1)));
        (PWild, None, ELit (LInt 0));
      ])) -> ()
  | _ -> failwith "wrong"

(* ── Data type tests ─────────────────────────────────── *)

let test_data_inline () =
  match parse_one "data Bool = True | False\n" with
  | DData ("Bool", [], [
      { con_name = "True";  con_fields = [] };
      { con_name = "False"; con_fields = [] };
    ]) -> ()
  | _ -> failwith "wrong"

let test_data_with_fields () =
  match parse_one "data Option a = Some a | None\n" with
  | DData ("Option", ["a"], [
      { con_name = "Some"; con_fields = [TyVar "a"] };
      { con_name = "None"; con_fields = [] };
    ]) -> ()
  | _ -> failwith "wrong"

let test_data_block () =
  let src = {|
data Shape
  | Circle Float
  | Rectangle Float Float
|} in
  match parse_one src with
  | DData ("Shape", [], [
      { con_name = "Circle";    con_fields = [TyCon "Float"] };
      { con_name = "Rectangle"; con_fields = [TyCon "Float"; TyCon "Float"] };
    ]) -> ()
  | _ -> failwith "wrong"

(* ── Record type tests ───────────────────────────────── *)

let test_record_decl () =
  let src = {|
record Person
  name : String
  age : Int
|} in
  match parse_one src with
  | DRecord ("Person", [], [
      { field_name = "name"; field_type = TyCon "String" };
      { field_name = "age";  field_type = TyCon "Int" };
    ]) -> ()
  | _ -> failwith "wrong"

(* ── Do notation tests ───────────────────────────────── *)

let test_do_basic () =
  let src = {|
result =
  do
    x <- foo
    y <- bar x
    pure (x + y)
|} in
  match parse_one src with
  | DFunDef ("result", [], EDo [
      DoBind (PVar "x", EVar "foo");
      DoBind (PVar "y", EApp (EVar "bar", EVar "x"));
      DoExpr (EApp (EVar "pure", EBinOp ("+", EVar "x", EVar "y")));
    ]) -> ()
  | _ -> failwith "wrong"

(* ── Use declaration tests ───────────────────────────── *)

let test_use_simple () =
  match parse_one "use utils.greet\n" with
  | DUse (false, UseName ["utils"; "greet"]) -> ()
  | _ -> failwith "wrong"

let test_use_group () =
  match parse_one "use utils.{greet, helper}\n" with
  | DUse (false, UseGroup (["utils"], ["greet"; "helper"])) -> ()
  | _ -> failwith "wrong"

let test_use_pub () =
  match parse_one "pub use list.{map, filter}\n" with
  | DUse (true, UseGroup (["list"], ["map"; "filter"])) -> ()
  | _ -> failwith "wrong"

let test_use_alias () =
  match parse_one "use collections.HashMap as HM\n" with
  | DUse (false, UseAlias (["collections"; "HashMap"], "HM")) -> ()
  | _ -> failwith "wrong"

let test_use_wildcard () =
  match parse_one "use utils.*\n" with
  | DUse (false, UseWild ["utils"]) -> ()
  | _ -> failwith "wrong"

(* ── Multi-declaration tests ─────────────────────────── *)

(* ── Pipe and compose ────────────────────────────────── *)

let test_pipe () =
  match parse_expr "x |> f" with
  | EBinOp ("|>", EVar "x", EVar "f") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_pipe_chain () =
  (* left-associative: x |> f |> g  =  (x |> f) |> g *)
  match parse_expr "x |> f |> g" with
  | EBinOp ("|>", EBinOp ("|>", EVar "x", EVar "f"), EVar "g") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_compose_right () =
  match parse_expr "f >> g" with
  | EBinOp (">>", EVar "f", EVar "g") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_compose_left () =
  match parse_expr "f << g" with
  | EBinOp ("<<", EVar "f", EVar "g") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_pipe_lower_than_or () =
  (* x |> f  should not capture the `||` inside f — `||` binds tighter *)
  match parse_expr "a || b |> f" with
  | EBinOp ("|>", EBinOp ("||", EVar "a", EVar "b"), EVar "f") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_compose_lower_than_or () =
  match parse_expr "f >> a || b" with
  | EBinOp (">>", EVar "f", EBinOp ("||", EVar "a", EVar "b")) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_multi_decl () =
  let src = "x : Int\nx = 42\n" in
  match parse src with
  | [DTypeSig ("x", TyCon "Int"); DFunDef ("x", [], ELit (LInt 42))] -> ()
  | _ -> failwith "wrong"

let test_multi_clause () =
  let src = "factorial 0 = 1\nfactorial n = n * factorial n\n" in
  match parse src with
  | [DFunDef ("factorial", [PLit (LInt 0)], ELit (LInt 1));
     DFunDef ("factorial", [PVar "n"], _)] -> ()
  | _ -> failwith "wrong"

(* ── Extern declaration tests ───────────────────────── *)

let test_extern_simple () =
  match parse_one "extern foo : Int -> String\n" with
  | DExtern ("foo", TyFun (TyCon "Int", TyCon "String")) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_typevar () =
  match parse_one "extern id : a -> a\n" with
  | DExtern ("id", TyFun (TyVar "a", TyVar "a")) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_effect () =
  match parse_one "extern print : a -> <IO> Unit\n" with
  | DExtern ("print", TyFun (TyVar "a", TyEffect (["IO"], TyCon "Unit"))) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_constant () =
  match parse_one "extern pi : Float\n" with
  | DExtern ("pi", TyCon "Float") -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_multiarg () =
  match parse_one "extern set_ref : Ref a -> a -> <Mut> Unit\n" with
  | DExtern ("set_ref", TyFun (TyApp (TyCon "Ref", TyVar "a"),
                          TyFun (TyVar "a", TyEffect (["Mut"], TyCon "Unit")))) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

(* ── Test runner ─────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Medaka Parser" [
    "type signatures", [
      test_case "simple arrow"     `Quick test_typesig_simple;
      test_case "type variable"    `Quick test_typesig_typevar;
      test_case "effect"           `Quick test_typesig_effect;
      test_case "multi-effect"     `Quick test_typesig_multieffect;
      test_case "type application" `Quick test_typesig_typeapp;
    ];
    "function definitions", [
      test_case "constant"           `Quick test_fundef_simple;
      test_case "one argument"       `Quick test_fundef_with_arg;
      test_case "literal pattern"    `Quick test_fundef_pattern_lit;
      test_case "wildcard pattern"   `Quick test_fundef_wildcard;
      test_case "cons pattern"       `Quick test_fundef_cons_pattern;
      test_case "constructor pattern" `Quick test_fundef_constructor_pattern;
    ];
    "expressions", [
      test_case "lambda"            `Quick test_expr_lambda;
      test_case "lambda multi-arg"  `Quick test_expr_lambda_multi_arg;
      test_case "let"               `Quick test_expr_let;
      test_case "let mut"           `Quick test_expr_let_mut;
      test_case "let fn one arg"    `Quick test_expr_let_fn_one_arg;
      test_case "let fn multi arg"  `Quick test_expr_let_fn_multi_arg;
      test_case "if-then-else"      `Quick test_expr_if;
      test_case "application"       `Quick test_expr_application;
      test_case "infix backtick"    `Quick test_expr_infix_backtick;
      test_case "list literal"      `Quick test_expr_list_literal;
      test_case "array literal"     `Quick test_expr_array_literal;
      test_case "tuple"             `Quick test_expr_tuple;
      test_case "field access"      `Quick test_expr_field_access;
      test_case "record create"     `Quick test_expr_record_create;
      test_case "record update"     `Quick test_expr_record_update;
      test_case "type annotation"   `Quick test_expr_type_annot;
      test_case "array index"       `Quick test_expr_index;
    ];
    "match", [
      test_case "basic match"       `Quick test_match_basic;
      test_case "match with guard"  `Quick test_match_with_guard;
    ];
    "data types", [
      test_case "inline variants"     `Quick test_data_inline;
      test_case "parametric variant"  `Quick test_data_with_fields;
      test_case "block variants"      `Quick test_data_block;
    ];
    "records", [
      test_case "record declaration"  `Quick test_record_decl;
    ];
    "do notation", [
      test_case "basic do"  `Quick test_do_basic;
    ];
    "use declarations", [
      test_case "simple"    `Quick test_use_simple;
      test_case "group"     `Quick test_use_group;
      test_case "pub"       `Quick test_use_pub;
      test_case "alias"     `Quick test_use_alias;
      test_case "wildcard"  `Quick test_use_wildcard;
    ];
    "pipe and compose", [
      test_case "pipe"                  `Quick test_pipe;
      test_case "pipe chain"            `Quick test_pipe_chain;
      test_case "compose >>"           `Quick test_compose_right;
      test_case "compose <<"           `Quick test_compose_left;
      test_case "pipe lower than ||"    `Quick test_pipe_lower_than_or;
      test_case "compose lower than ||" `Quick test_compose_lower_than_or;
    ];
    "multiple declarations", [
      test_case "sig + def"       `Quick test_multi_decl;
      test_case "multi-clause fn" `Quick test_multi_clause;
    ];
    "extern declarations", [
      test_case "simple arrow"    `Quick test_extern_simple;
      test_case "type variable"   `Quick test_extern_typevar;
      test_case "effect"          `Quick test_extern_effect;
      test_case "constant"        `Quick test_extern_constant;
      test_case "multi-arg"       `Quick test_extern_multiarg;
    ];
  ]
