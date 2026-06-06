(* Round-trip tests: parse source → pretty-print → parse again → check ASTs match.
   The printed source need not be byte-identical to the original; what matters
   is that re-parsing yields the same AST. *)

open Medaka_lib

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with
  | Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                pos.Lexing.pos_lnum
                (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                src)

let roundtrip src =
  let ast1 = parse src in
  let printed = Printer.program_to_string ast1 in
  let ast2 =
    try parse printed
    with Failure msg ->
      failwith (Printf.sprintf
        "Re-parse of printed output failed: %s\n\nOriginal:\n%s\nPrinted:\n%s"
        msg src printed)
  in
  let ast1' = Ast.strip_locs_program ast1 in
  let ast2' = Ast.strip_locs_program ast2 in
  if ast1' <> ast2' then
    failwith (Printf.sprintf
      "AST mismatch on round-trip.\n\nOriginal source:\n%s\nPrinted:\n%s\n\
       AST1 has %d decls, AST2 has %d decls."
      src printed (List.length ast1) (List.length ast2))

(* ── Test cases ──────────────────────────────────── *)

let mk src () = roundtrip src

(* Type signatures *)
let ts_simple    = mk "add : Int -> Int -> Int\n"
let ts_typevar   = mk "id : a -> a\n"
let ts_effect    = mk "readFile : String -> <IO> String\n"
let ts_multieff  = mk "fetch : String -> <Async, IO> String\n"
let ts_effvar    = mk "applyTo : (a -> <e> b) -> a -> b\n"
let ts_effrow    = mk "run : (Unit -> <IO | e> a) -> <IO | e> a\n"
let ts_typeapp   = mk "head : List a -> Option a\n"
let ts_nested    = mk "foo : List (Option a) -> Option (List a)\n"
let ts_funarg    = mk "apply : (a -> b) -> a -> b\n"
let ts_tuple     = mk "swap : (a, b) -> (b, a)\n"

(* Function definitions *)
let fd_const     = mk "answer = 42\n"
let fd_one_arg   = mk "double x = x + x\n"
let fd_pat_lit   = mk "factorial 0 = 1\n"
let fd_wildcard  = mk "const x _ = x\n"
let fd_cons_pat  = mk "head (x::_) = x\n"
let fd_con_pat   = mk "unwrap (Some x) = x\n"

(* Expressions in fn bodies *)
let ex_lambda       = mk "f = x => x + 1\n"
(* Operator sections are preserved as ESection nodes, so the original surface
   syntax round-trips (rather than being printed as the desugared lambda). *)
let ex_right_section = mk "f = (+ 1)\n"
let ex_left_section  = mk "f = (2 * _)\n"
let ex_left_sec_app  = mk "f = (foo 1 * _)\n"
let ex_bare_section  = mk "f = (+)\n"
let ex_bare_sec_cons = mk "f = (::)\n"
let ex_section_arg   = mk "g = map (> 2) xs\n"
let ex_lam_tup   = mk "add = (x, y) => x + y\n"
let ex_let       = mk "f = let x = 5 in x + 1\n"
let ex_let_mut   = mk "f = let mut x = 5 in x\n"
let ex_let_fn    = mk "f = let g x = x + 1 in g 5\n"
let ex_let_fn_m  = mk "f = let g x y = x + y in g 1 2\n"
let ex_if        = mk "abs x = if x > 0 then x else -x\n"
let ex_app       = mk "v = f x y\n"
let ex_infix     = mk "v = x `div` y\n"
let ex_list      = mk "xs = [1, 2, 3]\n"
let ex_array     = mk "xs = [|1, 2, 3|]\n"
let ex_tuple     = mk "p = (1, \"hello\")\n"
let ex_field     = mk "name = person.name\n"
let ex_rec_new   = mk "alice = Person { name = \"Alice\", age = 30 }\n"
let ex_rec_upd   = mk "older p = { p | age = 31 }\n"
let ex_index     = mk "first arr = arr[0]\n"
let ex_annot     = mk "x = (5 : Int)\n"
let ex_nested    = mk "compute x y = (x + y) * (x - y)\n"
let ex_neg       = mk "neg x = -x\n"

(* Match expressions *)
let m_basic = mk
{|f x =
  match x
    0 => "zero"
    _ => "nonzero"
|}

let m_guard = mk
{|sign x =
  match x
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
|}

(* Function-clause guards (EGuards): round-trip as guard arms, not the
   desugared if/else chain. *)
let g_fun = mk
{|classify n
  | n < 0 = "neg"
  | n == 0 = "zero"
  | otherwise = "pos"
|}

(* Pattern-bind guard qualifier. *)
let g_bind = mk
{|f o
  | Some y <- o = y
  | otherwise = 0
|}

(* Guards inside a where binding (the stdlib count/find shape). *)
let g_where = mk
{|count f = fold g 0 where
    g acc x
      | f x = acc + 1
      | otherwise = acc
|}

(* A `where` clause scoping over all guard arms (Haskell-style, on its own
   indented line under the guards). *)
let g_where_over_guards = mk
{|f x
  | x > 0 = g x
  | otherwise = 0
  where
    g y = y + 1
|}

(* `function` keyword with guarded arms. *)
let fn_guard = mk
{|sign =
  function
    n if n > 0 => 1
    _ => 0
|}

let m_constructor = mk
{|extract opt =
  match opt
    Some x => x
    None => 0
|}

let m_as_cons = mk
{|f xs =
  match xs
    ys@(x::_) => x
    _ => 0
|}

let m_as_list = mk
{|f xs =
  match xs
    ys@[] => 0
    ys@(x::_) => x
|}

(* Data types *)
let d_inline     = mk "data Bool = True | False\n"
let d_param      = mk "data Option a = Some a | None\n"
let d_block      = mk
{|data Shape
  = Circle Float
  | Rectangle Float Float
|}

(* Records *)
let r_simple = mk
{|record Person
  name : String
  age : Int
|}

(* Do notation *)
let do_basic = mk
{|result =
  do
    x <- foo
    y <- bar x
    pure (x + y)
|}

let do_with_let = mk
{|main =
  do
    let x = 5
    y <- compute x
    pure y
|}

(* Phase 81: as-pattern binds and a lambda as-pattern param must round-trip.
   The formatter prints PAs sub-patterns parenthesised, so the re-parse takes
   the AS_AT path and yields the same AST. *)
let do_aspat_bind = mk
{|result =
  do
    all@(x::xs) <- foo
    p@(a, b) <- bar
    pure all
|}

let lam_aspat = mk "f = xs@rest => xs\n"

let lc_aspat = mk "f opts = [y | p@(Some y) <- opts]\n"

(* Import/export declarations *)
let u_simple  = mk "import utils.greet\n"
let u_group   = mk "import utils.{greet, helper}\n"
let u_ctors   = mk "import colors.{Color(..)}\n"
let u_mixed   = mk "import m.{f, T(..), g}\n"
let u_pub     = mk "export import list.{map, filter}\n"
let u_alias   = mk "import collections.HashMap as HM\n"
let u_wild    = mk "import utils.*\n"

(* Regression: a braced import `import m.{...}` must leave the lexer's
   paren-depth balanced.  Its `.{` lexes to DOT_LBRACE and its `}` to RBRACE
   (which decrements paren_depth), so if `.{` failed to increment, paren_depth
   would go negative and a *later* multi-line bracketed group would have its
   layout NEWLINE tokens leak in, failing to parse.  See lexer.mll `.{` rule.
   Repro distilled from `medaka fmt stdlib/array.mdk` (unzip). *)
let u_then_multiline_tuple = mk
{|import core.{Eq, Ord}

unzip arr =
  (
    fst arr,
    snd arr
  )
|}
let u_then_multiline_list = mk
{|import core.{Eq}

xs =
  [
    aaa,
    bbb
  ]
|}

(* Multiple declarations *)
let multi = mk
{|x : Int
x = 42

factorial : Int -> Int
factorial 0 = 1
factorial n = n * factorial (n - 1)
|}

(* Interface and impl (not covered by test_parser but valid in grammar) *)
let iface_basic = mk
{|interface Eq a where
  eq : a -> a -> Bool
|}

let impl_basic = mk
{|impl Eq Int where
  eq x y = x == y
|}

(* Phase 57: let rec *)
let lr_top_single = mk
  "let rec fact = n => if n == 0 then 1 else n * fact (n - 1)\n"

let lr_top_mutual = mk
  "let rec is_even = n => if n == 0 then True else is_odd (n - 1)\n\
   with is_odd = n => if n == 0 then False else is_even (n - 1)\n"

let lr_inline = mk
  "r = let rec fact = n => if n == 0 then 1 else n * fact (n - 1) in fact 5\n"

(* ── Test runner ─────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Medaka Round-Trip" [
    "type signatures", [
      test_case "simple"          `Quick ts_simple;
      test_case "type var"        `Quick ts_typevar;
      test_case "effect"          `Quick ts_effect;
      test_case "multi-effect"    `Quick ts_multieff;
      test_case "effect var"      `Quick ts_effvar;
      test_case "effect row"      `Quick ts_effrow;
      test_case "type app"        `Quick ts_typeapp;
      test_case "nested app"      `Quick ts_nested;
      test_case "function arg"    `Quick ts_funarg;
      test_case "tuple"           `Quick ts_tuple;
    ];
    "function definitions", [
      test_case "constant"         `Quick fd_const;
      test_case "one arg"          `Quick fd_one_arg;
      test_case "literal pat"      `Quick fd_pat_lit;
      test_case "wildcard"         `Quick fd_wildcard;
      test_case "cons pat"         `Quick fd_cons_pat;
      test_case "constructor pat"  `Quick fd_con_pat;
    ];
    "expressions", [
      test_case "lambda"           `Quick ex_lambda;
      test_case "right section"    `Quick ex_right_section;
      test_case "left section"     `Quick ex_left_section;
      test_case "left section app" `Quick ex_left_sec_app;
      test_case "bare section"     `Quick ex_bare_section;
      test_case "bare section cons" `Quick ex_bare_sec_cons;
      test_case "section as arg"   `Quick ex_section_arg;
      test_case "lambda tuple"     `Quick ex_lam_tup;
      test_case "lambda as-pat"    `Quick lam_aspat;
      test_case "let"              `Quick ex_let;
      test_case "let mut"          `Quick ex_let_mut;
      test_case "let fn"           `Quick ex_let_fn;
      test_case "let fn multi"     `Quick ex_let_fn_m;
      test_case "if-then-else"     `Quick ex_if;
      test_case "application"      `Quick ex_app;
      test_case "infix backtick"   `Quick ex_infix;
      test_case "list"             `Quick ex_list;
      test_case "array"            `Quick ex_array;
      test_case "tuple"            `Quick ex_tuple;
      test_case "field access"     `Quick ex_field;
      test_case "record create"    `Quick ex_rec_new;
      test_case "record update"    `Quick ex_rec_upd;
      test_case "index"            `Quick ex_index;
      test_case "type annot"       `Quick ex_annot;
      test_case "nested binops"    `Quick ex_nested;
      test_case "negate"           `Quick ex_neg;
    ];
    "match", [
      test_case "basic"            `Quick m_basic;
      test_case "with guard"       `Quick m_guard;
      test_case "constructor arms" `Quick m_constructor;
      test_case "as-pattern cons"  `Quick m_as_cons;
      test_case "as-pattern list"  `Quick m_as_list;
    ];
    "guards", [
      test_case "function clause"  `Quick g_fun;
      test_case "pattern bind"     `Quick g_bind;
      test_case "in where"         `Quick g_where;
      test_case "where over guards" `Quick g_where_over_guards;
      test_case "function keyword" `Quick fn_guard;
    ];
    "data types", [
      test_case "inline"           `Quick d_inline;
      test_case "parametric"       `Quick d_param;
      test_case "block"            `Quick d_block;
    ];
    "records", [
      test_case "simple"           `Quick r_simple;
    ];
    "do notation", [
      test_case "basic"            `Quick do_basic;
      test_case "with let"         `Quick do_with_let;
      test_case "as-pattern bind"  `Quick do_aspat_bind;
    ];
    "import/export", [
      test_case "simple"           `Quick u_simple;
      test_case "group"            `Quick u_group;
      test_case "group ctors T(..)" `Quick u_ctors;
      test_case "group mixed"      `Quick u_mixed;
      test_case "export import"    `Quick u_pub;
      test_case "alias"            `Quick u_alias;
      test_case "wildcard"         `Quick u_wild;
      test_case "braced import then multiline tuple" `Quick u_then_multiline_tuple;
      test_case "braced import then multiline list"  `Quick u_then_multiline_list;
      test_case "export data abstract"  `Quick (mk "export data Color = Red | Green | Blue\n");
      test_case "public export data"    `Quick (mk "public export data Color = Red | Green | Blue\n");
      test_case "private data"          `Quick (mk "data Color = Red | Green | Blue\n");
      test_case "public export record"  `Quick (mk "public export record Point\n  x : Int\n  y : Int\n");
      test_case "export record abstract" `Quick (mk "export record Point\n  x : Int\n  y : Int\n");
      test_case "effect decl"           `Quick (mk "effect KV\n");
      test_case "export effect decl"    `Quick (mk "export effect Fetch\n");
    ];
    "multi-decl", [
      test_case "mixed"            `Quick multi;
    ];
    "let rec (Phase 57)", [
      test_case "top single"       `Quick lr_top_single;
      test_case "top mutual"       `Quick lr_top_mutual;
      test_case "inline"           `Quick lr_inline;
    ];
    "interface/impl", [
      test_case "interface basic"  `Quick iface_basic;
      test_case "impl basic"       `Quick impl_basic;
    ];
    "extern", [
      test_case "constant"         `Quick (mk "extern pi : Float\n");
      test_case "simple arrow"     `Quick (mk "extern foo : Int -> String\n");
      test_case "with effect"      `Quick (mk "extern print : a -> <IO> Unit\n");
      test_case "multi-arg effect" `Quick (mk "extern set_ref : Ref a -> a -> <Mut> Unit\n");
    ];
    "collection literals", [
      test_case "map literal"  `Quick (mk "m = Map { \"a\" => 1, \"b\" => 2 }\n");
      test_case "set literal"  `Quick (mk "s = Set { 1, 2, 3 }\n");
      test_case "hashmap"      `Quick (mk "m = HashMap { \"x\" => True }\n");
    ];
    "constraint type signatures", [
      test_case "single constraint"    `Quick (mk "neq : Eq a => a -> a -> Bool\n");
      test_case "multi constraint"     `Quick (mk "f : (Eq a, Ord b) => a -> b -> Bool\n");
    ];
    "type aliases", [
      test_case "simple"      `Quick (mk "type Name = String\n");
      test_case "parametric"  `Quick (mk "type Wrapper a = Option a\n");
      test_case "function"    `Quick (mk "type Parser a = String -> Option a\n");
      test_case "export"      `Quick (mk "export type Name = String\n");
    ];
    "newtype declarations", [
      test_case "simple"      `Quick (mk "newtype UserId = UserId Int\n");
      test_case "parametric"  `Quick (mk "newtype Wrapper a = Wrap a\n");
      test_case "export"      `Quick (mk "export newtype UserId = UserId Int\n");
      test_case "deriving"    `Quick (mk "newtype Age = Age Int deriving (Eq)\n");
    ];
    "numeric literal extensions", [
      test_case "hex"              `Quick (mk "x = 0xFF\n");
      test_case "binary"           `Quick (mk "x = 0b1010\n");
      test_case "octal"            `Quick (mk "x = 0o17\n");
      test_case "int underscores"  `Quick (mk "x = 1_000_000\n");
    ];
    "string interpolation", [
      test_case "single hole"   `Quick (mk "x = \"hello \\{name}!\"\n");
      test_case "two holes"     `Quick (mk "x = \"\\{a} and \\{b}\"\n");
    ];
    "list comprehensions", [
      test_case "guard"      `Quick (mk "r = [x * 2 | x <- xs, x > 0]\n");
      test_case "multi gen"  `Quick (mk "r = [(x, y) | x <- xs, y <- ys]\n");
      test_case "let"        `Quick (mk "r = [y | x <- xs, let y = x * x, y > 2]\n");
      test_case "as-pat gen"  `Quick lc_aspat;
    ];
    "local let-rec (Phase 27)", [
      test_case "fun-def form"  `Quick (mk "r = let f x = x + 1 in f 5\n");
      test_case "multi-arg"     `Quick (mk "r = let g x y = x + y in g 1 2\n");
      test_case "value form unchanged" `Quick (mk "r = let x = 5 in x + 1\n");
    ];
    "record patterns", [
      test_case "pun"          `Quick (mk "f p =\n  match p\n    Person { name } => name\n");
      test_case "explicit"     `Quick (mk "f p =\n  match p\n    Person { age = 30 } => age\n");
      test_case "rest only"    `Quick (mk "f p =\n  match p\n    Person { ... } => 0\n");
      test_case "field + rest" `Quick (mk "f p =\n  match p\n    Person { name, ... } => name\n");
    ];
    "interface default where", [
      test_case "where in default body" `Quick
        (mk "interface Greeter a where\n  greet x = prefix ++ x where\n    prefix = \"Hi \"\n");
    ];
    "if let / let else (Phase 38)", [
      test_case "if let desugars to match" `Quick
        (mk "f opt =\n  if let Some x = opt then x else 0\n");
      test_case "let else in do-block" `Quick
        (mk "f opt =\n  do\n    let Some x = opt else pure 0\n    pure x\n");
    ];
    "if/else block branches (Phase 45.7 / 118)", [
      test_case "block then, block else" `Quick
        (mk "f x =\n  if x > 0 then\n    let a = 1\n    a\n  else\n    let b = 2\n    b\n");
      test_case "block then, inline else" `Quick
        (mk "f x =\n  if x > 0 then\n    let a = 1\n    a\n  else 2\n");
      test_case "inline then, block else" `Quick
        (mk "f x =\n  if x > 0 then 1\n  else\n    let b = 2\n    b\n");
      test_case "inline if/else unchanged" `Quick
        (mk "f x = if x > 0 then 1 else 2\n");
      (* Phase 122: else-less `if` (else defaults to `()`); in statement
         position the formatter drops the synthetic `else ()`. *)
      test_case "else-less inline (stmt)" `Quick
        (mk "g x =\n  if x > 0 then f x\n  done x\n");
      test_case "else-less block (stmt)" `Quick
        (mk "g x =\n  if x > 0 then\n    a x\n    b x\n  done x\n");
    ];
    "range literals (Phase 40)", [
      test_case "list half-open"      `Quick (mk "r = [1..10]\n");
      test_case "list inclusive"      `Quick (mk "r = [1..=10]\n");
      test_case "array half-open"     `Quick (mk "r = [|0..5|]\n");
      test_case "array inclusive"     `Quick (mk "r = [|1..=100|]\n");
      test_case "slice half-open"     `Quick (mk "r arr = arr.[2..5]\n");
      test_case "slice inclusive"     `Quick (mk "r arr = arr.[0..=3]\n");
      test_case "range pattern int"   `Quick
        (mk "f n =\n  match n\n    1..9 => True\n    _ => False\n");
      test_case "range pattern char"  `Quick
        (mk "f c =\n  match c\n    'a'..='z' => True\n    _ => False\n");
    ];
    "function keyword (Phase 44)", [
      test_case "basic arms" `Quick
        (mk "classify =\n  function\n    0 => \"zero\"\n    _ => \"nonzero\"\n");
    ];
    "test declarations (Phase 127)", [
      test_case "simple body"   `Quick (mk "test \"always passes\" = pass\n");
      test_case "expr body"     `Quick (mk "test \"check add\" = expectEqual (1 + 1) 2\n");
      test_case "export"        `Quick (mk "export test \"pub test\" = pass\n");
    ];
    "bench declarations (Phase 48)", [
      test_case "simple literal"  `Quick (mk "bench \"identity\" = 42\n");
      test_case "expr body"       `Quick (mk "bench \"add\" = 1 + 2\n");
    ];
    "declaration attributes (Phase 49)", [
      test_case "@deprecated round-trips" `Quick
        (mk "@deprecated \"use bar\"\nfoo x = x\n");
      test_case "@inline round-trips" `Quick
        (mk "@inline\nfoo x = x\n");
      test_case "@must_use round-trips" `Quick
        (mk "@must_use\nextern foo : Int -> Int\n");
    ];
  ]
