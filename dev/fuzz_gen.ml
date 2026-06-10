(* fuzz_gen.ml — type-directed generator for the Medaka differential fuzzer
   (Stage-0/1 MVP).

   Generates *well-typed-by-construction* Medaka programs by building typed
   terms top-down from a target type, never random token soup.  Output is a
   self-contained program whose `main` is a sequence of `println (debug e)`
   lines — a deterministic stdout transcript that the driver (test/fuzz_diff.sh)
   feeds through the OCaml oracle (Tier-A: oracle run + inline invariant checks)
   and the selfhost tree-walker (Tier-B: oracle-vs-selfhost stdout diff).

   Reuses lib/ast.ml + lib/printer.ml (program_to_string) — we emit an AST and
   pretty-print it, so the generated surface always parses.

   Determinism: an explicit SplitMix64 PRNG seeded by --seed N.  Each seed maps
   to exactly one program, fully replayable and portable across machines (unlike
   OCaml's Random, whose stream is implementation-defined).

   Tiers (cumulative, gated by --tier):
     0  scalars (Int/Float/Bool/String/Char) + arithmetic + if + let + mono fns
     1  + positional ADTs + tuples + exhaustive match
     2  + deriving (Eq,Ord,Debug) on the Tier-1 ADTs + comparison/equality ops

   NAMED-FIELD RECORDS are deliberately NOT generated for the Tier-B diff: the
   selfhost tree-walker's deriving generator builds a positional PCon pattern for
   a named-field `data` variant, which fails to match the VRecord value at eval
   time (non-exhaustive panic at selfhost/eval.mdk:1050).  See
   test/fuzz_allowlist.txt.  We stay inside positional ADTs so every Tier-B
   program is expected byte-identical.

   Usage:
     fuzz_gen.exe --seed N [--tier T] [--width W]
   prints the generated program to stdout.
*)

open Medaka_lib
open Ast

(* ── SplitMix64 ──────────────────────────────────────────────────────────── *)
(* 64-bit state in an int64 ref.  Same algorithm the project standardized on
   (see RNG = deterministic SplitMix64 memory): portable + seedable. *)
let state = ref 0L

let seed (s : int) = state := Int64.of_int s

let next64 () : int64 =
  let open Int64 in
  state := add !state 0x9E3779B97F4A7C15L;
  let z = !state in
  let z = mul (logxor z (shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = mul (logxor z (shift_right_logical z 27)) 0x94D049BB133111EBL in
  logxor z (shift_right_logical z 31)

(* uniform int in [0, n) for n > 0 *)
let rand_below (n : int) : int =
  if n <= 1 then 0
  else
    let r = Int64.logand (next64 ()) 0x3FFFFFFFFFFFFFFFL in (* mask to nonneg *)
    Int64.to_int (Int64.rem r (Int64.of_int n))

(* small int literal value in [0, 9].  We keep literals NON-NEGATIVE: a bare
   negative literal (e.g. `-8`) at an application-argument position prints
   without parens and the parser then reads `C "x" -8` as `(C "x") - 8`
   (subtraction).  Negative values still arise dynamically via arithmetic
   (`a - b`), which is well-parenthesized by precedence. *)
let rand_small_int () : int = rand_below 10
let pick (xs : 'a list) : 'a = List.nth xs (rand_below (List.length xs))
let chance (num : int) (den : int) : bool = rand_below den < num

(* ── target types we generate at ─────────────────────────────────────────── *)
type gty =
  | GInt
  | GFloat
  | GBool
  | GString
  | GChar
  | GTup of gty list        (* Tier 1 *)
  | GData of string         (* Tier 1: a generated ADT, by name *)

(* A generated ADT: positional variants only.  derives=true ⇒ Tier-2
   `deriving (Eq, Ord, Debug)`.  We always derive Debug (needed to print it). *)
type gadt = {
  tname : string;
  variants : (string * gty list) list;  (* constructor name, positional field types *)
  derives : bool;
}

(* ── generation context ──────────────────────────────────────────────────── *)
type ctx = {
  tier : int;
  mutable adts : gadt list;            (* declared ADTs *)
  mutable scope : (ident * gty) list;  (* in-scope value bindings with their type *)
  mutable fresh : int;
}

let fresh_name ctx prefix =
  let n = ctx.fresh in
  ctx.fresh <- n + 1;
  Printf.sprintf "%s%d" prefix n

(* base (scalar) types always available *)
let base_gtys = [GInt; GFloat; GBool; GString; GChar]

(* a random target type, biased toward scalars; ADTs/tuples only at higher tier *)
let rec rand_gty ctx depth : gty =
  if depth <= 0 then pick base_gtys
  else if ctx.tier >= 1 && ctx.adts <> [] && chance 1 4 then
    GData (pick ctx.adts).tname
  else if ctx.tier >= 1 && chance 1 6 then
    let k = 2 + rand_below 2 in
    GTup (List.init k (fun _ -> rand_gty ctx (depth - 1)))
  else pick base_gtys

(* ── leaf literals ───────────────────────────────────────────────────────── *)
let rand_char_lit () =
  let cs = ["a";"b";"c";"x";"y";"z";"A";"M";"0";"9";"!";" "] in
  LChar (pick cs)

let rand_string_lit () =
  let ws = [""; "ab"; "hello"; "x"; "Medaka"; "a b"; "12"; "::"] in
  LString (pick ws)

let lit_of ctx = function
  | GInt    -> ELit (LInt (rand_small_int ()))
  | GFloat  -> ELit (LFloat (float_of_int (rand_below 11) +. (float_of_int (rand_below 4) /. 4.0)))
  | GBool   -> ELit (LBool (chance 1 2))
  | GString -> ELit (rand_string_lit ())
  | GChar   -> ELit (rand_char_lit ())
  | GTup _ | GData _ -> ignore ctx; assert false

(* ── arithmetic / comparison operator sets ───────────────────────────────── *)
(* num arithmetic operators valid for both Int and Float *)
let num_arith_ops = ["+"; "-"; "*"]
(* operators only sane on Int (integer div/mod) *)
let int_only_ops  = ["/"; "%"]
(* equality applies to all comparable scalar types and (Tier-2) derived ADTs *)
let eq_ops = ["=="; "!="]
(* ordering likewise *)
let ord_ops = ["<"; ">"; "<="; ">="]

let lookup_in_scope ctx (t : gty) : ident option =
  let cands = List.filter (fun (_, t') -> t' = t) ctx.scope in
  if cands = [] then None else Some (fst (pick cands))

(* exhaustive set of constructors for a data name *)
let find_adt ctx name = List.find (fun a -> a.tname = name) ctx.adts

(* ── core: generate an expression of a given type ────────────────────────── *)
let rec gen_expr ctx (t : gty) depth : expr =
  (* small chance to reuse an in-scope binding of the right type *)
  match (if depth > 0 && chance 1 3 then lookup_in_scope ctx t else None) with
  | Some v -> EVar v
  | None ->
    if depth <= 0 then gen_leaf ctx t
    else
      match t with
      | GInt | GFloat -> gen_num ctx t depth
      | GBool -> gen_bool ctx depth
      | GString -> gen_string ctx depth
      | GChar -> gen_leaf ctx t
      | GTup ts -> ETuple (List.map (fun ti -> gen_expr ctx ti (depth - 1)) ts)
      | GData name -> gen_data ctx name depth

and gen_leaf ctx t =
  match t with
  | GTup ts -> ETuple (List.map (gen_leaf ctx) ts)
  | GData name -> gen_data ctx name 0
  | _ -> lit_of ctx t

(* numeric expression (Int or Float).  Mixes literals, arithmetic, if, let. *)
and gen_num ctx t depth : expr =
  let r = rand_below 10 in
  if r < 3 then lit_of ctx t
  else if r < 7 then begin
    (* arithmetic; int-only ops only for GInt, and guard against div/mod by 0 *)
    let ops = if t = GInt then num_arith_ops @ int_only_ops else num_arith_ops in
    let op = pick ops in
    let l = gen_expr ctx t (depth - 1) in
    let rhs =
      if op = "/" || op = "%" then
        (* nonzero divisor literal to keep evaluation total *)
        ELit (LInt (let v = rand_small_int () in if v = 0 then 1 else v))
      else gen_expr ctx t (depth - 1)
    in
    EBinOp (op, l, rhs, ref None)
  end
  else if r < 9 then
    EIf (gen_cond ctx (depth - 1),
         gen_expr ctx t (depth - 1),
         gen_expr ctx t (depth - 1))
  else
    gen_let ctx t depth

(* a boolean usable as an `if` condition: NEVER a bare EIf (the parser rejects
   `if if … then …`; the printer does not parenthesize an if in cond position).
   So conditions are comparisons / &&/|| / bool literals only. *)
and gen_cond ctx depth : expr =
  let r = rand_below 10 in
  if r < 3 || depth <= 0 then ELit (LBool (chance 1 2))
  else if r < 8 then gen_compare ctx (depth - 1)
  else EBinOp (pick ["&&"; "||"], gen_cond ctx (depth - 1), gen_cond ctx (depth - 1), ref None)

(* a comparison/equality expression with a well-typed operand pair *)
and gen_compare ctx depth : expr =
  (* choose operator category, then an operand type that supports it.
     Ord operands: Int/Float/String/Char (+ derived ADT).  Eq additionally
     allows Bool.  Bool has NO Ord impl — never compare it with </>/<=/>=. *)
  let want_ord = chance 1 2 in
  let derived = if ctx.tier >= 2 then List.filter (fun a -> a.derives) ctx.adts else [] in
  let ord_scalars = [GInt; GFloat; GString; GChar] in
  let optype =
    if derived <> [] && chance 1 3 then GData (pick derived).tname
    else if want_ord then pick ord_scalars
    else pick (GBool :: ord_scalars)
  in
  let op = if want_ord then pick ord_ops else pick eq_ops in
  EBinOp (op, gen_expr ctx optype depth, gen_expr ctx optype depth, ref None)

(* boolean expression (for general bool-typed values): comparisons, &&/||, if.
   Used where a full bool VALUE is wanted (an `if` here is fine — it's an operand,
   not a condition, and gets parenthesized by precedence). *)
and gen_bool ctx depth : expr =
  let r = rand_below 10 in
  if r < 2 then ELit (LBool (chance 1 2))
  else if r < 6 then gen_compare ctx (depth - 1)
  else if r < 8 then
    EBinOp (pick ["&&"; "||"], gen_bool ctx (depth - 1), gen_bool ctx (depth - 1), ref None)
  else
    EIf (gen_cond ctx (depth - 1), gen_bool ctx (depth - 1), gen_bool ctx (depth - 1))

and gen_string ctx depth : expr =
  if depth <= 0 || chance 1 2 then ELit (rand_string_lit ())
  else EBinOp ("++", gen_string ctx (depth - 1), gen_string ctx (depth - 1), ref None)

(* let x = e1 in e2  (single binding; x typed at a fresh scalar type) *)
and gen_let ctx t depth : expr =
  let bt = pick base_gtys in
  let name = fresh_name ctx "v" in
  let rhs = gen_expr ctx bt (depth - 1) in
  let saved = ctx.scope in
  ctx.scope <- (name, bt) :: ctx.scope;
  let body = gen_expr ctx t (depth - 1) in
  ctx.scope <- saved;
  ELet (false, false, PVar name, rhs, body)

(* construct an ADT value: pick a variant, fill positional fields *)
and gen_data ctx name depth : expr =
  let a = find_adt ctx name in
  let (con, ftys) = pick a.variants in
  List.fold_left
    (fun acc fty -> EApp (acc, gen_expr ctx fty (max 0 (depth - 1))))
    (EVar con) ftys

(* ── match: exhaustive arms over one ADT scrutinee, body of type t ───────── *)
let gen_match ctx (scrut_adt : gadt) (t : gty) depth : expr =
  let scrut = gen_data ctx scrut_adt.tname depth in
  let arms =
    List.map
      (fun (con, ftys) ->
        (* bind each field to a fresh var, make them available in the arm body *)
        let vars = List.map (fun fty -> (fresh_name ctx "p", fty)) ftys in
        let pat = PCon (con, List.map (fun (n, _) -> PVar n) vars) in
        let saved = ctx.scope in
        ctx.scope <- vars @ ctx.scope;
        let body = gen_expr ctx t (depth - 1) in
        ctx.scope <- saved;
        (pat, [], body))
      scrut_adt.variants
  in
  EMatch (scrut, arms)

(* ── ADT declarations ────────────────────────────────────────────────────── *)
let gen_adt_decl ctx : gadt =
  let tname = fresh_name ctx "T" in
  let nvariants = 1 + rand_below 3 in
  let derives = ctx.tier >= 2 in
  (* Field types must support every derived class.  Deriving Ord (Tier-2)
     requires each field's type to have an Ord impl — Bool has Eq but NO Ord
     (no `impl Ord Bool` in core.mdk), so a Bool field would make derived Ord
     fail to elaborate.  Restrict field types to Ord-able scalars when deriving. *)
  let field_tys = if derives then [GInt; GFloat; GString; GChar] else base_gtys in
  let variants =
    List.init nvariants (fun _ ->
      let cname = fresh_name ctx "C" in
      (* positional fields, scalar types only (keeps match/deriving simple) *)
      let nf = rand_below 3 in
      let ftys = List.init nf (fun _ -> pick field_tys) in
      (cname, ftys))
  in
  { tname; variants; derives }

let rec gty_to_ty = function
  | GInt -> TyCon "Int"
  | GFloat -> TyCon "Float"
  | GBool -> TyCon "Bool"
  | GString -> TyCon "String"
  | GChar -> TyCon "Char"
  | GTup ts -> TyTuple (List.map gty_to_ty ts)
  | GData n -> TyCon n

let adt_to_decl (a : gadt) : decl =
  let variants =
    List.map
      (fun (con, ftys) ->
        { con_name = con; con_payload = ConPos (List.map (fun g -> gty_to_ty g) ftys) })
      a.variants
  and derives = if a.derives then ["Eq"; "Ord"; "Debug"] else ["Debug"] in
  DData (DataPrivate, a.tname, [], variants, derives)

(* ── monomorphic helper function: f : A -> B ─────────────────────────────── *)
let gen_fun_decl ctx : (decl * (ident * gty)) =
  let pt = pick base_gtys and rt = pick base_gtys in
  let fname = fresh_name ctx "f" in
  let pname = fresh_name ctx "x" in
  let saved = ctx.scope in
  ctx.scope <- [(pname, pt)];      (* only the param is in scope inside the fn *)
  let body = gen_expr ctx rt 3 in
  ctx.scope <- saved;
  let sig_ty = TyFun (gty_to_ty pt, gty_to_ty rt) in
  let def = DFunDef (false, fname, [PVar pname], body) in
  (* return both decls (sig + def) flattened by caller *)
  ignore sig_ty;
  (def, (fname, pt))   (* we don't add the fn to value scope; calls handled separately *)

(* ── invariant assertions (Tier-A) ───────────────────────────────────────── *)
(* Each returns a Bool expr that MUST evaluate True for the values we built.
   The generator knows these hold by construction; a False ⇒ a real bug. *)

(* arithmetic identities over a fresh Int operand *)
let inv_arith ctx : expr list =
  let a = gen_expr ctx GInt 2 and b = gen_expr ctx GInt 2 in
  [ (* a + 0 == a *)
    EBinOp ("==", EBinOp ("+", a, ELit (LInt 0), ref None), a, ref None);
    (* a * 1 == a *)
    EBinOp ("==", EBinOp ("*", a, ELit (LInt 1), ref None), a, ref None);
    (* (a + b) - b == a *)
    EBinOp ("==",
            EBinOp ("-", EBinOp ("+", a, b, ref None), b, ref None),
            a, ref None);
  ]

(* Eq reflexivity + (a==b)==(eq a b) over a derived ADT operand *)
let inv_eq ctx (a : gadt) : expr list =
  let x = gen_data ctx a.tname 2 and y = gen_data ctx a.tname 2 in
  [ (* x == x  (reflexive) *)
    EBinOp ("==", x, x, ref None);
    (* (x == y) == (eq x y) : operator and method agree *)
    EBinOp ("==",
            EBinOp ("==", x, y, ref None),
            EApp (EApp (EVar "eq", x), y), ref None);
    (* symmetry: (x == y) == (y == x) *)
    EBinOp ("==",
            EBinOp ("==", x, y, ref None),
            EBinOp ("==", y, x, ref None), ref None);
  ]

(* Ord: (a<b)==(lt a b); antisymmetry not(a<b && b<a) over derived ADT *)
let inv_ord ctx (a : gadt) : expr list =
  let x = gen_data ctx a.tname 2 and y = gen_data ctx a.tname 2 in
  [ (* (x < y) == (lt x y) *)
    EBinOp ("==",
            EBinOp ("<", x, y, ref None),
            EApp (EApp (EVar "lt", x), y), ref None);
    (* antisymmetry: not (x < y && y < x) *)
    EUnOp ("not", EBinOp ("&&",
                          EBinOp ("<", x, y, ref None),
                          EBinOp ("<", y, x, ref None), ref None));
    (* totality on equal values: x <= x *)
    EBinOp ("<=", x, x, ref None);
  ]

(* Ord transitivity over a generated triple of Int (cheap, always meaningful) *)
let inv_ord_trans ctx : expr =
  let a = gen_expr ctx GInt 1 and b = gen_expr ctx GInt 1 and c = gen_expr ctx GInt 1 in
  (* (a<=b && b<=c) => a<=c   encoded as  not(a<=b && b<=c) || a<=c *)
  EBinOp ("||",
          EUnOp ("not", EBinOp ("&&",
                                EBinOp ("<=", a, b, ref None),
                                EBinOp ("<=", b, c, ref None), ref None)),
          EBinOp ("<=", a, c, ref None), ref None)

(* ── program assembly ────────────────────────────────────────────────────── *)
(* A println(debug e) statement *)
let print_stmt (e : expr) : do_stmt =
  DoExpr (EApp (EVar "println", EApp (EVar "debug", e)))

(* Generate one independent "block": its decls (ADTs, fns, vals, hoisted output
   bindings) plus the main-body statements that print them.  Shares `ctx` (and
   thus the global fresh-name counter) with sibling blocks so names never collide
   when many blocks are concatenated into one file — that is how we BATCH many
   generated programs into a single selfhost process, amortizing the ~480ms
   runtime+core parse tax over all of them.  Each block resets ctx.adts/scope so
   blocks are semantically independent. *)
let gen_block ctx : decl list * do_stmt list =
  ctx.adts <- [];
  ctx.scope <- [];
  (* 1. declare a few ADTs (Tier >= 1) *)
  let n_adts = if ctx.tier >= 1 then 1 + rand_below 2 else 0 in
  for _ = 1 to n_adts do
    let a = gen_adt_decl ctx in
    ctx.adts <- ctx.adts @ [a]
  done;
  let adt_decls = List.map adt_to_decl ctx.adts in

  (* 2. a couple of monomorphic helper fns (Tier >= 0) *)
  let n_fns = rand_below 3 in
  let fn_decls = List.init n_fns (fun _ -> fst (gen_fun_decl ctx)) in

  (* 3. some top-level value bindings to populate scope for reuse *)
  let n_vals = 2 + rand_below 3 in
  let val_decls =
    List.init n_vals (fun _ ->
      let t = rand_gty ctx 1 in
      let name = fresh_name ctx "g" in
      let e = gen_expr ctx t 3 in
      ctx.scope <- (name, t) :: ctx.scope;
      DFunDef (false, name, [], e))
  in

  (* 4. printed expressions.  To dodge the parser's inline-match / line-
     continuation layout limits, every printed expression is HOISTED into its
     own top-level binding `oN = <expr>`; main just prints `debug oN`.  A
     top-level binding RHS accepts a full expression (incl. match) with
     well-behaved layout and no wrapping. *)
  let outs = ref [] in     (* (name, decl, is_inv) for hoisted exprs, in order *)
  let hoist0 is_inv e =
    let name = fresh_name ctx "o" in
    outs := !outs @ [(name, DFunDef (false, name, [], e), is_inv)]
  in
  let hoist e = hoist0 false e in        (* ordinary printed expr *)
  let hoist_inv e = hoist0 true e in     (* Tier-A invariant: must be True *)

  (* general printed expressions *)
  for _ = 1 to 4 do
    let t = rand_gty ctx 2 in
    hoist (gen_expr ctx t 3)
  done;

  (* match expressions (Tier >= 1) over each ADT *)
  if ctx.tier >= 1 then
    List.iter
      (fun a ->
        let rt = pick base_gtys in
        hoist (gen_match ctx a rt 3))
      ctx.adts;

  (* Tier-A invariants — always present, deterministic, must print "INV True" *)
  List.iter hoist_inv (inv_arith ctx);
  hoist_inv (inv_ord_trans ctx);

  (* Tier-2 Eq/Ord invariants over each derived ADT *)
  if ctx.tier >= 2 then
    List.iter
      (fun a ->
        if a.derives then begin
          List.iter hoist_inv (inv_eq ctx a);
          List.iter hoist_inv (inv_ord ctx a)
        end)
      ctx.adts;

  (* main: ordinary outputs print `debug oN`; invariants print `"INV " ++ debug oN`
     so the driver can isolate them — a `False` from a *random* comparison is not
     an invariant violation, but `INV False` always is. *)
  let body =
    List.map
      (fun (name, _, is_inv) ->
        if is_inv then
          DoExpr (EApp (EVar "println",
                        EBinOp ("++", ELit (LString "INV "),
                                EApp (EVar "debug", EVar name), ref None)))
        else print_stmt (EVar name))
      !outs
  in
  let out_decls = List.map (fun (_, d, _) -> d) !outs in
  (adt_decls @ fn_decls @ val_decls @ out_decls, body)

(* Assemble a full program from K independent blocks, sharing one ctx so names
   stay unique.  One combined `main` runs every block's statements in order,
   with a `println ""` separator block boundary marker between blocks so the
   driver can split the transcript per-block if needed. *)
let gen_program ctx (nblocks : int) : program =
  let all_decls = ref [] and all_body = ref [] in
  for i = 1 to nblocks do
    let (decls, body) = gen_block ctx in
    all_decls := !all_decls @ decls;
    (* separate blocks in the transcript with a marker line *)
    let sep = if i > 1 then [DoExpr (EApp (EVar "println", ELit (LString "--BLOCK--")))] else [] in
    all_body := !all_body @ sep @ body
  done;
  let main_decl = DFunDef (false, "main", [], EBlock !all_body) in
  !all_decls @ [main_decl]

(* ── CLI ─────────────────────────────────────────────────────────────────── *)
let () =
  let seed_val = ref 0 and tier = ref 2 and width = ref 200 and batch = ref 1 in
  let spec = [
    ("--seed", Arg.Set_int seed_val, "PRNG seed (int)");
    ("--tier", Arg.Set_int tier, "tier 0|1|2 (default 2)");
    ("--width", Arg.Set_int width, "printer width (default 200 — keeps lines unwrapped)");
    ("--batch", Arg.Set_int batch, "number of independent blocks in one program (default 1); blocks share a fresh-name counter so a single selfhost process amortizes the prelude parse over all of them");
  ] in
  Arg.parse spec (fun _ -> ()) "fuzz_gen --seed N [--tier T] [--width W] [--batch K]";
  seed !seed_val;
  let ctx = { tier = !tier; adts = []; scope = []; fresh = 0 } in
  let prog = gen_program ctx (max 1 !batch) in
  print_string (Printer.program_to_string ~width:!width prog)
