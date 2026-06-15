open Ast

(* String-keyed hashtable for environment frames.  Using Hashtbl.Make(String)
   with String.equal keeps key comparison on the direct specialized path instead
   of the polymorphic caml_equal → compare_val → memcmp the default Hashtbl uses
   (which showed up in env-lookup profiles). *)
module FrameTbl = Hashtbl.Make (struct
  type t = string
  let equal = String.equal
  let hash = Hashtbl.hash
end)

(* ── Value type ──────────────────────────────────────────────────────────── *)

type value =
  | VInt    of int
  | VFloat  of float
  | VString of string
  | VChar   of string
  | VBool   of bool
  | VUnit
  | VTuple  of value list
  | VList   of value list
  | VArray  of value array
  | VCon    of string * value list
  | VRecord of string * (string * value) list
                                  (* type_name, fields.  The type name is
                                     used by runtime_type_tag so that VMulti
                                     dispatch on a method like `debug` can
                                     route through to the right impl when
                                     multiple candidates exist. *)
  | VRef    of value ref
  | VClosure of env * pat list * expr
  | VPrim   of (value -> value)
  | VMulti  of value list  (* ordered impl closures for the same method; tried in sequence *)
  | VThunk  of value Lazy.t  (* deferred top-level zero-param binding; forced on first lookup *)
  | VNamedImpl of string * value  (* impl closure tagged with its declared name *)
  | VTypedImpl of string * string * int list * int * value
      (* impl method: (tag, key, dispatch_positions, args_seen, inner).
         `tag`  is the impl's head type-ctor name (e.g. "List" for Foldable List).
         `key`  is the canonical Ast.impl_key for this impl (iface + full type
            args + opt name).  Unlike `tag`, it distinguishes impls that share a
            head ctor — `Convert Int String` vs `Convert Int Bool` — so Phase 69
            return-position / multi-param dispatch can pick the impl the
            typechecker resolved, recorded in the call site's EMethodRef.
         `dispatch_positions` is the set of argument indices whose runtime type
            actually determines impl selection, computed from the interface
            method's type signature.  For `fold : (b -> a -> b) -> b -> t a -> b`
            of `Foldable t`, only position 2 mentions `t`, so positions = [2].
         `args_seen` is the number of args already applied to this impl method.
            VMulti's tag-filter only fires when `args_seen ∈ dispatch_positions`;
            other arg slots (like fold's accumulator) pass through untouched.
            An empty `dispatch_positions` (e.g. `pure : a -> f a`) means no
            positional dispatch is possible from arguments alone. *)
  | VDict   of string * value list
      (* Phase 69.x: a runtime dictionary — the canonical impl key of the
         constraint it satisfies, plus (Phase 83/84 #5) the *structured* element
         dicts for that impl's own `requires`, one per constraint in slot order
         (each itself a VDict / VDictHead).  Passed as a leading argument to
         constrained functions (EDictApp builds it, dict_pass binds it as a
         parameter); an EMethodRef stamped `RDict d` reads `d`'s VDict, narrows
         its method VMulti by the key via select_impl_by_key, then forwards the
         carried `requires` dicts into the selected impl's body — so a recursive
         instance (`def : List (List Int)`) unfolds level by level.  An empty key
         means "unresolved" — narrowing finds nothing and dispatch falls back to
         arg-tag, as it did before 69.x. *)
  | VDictHead of string * value list
      (* Phase 83/84 (#4): a head-key dictionary — carries the discriminating
         *head tycon* (e.g. "Result") plus, for uniformity with VDict, its
         impl's `requires` dicts (`[]` in the head-concrete free-args case it was
         introduced for).  Built from a RHeadKey dict-application route; read via
         RDict, it narrows the method VMulti by head tag (select_impl_by_head)
         rather than by full impl key. *)

and env = frame list
and frame =
  (* A frame is one lexical scope.  Tiny per-call frames (function params, let
     bindings) stay as association lists — building a Hashtbl for 1-3 entries is
     net-negative.  The large persistent frames (the global/prelude frame, a
     module's local+import frames) are Hashtbls so every global-name lookup is
     O(1) instead of a linear string-compare scan — that scan was ~87% of
     interpreter time on the self-hosted compiler (sample-profiled 2026-06-04). *)
  | FList  of (string * value ref) list
  | FTable of value ref FrameTbl.t

exception Eval_error of string * loc option
(* Raised instead of Eval_error when a pattern/match fails during dispatch so
   that VMulti.apply can silently fall through to the next impl candidate. *)
exception Impl_no_match

let output_hook : (string -> unit) ref = ref print_string

(* stderr sink, mirroring `output_hook` for stdout — lets tests capture stderr
   and keeps `ePutStr`/`ePutStrLn` (the `io` module) distinct from stdout. *)
let error_hook : (string -> unit) ref = ref (fun s -> output_string stderr s; flush stderr)

(* Program arguments for the `args` extern (io Module 7): the tokens passed to a
   Medaka program after the script name (`medaka run script.mdk a b c` →
   ["a"; "b"; "c"]). Set by bin/main.ml's run driver; empty everywhere else. *)
let program_args : string list ref = ref []

(* Deterministic RNG state — SplitMix64.  The SAME algorithm runs in the native
   runtime (runtime/medaka_rt.c mdk_next_u64), seeded identically, so random*
   output is byte-identical per seed and cross-backend stable (project decision
   2026-06-07: reproducible property tests + WasmGC-portable streams).  State is a
   uint64 held in an Int64; default 0; setSeed sets it.  Use ONLY unsigned 64-bit
   ops so OCaml and C agree. *)
let rng_state : int64 ref = ref 0L

let splitmix64_next () : int64 =
  rng_state := Int64.add !rng_state 0x9E3779B97F4A7C15L;
  let z = !rng_state in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 27)) 0x94D049BB133111EBL in
  Int64.logxor z (Int64.shift_right_logical z 31)

(* ── Hashable per-type hashers (specified hash, replacing structural __hashRaw) ─
   The old `__hashRaw = Hashtbl.hash` content-hashed any value, but the native
   backend is type-erased — one i64 word can't tell a tagged Int from a String
   pointer, so it can't content-hash boxed values.  Fix (the RNG playbook): each
   primitive `Hashable` impl calls a typed hasher specified IDENTICALLY here and
   in runtime/medaka_rt.c (the mdk_hash_ helpers), so the hash is byte-identical
   across the tree-walker oracle and native.  All math is unsigned 64-bit (Int64) so OCaml's
   63-bit int can't diverge from C uint64 on overflow; every result is masked to
   [0, 2^30) — NON-NEGATIVE (hash_map does `hash % cap`; a negative hash breaks
   bucketing), matching the old Hashtbl.hash range. *)
let hash_mask = 0x3FFFFFFFL   (* 2^30 - 1 *)

(* SplitMix64 finalizer reused as a pure avalanche mixer.  == mdk_hash_mix64 (C). *)
let hash_mix64 (x : int64) : int64 =
  let z = Int64.add x 0x9E3779B97F4A7C15L in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 27)) 0x94D049BB133111EBL in
  Int64.logxor z (Int64.shift_right_logical z 31)

(* hashInt: mix the int bits, mask.  == mdk_hash_int (C). *)
let hash_int (n : int) : int =
  Int64.to_int (Int64.logand (hash_mix64 (Int64.of_int n)) hash_mask)

(* hashString: FNV-1a over the raw UTF-8 bytes, mask.  == mdk_hash_string (C).
   offset basis 0xCBF29CE484222325, prime 0x100000001B3. *)
let hash_string (s : string) : int =
  let h = ref 0xCBF29CE484222325L in
  String.iter (fun c ->
    h := Int64.mul (Int64.logxor !h (Int64.of_int (Char.code c))) 0x100000001B3L) s;
  Int64.to_int (Int64.logand !h hash_mask)

(* hashFloat: bit-cast the double to u64, mix, mask.  == mdk_hash_float (C).
   -0.0 and 0.0 have distinct bit patterns and so hash differently — acceptable. *)
let hash_float (f : float) : int =
  Int64.to_int (Int64.logand (hash_mix64 (Int64.bits_of_float f)) hash_mask)

(* hashChar: hash the single codepoint as an int.  == mdk_hash_char (C). *)
let hash_char (c : string) : int =
  hash_int (Uchar.to_int (Uchar.utf_decode_uchar (String.get_utf_8_uchar c 0)))

(* Extra name→value bindings injected before eval_program runs — used by the
   check-policy demo harness to stub platform-supplied externs (cacheGet etc.)
   without modifying the primitives table.  Reset to [] after each use. *)
let extra_prims : (string * value) list ref = ref []

let snapshot_dir    : string ref = ref "snapshots"
let snapshot_update : bool ref   = ref false

(* ── Env helpers ─────────────────────────────────────────────────────────── *)

(* Force a zero-param binding's deferred thunk (Phase 138).  If the binding
   references itself such that the reference is forced *while it is still being
   computed* (e.g. `loop = ident loop`, where `ident`'s strict argument re-looks
   up `loop`), OCaml's `Lazy.force` re-enters the in-progress thunk and raises
   `CamlinternalLazy.Undefined`.  Catch it and surface a proper Medaka
   diagnostic naming the binding instead of leaking a raw OCaml fatal error. *)
let force_thunk name t =
  try Lazy.force t
  with CamlinternalLazy.Undefined ->
    raise (Eval_error (Printf.sprintf
      "recursive value '%s' is forced while it is being defined; a \
       non-function recursive binding must defer its self-reference \
       (through a lambda or continuation)" name, None))

(* Build a Hashtbl frame from an assoc list, preserving List.assoc_opt's
   first-occurrence-wins semantics (keep the first binding seen for each key, so
   `find_opt` matches what `List.assoc_opt` returned over the same list). *)
let table_of_assoc (l : (string * value ref) list) : value ref FrameTbl.t =
  let h = FrameTbl.create (max 16 (List.length l)) in
  List.iter (fun (k, c) -> if not (FrameTbl.mem h k) then FrameTbl.add h k c) l;
  h

let frame_find name = function
  | FList l  -> List.assoc_opt name l
  | FTable h -> FrameTbl.find_opt h name

(* Flatten a frame back to an assoc list (order within a frame is irrelevant —
   keys are unique per frame).  Used where a whole env is concatenated. *)
let frame_assoc = function
  | FList l  -> l
  | FTable h -> FrameTbl.fold (fun k c acc -> (k, c) :: acc) h []

let lookup env name =
  let rec search = function
    | [] -> raise (Eval_error ("unbound identifier: " ^ name, None))
    | frame :: rest ->
      (match frame_find name frame with
       | Some cell ->
         (match !cell with
          | VThunk t ->
            let v = force_thunk name t in
            cell := v;
            v
          | v -> v)
       | None -> search rest)
  in search env

(* Phase 112: resolve a method occurrence to the coalesced method binding,
   looking PAST a nearer same-named non-method shadow.  This matters only when a
   name is both an interface method and an explicitly-imported standalone (e.g.
   map's `toList`/`isEmpty` vs Foldable's): `eval_modules` binds the import in a
   frame ahead of the global method VMulti, so a plain `lookup` would return the
   standalone even for a genuine method call.  Walk frames, returning the first
   VMulti (the dispatcher); if no frame binds the name to a VMulti, fall back to
   the nearest binding (normal lookup) — preserving every non-collision case,
   where the nearest binding already IS the method. *)
let lookup_method env name =
  let rec search = function
    | [] -> lookup env name
    | frame :: rest ->
      (match frame_find name frame with
       | Some cell ->
         let v = (match !cell with
           | VThunk t -> let v = force_thunk name t in cell := v; v
           | v -> v) in
         (match v with VMulti _ -> v | _ -> search rest)
       | None -> search rest)
  in search env

let extend env binds =
  FList (List.map (fun (k, v) -> (k, ref v)) binds) :: env

(* ── Pretty-print values ─────────────────────────────────────────────────── *)

let rec pp_value = function
  | VInt n    -> string_of_int n
  | VFloat f  ->
    (* Canonical Medaka float lexeme (DECIDED 2026-06-15): "%.12g" then ".0" when
       integral.  Deliberate divergence from string_of_float, mirrored in
       runtime/medaka_rt.c so native and oracle stay byte-identical.  The
       'n'/'i' guard leaves nan/inf untouched (no "nan.0"/"inf.0"). *)
    let s = Printf.sprintf "%.12g" f in
    if String.exists (fun c -> c='.'||c='e'||c='E'||c='n'||c='i') s then s else s ^ ".0"
  | VString s -> s
  | VChar c   -> c
  | VBool b   -> string_of_bool b
  | VUnit     -> "()"
  | VTuple vs -> "(" ^ String.concat ", " (List.map pp_value vs) ^ ")"
  | VList vs  -> "[" ^ String.concat ", " (List.map pp_value vs) ^ "]"
  | VArray vs ->
    "[|" ^ String.concat ", " (Array.to_list (Array.map pp_value vs)) ^ "|]"
  | VCon (name, []) -> name
  | VCon (name, vs) ->
    name ^ " " ^ String.concat " " (List.map pp_value_atom vs)
  | VRecord (name, fields) ->
    let pp_f (k, v) = k ^ " = " ^ pp_value v in
    name ^ " { " ^ String.concat ", " (List.map pp_f fields) ^ " }"
  | VRef cell -> "Ref(" ^ pp_value !cell ^ ")"
  | VClosure _ -> "<closure>"
  | VPrim _    -> "<prim>"
  | VMulti vs  -> Printf.sprintf "<dispatch/%d>" (List.length vs)
  | VThunk t   -> pp_value (Lazy.force t)
  | VNamedImpl (n, _) -> Printf.sprintf "<impl:%s>" n
  | VTypedImpl (t, _, _, _, inner) -> Printf.sprintf "<impl@%s:%s>" t (pp_value inner)
  | VDict (key, _) -> Printf.sprintf "<dict:%s>" key
  | VDictHead (h, _) -> Printf.sprintf "<dict-head:%s>" h

and pp_value_atom v = match v with
  | VCon (_, _ :: _) | VTuple _ -> "(" ^ pp_value v ^ ")"
  | _ -> pp_value v

(* Escape a string into the body of a Medaka double-quoted literal, mirroring
   the escapes lexer.mll's read_string understands (backslash n, t, dquote,
   backslash, r, 0) so the result is valid, round-trippable source.  Backs
   debugStringLit. *)
let escape_string_lit s =
  let b = Buffer.create (String.length s + 2) in
  String.iter (fun c -> match c with
    | '"'    -> Buffer.add_string b "\\\""
    | '\\'   -> Buffer.add_string b "\\\\"
    | '\n'   -> Buffer.add_string b "\\n"
    | '\t'   -> Buffer.add_string b "\\t"
    | '\r'   -> Buffer.add_string b "\\r"
    | '\000' -> Buffer.add_string b "\\0"
    | c      -> Buffer.add_char b c) s;
  Buffer.contents b

let escape_char_lit c = match c with
  | "'"    -> "\\'"
  | "\\"   -> "\\\\"
  | "\n"   -> "\\n"
  | "\t"   -> "\\t"
  | "\r"   -> "\\r"
  | "\000" -> "\\0"
  | s      -> s

(* ── UTF-8 codepoint helpers for the String/Char kernel (Phase 75) ───────────
   String is a sequence of Unicode scalar values, UTF-8 backed; Char is one
   codepoint, stored as its UTF-8 bytes (the VChar representation).  These walk
   codepoint boundaries via the OCaml 5 stdlib (String.get_utf_8_uchar etc.),
   so no external dependency is needed for the bridge / perf / parse kernel. *)

(* Decode [s] into its codepoints, each kept as its own UTF-8 byte slice. *)
let utf8_codepoints (s : string) : string list =
  let n = String.length s in
  let rec go i acc =
    if i >= n then List.rev acc
    else
      let len = Uchar.utf_decode_length (String.get_utf_8_uchar s i) in
      go (i + len) (String.sub s i len :: acc)
  in
  go 0 []

(* Codepoint count (single pass, no allocation). *)
let utf8_length (s : string) : int =
  let n = String.length s in
  let rec go i count =
    if i >= n then count
    else go (i + Uchar.utf_decode_length (String.get_utf_8_uchar s i)) (count + 1)
  in
  go 0 0

(* Byte offset where the [cp]-th codepoint begins, clamped to [String.length s]
   when [cp] runs past the end. *)
let utf8_byte_offset (s : string) (cp : int) : int =
  let n = String.length s in
  let rec go i k =
    if k <= 0 || i >= n then i
    else go (i + Uchar.utf_decode_length (String.get_utf_8_uchar s i)) (k - 1)
  in
  go 0 cp

(* Half-open codepoint slice [lo, hi), clamped to [0, length] — never raises. *)
let utf8_slice (lo : int) (hi : int) (s : string) : string =
  let len = utf8_length s in
  let lo = if lo < 0 then 0 else if lo > len then len else lo in
  let hi = if hi < lo then lo else if hi > len then len else hi in
  let b_lo = utf8_byte_offset s lo in
  let b_hi = utf8_byte_offset s hi in
  String.sub s b_lo (b_hi - b_lo)

(* Byte index of the first occurrence of [needle] in [hay], or None.  UTF-8 is
   self-synchronizing and [needle] is a whole-codepoint string, so a full
   byte-sequence match can only land on a codepoint boundary — byte search is
   codepoint-correct.  Non-allocating compare loop. *)
let byte_search (needle : string) (hay : string) : int option =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then Some 0
  else
    let rec matches i j = j >= nl || (hay.[i + j] = needle.[j] && matches i (j + 1)) in
    let rec go i =
      if i + nl > hl then None
      else if matches i 0 then Some i
      else go (i + 1)
    in
    go 0

(* Codepoint index of byte offset [byte_off] in [s] (count of codepoints before
   it).  Used to report substring matches as codepoint indices. *)
let utf8_cp_at_byte (s : string) (byte_off : int) : int =
  let rec go i cp =
    if i >= byte_off then cp
    else go (i + Uchar.utf_decode_length (String.get_utf_8_uchar s i)) (cp + 1)
  in
  go 0 0

(* Decode the first codepoint of a Char's UTF-8 bytes. *)
let char_uchar (s : string) : Uchar.t =
  Uchar.utf_decode_uchar (String.get_utf_8_uchar s 0)

(* Encode a single codepoint to its UTF-8 byte string (the VChar form). *)
let uchar_to_string (u : Uchar.t) : string =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b u;
  Buffer.contents b

(* Whole-string case fold (Phase 75): apply [m] (uucp to_upper/to_lower) to
   every codepoint, expanding 1→N where Unicode requires it (e.g. ß → SS).
   This is why String.toUpper/toLower can't be `map charToUpper`: the Char→Char
   externs are identity on expansion, so full fidelity lives here. *)
let utf8_case_fold (m : Uchar.t -> [ `Self | `Uchars of Uchar.t list ]) (s : string) : string =
  let b = Buffer.create (String.length s) in
  List.iter (fun cp ->
    match m (char_uchar cp) with
    | `Self -> Buffer.add_string b cp
    | `Uchars us -> List.iter (Buffer.add_utf_8_uchar b) us)
    (utf8_codepoints s);
  Buffer.contents b

(* Named-field constructor name → field names in declaration order.
   Populated from DData ConNamed variants at eval init. *)
let ctor_field_order : (string, string list) Hashtbl.t = Hashtbl.create 4

(* ── Pattern matching ────────────────────────────────────────────────────── *)

let rec match_pat pat value =
  match pat, value with
  | PVar x, v -> Some [(x, v)]
  | PWild, _ -> Some []
  | PLit (LInt n), VInt m when n = m -> Some []
  | PLit (LFloat f), VFloat g when f = g -> Some []
  | PLit (LString s), VString t when s = t -> Some []
  | PLit (LChar c), VChar d when c = d -> Some []
  | PLit (LBool b), VBool c when b = c -> Some []
  | PLit LUnit, VUnit -> Some []
  (* Boolean constructors: True/False match VBool *)
  | PCon ("True",  []), VBool true  -> Some []
  | PCon ("False", []), VBool false -> Some []
  | PCon (name, pats), VCon (name', vals)
    when name = name' && List.compare_lengths pats vals = 0 ->
    match_pats pats vals
  | PCons (h, t), VList (x :: xs) ->
    (match match_pat h x with
     | None -> None
     | Some b1 ->
       (match match_pat t (VList xs) with
        | None -> None
        | Some b2 -> Some (b1 @ b2)))
  | PCons _, VList [] -> None
  | PTuple pats, VTuple vals when List.compare_lengths pats vals = 0 ->
    match_pats pats vals
  | PList pats, VList vals when List.compare_lengths pats vals = 0 ->
    match_pats pats vals
  | PList [], VList [] -> Some []
  | PAs (x, p), v ->
    (match match_pat p v with
     | None -> None
     | Some binds -> Some ((x, v) :: binds))
  | PRec (ctor, fields, _rest), VCon (ctor', vals) when ctor = ctor' ->
    (match Hashtbl.find_opt ctor_field_order ctor with
     | None -> None
     | Some field_names ->
       let field_assoc = List.combine field_names vals in
       let result = ref (Some []) in
       List.iter (fun (fname, pat_opt) ->
         if !result <> None then
           match List.assoc_opt fname field_assoc with
           | None -> result := None
           | Some v ->
             (match pat_opt with
              | None ->
                result := Option.map (fun bs -> bs @ [(fname, v)]) !result
              | Some q ->
                match match_pat q v with
                | None   -> result := None
                | Some b -> result := Option.map (fun bs -> bs @ b) !result)
       ) fields;
       !result)
  | PRec (_, fields, _rest), VRecord (_, record_fields) ->
    let result = ref (Some []) in
    List.iter (fun (fname, pat_opt) ->
      if !result <> None then
        match List.assoc_opt fname record_fields with
        | None -> result := None
        | Some v ->
          (match pat_opt with
           | None ->
             result := Option.map (fun bs -> bs @ [(fname, v)]) !result
           | Some q ->
             match match_pat q v with
             | None   -> result := None
             | Some b -> result := Option.map (fun bs -> bs @ b) !result)
    ) fields;
    !result
  | PRec _, _ -> None
  | PRng (LInt lo, LInt hi, incl), VInt v ->
    let hi' = if incl then hi else hi - 1 in
    if v >= lo && v <= hi' then Some [] else None
  | PRng (LChar lo, LChar hi, incl), VChar c ->
    let cmp = String.compare in
    if cmp c lo >= 0 && (if incl then cmp c hi <= 0 else cmp c hi < 0)
    then Some [] else None
  | PRng _, _ -> None
  | _ -> None

and match_pats pats vals =
  List.fold_left2
    (fun acc p v ->
       match acc with
       | None -> None
       | Some binds ->
         (match match_pat p v with
          | None -> None
          | Some b -> Some (binds @ b)))
    (Some []) pats vals

(* ── Monad context for do-blocks ─────────────────────────────────────────── *)

let current_loc : loc option ref = ref None

(* Constructor name → type name.  Populated from DData declarations at eval
   init.  Used by runtime_type_tag to map a value's head constructor back to its
   type for VMulti dispatch. *)
let ctor_to_type : (string, string) Hashtbl.t = Hashtbl.create 8

(* (iface_name, method_name) → list of argument positions whose types mention
   any of the interface's type parameters.  Populated when DInterface declarations
   are processed; consulted at DImpl registration so each impl method is wrapped
   in a VTypedImpl carrying the right dispatch metadata. *)
let iface_dispatch : (string * string, int list) Hashtbl.t = Hashtbl.create 8

(* Walk a method's declared type and find argument positions that mention any
   of the given interface type parameters.  Strips leading `TyConstrained` and
   `TyEffect` wrappers; recurses into TyApp/TyFun/TyTuple looking for matching
   TyVars. *)
let dispatch_positions_of (method_ty : Ast.ty) (iface_params : Ast.ident list)
    : int list =
  let rec mentions = function
    | Ast.TyVar n -> List.mem n iface_params
    | Ast.TyCon _ -> false
    | Ast.TyApp (a, b) | Ast.TyFun (a, b) -> mentions a || mentions b
    | Ast.TyTuple ts -> List.exists mentions ts
    | Ast.TyEffect (_, _, t) | Ast.TyConstrained (_, t) -> mentions t
  in
  let rec args_of = function
    | Ast.TyConstrained (_, t) -> args_of t
    | Ast.TyEffect (_, _, t) -> args_of t
    | Ast.TyFun (a, b) -> a :: args_of b
    | _ -> []
  in
  args_of method_ty
  |> List.mapi (fun i a -> (i, a))
  |> List.filter_map (fun (i, a) -> if mentions a then Some i else None)

let record_iface_dispatch (iface_name : string) (type_params : Ast.ident list)
    (methods : Ast.iface_method list) : unit =
  List.iter (fun (m : Ast.iface_method) ->
    let positions = dispatch_positions_of m.method_type type_params in
    Hashtbl.replace iface_dispatch (iface_name, m.method_name) positions
  ) methods

(* Look up the dispatch positions for an impl method.  Defaults to [0] when
   the interface declaration hasn't been seen yet — this matches the pre-fix
   behaviour where every arg triggered the tag filter on dispatch. *)
let lookup_dispatch_positions (iface_name : string) (method_name : string) : int list =
  try Hashtbl.find iface_dispatch (iface_name, method_name)
  with Not_found -> [0]

(* Phase 69.x-e: count the leading dictionary parameters dict_pass prepended to a
   method body ($dict_<method>_<slot>).  Argument-tag dispatch positions, computed
   from the method's *surface* type, must shift right by this count so the filter
   still fires on the discriminating value argument and not on a leading dict. *)
let leading_dict_params (pats : Ast.pat list) : int =
  let is_dict = function
    | Ast.PVar n ->
      String.length n >= 6 && String.sub n 0 6 = "$dict_"
    | _ -> false
  in
  let rec count = function
    | p :: rest when is_dict p -> 1 + count rest
    | _ -> 0
  in
  count pats


(* Type name → arbitrary generator function.  Populated from `impl Arbitrary T`
   declarations at eval init.  Used by prop_runner to generate random values
   for user-defined types without going through VMulti dispatch. *)
let arbitrary_registry : (string, unit -> value) Hashtbl.t = Hashtbl.create 8

(* Type name → shrink function.  Populated from an `impl Arbitrary T` that
   *overrides* `shrink` (the interface default `shrink _ = []` is not an impl
   method, so a non-overriding impl registers nothing).  Used by prop_runner so
   a hand-written/derived `shrink` wins over the native shrinker. *)
let shrink_registry : (string, value -> value) Hashtbl.t = Hashtbl.create 8

(* Runtime "head type" tag for a value.  Used to filter VMulti candidates
   tagged via VTypedImpl when dispatching on a value of known shape. *)
let rec runtime_type_tag = function
  | VInt _    -> Some "Int"
  | VFloat _  -> Some "Float"
  | VString _ -> Some "String"
  | VChar _   -> Some "Char"
  | VBool _   -> Some "Bool"
  | VUnit     -> Some "Unit"
  | VList _   -> Some "List"
  | VArray _  -> Some "Array"
  | VTuple _  -> Some "__tuple__"   (* matches typecheck's synthetic tuple head *)
  | VCon (cname, _) -> Hashtbl.find_opt ctor_to_type cname
  | VRecord (name, _) -> Some name
  | VTypedImpl (t, _, _, _, _) -> Some t
  | VNamedImpl (_, inner) -> runtime_type_tag inner
  | _ -> None

(* Phase 69: the canonical impl key a VMulti candidate carries (through any
   VNamedImpl wrapper), or None if it isn't a typed impl. *)
let rec candidate_key = function
  | VTypedImpl (_, key, _, _, _) -> Some key
  | VNamedImpl (_, inner) -> candidate_key inner
  | _ -> None

(* Phase 69: narrow a method binding to the single impl the typechecker chose,
   identified by its canonical key.  Only fires for VMulti bindings; if exactly
   one candidate matches the key, return it (keeping its dispatch wrapper so
   partial application still works).  No unique match — wrong key, single-impl
   binding, or a value that isn't a VMulti — leaves the binding untouched so the
   arg-tag dispatch path runs as before. *)
let select_impl_by_key key = function
  | VMulti vs as v ->
    (match List.filter (fun c -> candidate_key c = Some key) vs with
     | [c] -> c
     | _ -> v)
  | v -> v

(* Phase 69.x-c: narrow a method binding by the impl's *head tycon* alone, for
   return-position calls whose discriminating type is head-concrete but whose
   args are still free (`pure x : Result e a`).  The typechecker only stamps
   RHeadKey when a single-param interface's head uniquely picks an impl, so a
   unique head match here is the impl it chose.  Like select_impl_by_key, a
   non-unique match leaves the binding untouched (arg-tag fallback). *)
let select_impl_by_head head = function
  | VMulti vs as v ->
    (match List.filter (fun c -> runtime_type_tag c = Some head) vs with
     | [c] -> c
     | _ -> v)
  | v -> v

(* Phase 69.x: build the runtime dictionary for a dict route.  RKey is a literal
   impl key (VDict); RDict forwards an enclosing dict param (key or head);
   RHeadKey (Phase 83/84 #4) carries a head-concrete args-free dispatch type as a
   VDictHead — eval narrows by head tag when the body reads it. *)
let rec dict_of_route env = function
  | Ast.RKey (key, reqs) ->
    (* Phase 83/84 #5: build the structured dict — the impl key plus its own
       `requires` dicts, recursively, so a nested instance dict carries every
       element dict its body will need. *)
    VDict (key, List.map (dict_of_route env) reqs)
  | Ast.RDict d  ->
    (match lookup env d with (VDict _ | VDictHead _) as vd -> vd | _ -> VDict ("", []))
  | Ast.RHeadKey h -> VDictHead (h, [])
  | Ast.RLocal -> VDict ("", [])  (* Phase 112: RLocal never appears in a dict route *)

(* Convert Impl_no_match → Eval_error at the boundary of user-visible code.
   Used at every eval site that is NOT inside a VMulti dispatch chain. *)
let wrap_match_errors f =
  try f ()
  with Impl_no_match ->
    raise (Eval_error ("non-exhaustive match", !current_loc))

(* Walk a field path off [top], setting the final field to [new_val].
   Records rebuild copy-on-update (immutable fields); a `Ref .value` step
   mutates the cell in place and the shared cell keeps its identity, so a
   surrounding record need not be re-shadowed for the effect to persist.
   Returns the (possibly rebuilt) top value. *)
let rec update_path top fields new_val =
  match fields, top with
  | [], _ -> new_val
  | f :: rest, VRecord (name, fs) ->
    let child =
      match List.assoc_opt f fs with
      | Some v -> v
      | None -> raise (Eval_error ("unknown field in assignment: " ^ f, !current_loc))
    in
    let child' = update_path child rest new_val in
    VRecord (name, List.map (fun (k, v) -> if k = f then (k, child') else (k, v)) fs)
  | f :: rest, VRef cell when f = "value" ->
    cell := update_path !cell rest new_val;
    top
  | _, _ ->
    raise (Eval_error ("field assignment on non-record/ref value", !current_loc))

(* ── Mutually recursive evaluator ───────────────────────────────────────── *)

let rec apply fn arg =
  match fn with
  | VClosure (env, [p], body) ->
    (match match_pat p arg with
     | None -> raise Impl_no_match
     | Some binds -> eval (extend env binds) body)
  | VClosure (env, p :: ps, body) ->
    (match match_pat p arg with
     | None -> raise Impl_no_match
     | Some binds -> VClosure (extend env binds, ps, body))
  | VClosure (_, [], _) ->
    raise (Eval_error ("applied closure with no parameters", !current_loc))
  | VPrim f -> f arg
  | VNamedImpl (n, inner) ->
    (* Sibling of the VTypedImpl arm below — same shape, for a named impl.  A
       bare VNamedImpl reaches `apply` whenever the typed pipeline has *already*
       committed the method occurrence to one named impl (EMethodRef stamped
       RKey → eval's RKey arm `select_impl_by_key`-narrows the VMulti to this
       single VNamedImpl), then applies it.  Two routes reach here:
         - explicit `@Impl` hint: `combine @First 3 4` (the hint arm passes the
           already-narrowed VNamedImpl through via `| other -> other`);
         - a lone named impl with no hint: `bar 3 4` where `impl Foo of Bar Int`
           is the only candidate — never touches the hint arm at all.
       Pass the argument through to the inner value, preserving the name tag
       across partial applications so a multi-arg method keeps routing to the
       same impl.  (In the VMulti dispatch path tags are unwrapped before
       `apply`, so this arm only fires for an already-narrowed named impl.) *)
    let result = apply inner arg in
    (match result with
     | VClosure _ | VPrim _ | VMulti _ -> VNamedImpl (n, result)
     | _ -> result)
  | VTypedImpl (t, key, positions, seen, inner) ->
    (* Pass through to the inner value but preserve the dispatch metadata
       across partial applications so subsequent VMulti dispatch can still
       route to the right typed candidate.  (See the VNamedImpl arm above — the
       named-impl analogue of this same tag-preserving pattern.) *)
    let result = apply inner arg in
    (match result with
     | VClosure _ | VPrim _ | VMulti _ -> VTypedImpl (t, key, positions, seen + 1, result)
     | _ -> result)
  | VMulti vs ->
    (* Apply each impl to arg; collect results.
       - Terminal result (non-closure): first one wins (return immediately).
       - VClosure/VMulti result (partial application): collect ALL that succeeded;
         return as a new VMulti so the next argument can dispatch correctly.
       - If all fail: dispatch error.
       VNamedImpl/VTypedImpl entries are unwrapped before applying; the tag
       and dispatch metadata are re-attached to partial-application results
       so subsequent dispatch still sees the routing info.
       The tag-filter only fires for VTypedImpl candidates whose `args_seen`
       is in their declared `dispatch_positions` set — i.e. the arg about to
       be applied is the one that determines impl selection.  Candidates not
       at a dispatching slot (e.g. fold's accumulator) pass through unfiltered;
       candidates with empty positions (e.g. `pure : a -> f a`, where no arg
       mentions the interface type param) are never filtered positionally. *)
    let unwrap_tags = function
      | VNamedImpl (_, inner) -> inner
      | VTypedImpl (_, _, _, _, inner) -> inner
      | v -> v
    in
    let is_dispatching = function
      | VTypedImpl (_, _, positions, seen, _) -> List.mem seen positions
      | VNamedImpl (_, VTypedImpl (_, _, positions, seen, _)) -> List.mem seen positions
      | _ -> false
    in
    let vs =
      match runtime_type_tag arg with
      | None -> vs
      | Some tag ->
        let matches_tag = function
          | VTypedImpl (t, _, _, _, _) -> t = tag
          | VNamedImpl (_, VTypedImpl (t, _, _, _, _)) -> t = tag
          | _ -> true  (* untagged candidates always considered *)
        in
        (* Only filter candidates that are at a dispatching slot.  A
           non-dispatching candidate (e.g. a Foldable impl with `args_seen`
           still on the accumulator) gets a free pass regardless of tag. *)
        let should_filter = List.exists is_dispatching vs in
        if not should_filter then vs
        else
          let keep v = (not (is_dispatching v)) || matches_tag v in
          let filtered = List.filter keep vs in
          if filtered = [] then vs else filtered
    in
    let rec collect_partials acc = function
      | [] ->
        (match acc with
         | [] -> raise (Eval_error ("no matching impl for dispatch", !current_loc))
         | [v] -> v
         | many -> VMulti (List.rev many))
      | v :: rest ->
        (match (try Some (apply (unwrap_tags v) arg) with Impl_no_match -> None) with
         | None -> collect_partials acc rest
         | Some (VClosure _ | VPrim _ | VMulti _ as c) ->
           let wrapped = (match v with
             | VNamedImpl (n, _) -> VNamedImpl (n, c)
             | VTypedImpl (t, key, positions, seen, _) ->
               VTypedImpl (t, key, positions, seen + 1, c)
             | _ -> c) in
           collect_partials (wrapped :: acc) rest
         | Some terminal -> terminal)  (* first terminal result wins *)
    in
    collect_partials [] vs
  | _ ->
    raise (Eval_error ("applied non-function: " ^ pp_value fn, !current_loc))

and eval env expr =
  match expr with
  | ELoc (loc, e) ->
    current_loc := Some loc;
    (* Guard at the call site: record_hit is a cross-module call (not inlined
       without flambda) taking two field reads, but no-ops unless coverage is on.
       This arm fires on essentially every expression node, so skipping the call
       when coverage is off — the case for every diff/run harness — is a real
       per-node saving. *)
    if !Coverage.enabled then Coverage.record_hit loc.file loc.line;
    eval env e

  | ELit (LInt n)    -> VInt n
  | ELit (LFloat f)  -> VFloat f
  | ELit (LString s) -> VString s
  | ELit (LChar c)   -> VChar c
  | ELit (LBool b)   -> VBool b
  | ELit LUnit       -> VUnit

  | EVar hint when String.length hint > 0 && hint.[0] = '@' ->
    VUnit  (* @Name as standalone expr; typechecker types it as Unit *)

  | EVar x -> lookup env x

  (* Phase 69 / 69.x: resolved method occurrence.  If the typechecker stamped
     this site with the impl it chose, narrow the VMulti to that one candidate by
     its canonical key — this is what makes return-position / multi-param
     dispatch pick the right impl instead of letting "first arg-tag match wins".
     - RKey key: the discriminating type was concrete at this site; narrow by key.
     - RDict d:  the discriminating type is the enclosing function's constraint
       var; read the runtime dictionary parameter `d` (a VDict key passed in by
       the caller) and narrow by that.
     - RHeadKey head: the discriminating type was head-concrete (head fixed, args
       free); narrow by the impl's head tycon (Phase 69.x-c).
     When unstamped (genuinely polymorphic site with no enclosing constraint) or
     the key isn't found, fall back to the whole VMulti and arg-tag dispatch. *)
  | EMethodRef (r, x) ->
    (match !r with
     | None -> lookup env x
     (* Phase 112: the typechecker found no impl of this interface for the
        concrete receiver but the name has an explicitly-imported/local
        standalone — a plain `lookup` (which the import frame shadows ahead of
        any global method VMulti) IS that standalone.  Return it unnarrowed,
        with no dict folding. *)
     | Some { Ast.res_route = RLocal; _ } -> lookup env x
     | Some { Ast.res_route; res_method_dicts; res_impl_dicts; res_fwd_requires; _ } ->
       (* A genuine method dispatch: resolve the method VMulti past any nearer
          same-named standalone shadow (Phase 112), then narrow by the route. *)
       let v = lookup_method env x in
       (* First narrow by the t-dispatch route (return-position / multi-param).
          A RDict route also *forwards* the dict value's own `requires` dicts
          (Phase 83/84 #5): the structured dict the caller passed carries the
          element dicts for the selected impl's body, so the inner return-position
          ref inside a recursive instance resolves level by level.  RKey routes
          carry their requires statically in res_impl_dicts instead, so
          forwarded_requires is empty for them. *)
       let v, forwarded_requires = match res_route with
         | RKey (key, _) -> select_impl_by_key key v, []
         | RHeadKey head -> select_impl_by_head head v, []
         | RDict d -> (match lookup env d with
                       (* res_fwd_requires gates the splice to return-position
                          sites: an arg-position method dispatches by arg-tag and
                          would be corrupted by extra leading dict args. *)
                       | VDict (key, reqs)  ->
                         select_impl_by_key key v, (if res_fwd_requires then reqs else [])
                       | VDictHead (h, reqs) ->
                         select_impl_by_head h v, (if res_fwd_requires then reqs else [])
                       | _ -> v, [])
         | RLocal -> v, []  (* unreachable: handled by the RLocal arm above *)
       in
       (* Phase 96: select_impl_by_key keeps the chosen impl's dispatch wrapper
          (VTypedImpl/VNamedImpl) so a method awaiting arguments still arg-tag-
          dispatches and `apply` strips the tag on application.  But a *nullary*
          return-position method (`empty`, `minBound`) is a value, never applied —
          so the wrapper would leak into the program and break downstream
          pattern-matching / debug.  Once the route has pinned a single impl, strip
          the wrapper iff its payload is a terminal value (not a function still
          awaiting application). *)
       let v =
         let rec strip = function
           | VNamedImpl (_, inner) | VTypedImpl (_, _, _, _, inner) -> strip inner
           | other -> other in
         match v with
         | VNamedImpl _ | VTypedImpl _ ->
           (match strip v with
            | VClosure _ | VPrim _ | VMulti _ | VThunk _ -> v  (* awaits application *)
            | bare -> bare)                                    (* nullary value *)
         | _ -> v
       in
       (* Phase 103: only fold dicts onto a value still awaiting application. A
          nullary return-position impl body that is a terminal value (`empty =
          Tip`, `empty = [||]`) takes no dict params — dict_pass's `uses_impl_dict`
          gate adds none for it — so applying the route's dicts would over-apply
          them to a constructor/record/scalar (corruption / "applied non-function").
          Function-shaped bodies (closures, e.g. `impl Arbitrary (List a) requires
          Arbitrary a`) stay VClosure/VTypedImpl after the strip above and still
          receive their dicts, preserving Phase 83/84. *)
       let awaits_args = match v with
         | VClosure _ | VPrim _ | VMulti _ | VThunk _
         | VTypedImpl _ | VNamedImpl _ -> true
         | _ -> false in
       if not awaits_args then v
       else
         (* Phase 69.x-e: then apply the method's own method-level-constraint dicts
            (e.g. foldMap's Monoid dict) as leading arguments, matching the leading
            params dict_pass prepended to the method's bodies; the body's inner refs
            (`empty`) read them via RDict.  Empty list ⇒ no-op (untyped path / a
            method with no method-level constraint), preserving arg-tag fallback. *)
         let v =
           List.fold_left (fun f route -> apply f (dict_of_route env route))
             v res_method_dicts in
         (* Phase 83/84: then the *selected impl's* `requires` dicts (e.g. the
            `Arbitrary a` of `impl Arbitrary (List a)`), applied after the
            method-level dicts to match dict_pass's param order.  These let a
            return-position ref inside the impl body resolve via the element dict
            rather than failing arg-tag dispatch.  Empty ⇒ no-op (untyped path /
            impl with no requires). *)
         let v =
           List.fold_left (fun f route -> apply f (dict_of_route env route))
             v res_impl_dicts in
         (* Phase 83/84 #5: finally, the impl-`requires` dicts forwarded from a
            RDict route's structured dict value — already-built VDicts (the
            element dicts for a recursive instance), applied like res_impl_dicts.
            Exactly one of res_impl_dicts / forwarded_requires is non-empty: the
            former at a ground RKey site, the latter at a forwarded RDict site. *)
         List.fold_left apply v forwarded_requires)

  (* Phase 69.x: constrained-function occurrence.  Evaluate the function value,
     then apply the resolved dictionaries (one per constraint) as leading
     arguments — matching the dict parameters dict_pass prepended to its
     definition.  RKey builds a literal VDict; RDict forwards a dictionary
     parameter of the enclosing function.  Unstamped (no surviving constraints,
     or a name that didn't reach the recorder) → apply nothing. *)
  | EDictApp (r, x) ->
    let vf = lookup env x in
    (match !r with
     | None -> vf
     | Some routes ->
       List.fold_left (fun f route -> apply f (dict_of_route env route)) vf routes)

  | EApp (f_expr, EVar hint)
  | EApp (f_expr, ELoc (_, EVar hint))
    when String.length hint > 0 && hint.[0] = '@' ->
    (* @Name hint: evaluate f, then filter VMulti to the named impl *)
    let name = String.sub hint 1 (String.length hint - 1) in
    (match eval env f_expr with
     | VMulti vs ->
       let filtered = List.filter (function
         | VNamedImpl (n, _) -> n = name | _ -> false) vs in
       (match filtered with
        | []                  -> raise (Eval_error ("no impl named '" ^ name ^ "'", !current_loc))
        | [VNamedImpl (_, v)] -> v
        | many                -> VMulti many)
     | other -> other)  (* hint on non-VMulti: ignore gracefully *)

  | EApp (f, x) ->
    let fv = eval env f in
    let xv = eval env x in
    apply fv xv

  | ELam (pats, body) -> VClosure (env, pats, body)

  | ELet (_, true, PVar f, e1, e2) ->
    (* Self-recursive: create a mutable ref cell so the closure can call itself *)
    let cell = ref VUnit in
    let rec_env = FList [(f, cell)] :: env in
    let v = eval rec_env e1 in
    cell := v;
    eval rec_env e2

  | ELet (_, _, pat, e1, e2) ->
    let v = eval env e1 in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure", !current_loc))
     | Some binds -> eval (extend env binds) e2)

  | ELetGroup (bindings, body) ->
    let cells = List.map (fun (name, _) -> (name, ref VUnit)) bindings in
    let env' = FList cells :: env in
    List.iter (fun (name, clauses) ->
      let closures = List.map (fun (pats, rhs) ->
        if pats = [] then eval env' rhs
        else VClosure (env', pats, rhs)) clauses in
      (List.assoc name cells) := (match closures with
        | [v] -> v
        | many -> VMulti many)
    ) bindings;
    eval env' body

  | EMatch (scrut, arms) ->
    let sv = eval env scrut in
    let rec try_arms = function
      | [] -> raise Impl_no_match
      | (pat, guards, body) :: rest ->
        (match match_pat pat sv with
         | None -> try_arms rest
         | Some binds ->
           (* Run guard qualifiers in order; pattern binds extend the env for
              later qualifiers and the body.  Any failure falls through. *)
           let rec run env_cur = function
             | [] -> Some env_cur
             | GBool g :: qs ->
               (match eval env_cur g with
                | VBool true | VCon ("True", []) -> run env_cur qs
                | _ -> None)
             | GBind (p, e) :: qs ->
               (match match_pat p (eval env_cur e) with
                | Some b -> run (extend env_cur b) qs
                | None -> None)
           in
           (match run (extend env binds) guards with
            | Some env' -> eval env' body
            | None -> try_arms rest))
    in
    try_arms arms

  | EIf (cond, thn, els) ->
    (match eval env cond with
     | VBool true | VCon ("True", [])  -> eval env thn
     | VBool false | VCon ("False", []) -> eval env els
     | _ -> raise (Eval_error ("if condition is not a Bool", !current_loc)))

  | EBinOp (op, l, r, _) -> eval_binop env op l r

  | EUnOp ("-", e) ->
    (match eval env e with
     | VInt n   -> VInt (-n)
     | VFloat f -> VFloat (-.f)
     | _ -> raise (Eval_error ("unary minus on non-number", !current_loc)))

  | EUnOp (("!" | "not"), e) ->
    (match eval env e with
     | VBool b -> VBool (not b)
     | _ -> raise (Eval_error ("'!' on non-Bool", !current_loc)))

  | EUnOp (op, _) ->
    raise (Eval_error ("unknown unary op: " ^ op, !current_loc))

  | EFieldAccess (e, "value") ->
    (match eval env e with
     | VRef cell -> !cell
     | VRecord (_, fields) ->
       (match List.assoc_opt "value" fields with
        | Some v -> v
        | None -> raise (Eval_error ("record has no field 'value'", !current_loc)))
     | _ -> raise (Eval_error ("field access on non-record/ref", !current_loc)))

  | EFieldAccess (e, field) ->
    (match eval env e with
     | VRecord (_, fields) ->
       (match List.assoc_opt field fields with
        | Some v -> v
        | None -> raise (Eval_error ("unknown field: " ^ field, !current_loc)))
     | _ -> raise (Eval_error ("field access on non-record", !current_loc)))

  | ERecordCreate (name, fields) ->
    (match Hashtbl.find_opt ctor_field_order name with
     | Some order ->
       let vals = List.map (fun fn ->
         match List.assoc_opt fn fields with
         | Some e -> eval env e
         | None -> raise (Eval_error ("missing field: " ^ fn, !current_loc))
       ) order in
       VCon (name, vals)
     | None ->
       VRecord (name, List.map (fun (k, e) -> (k, eval env e)) fields))

  | ERecordUpdate (base, fields) ->
    (match eval env base with
     | VRecord (name, existing) ->
       let updates = List.map (fun (k, e) -> (k, eval env e)) fields in
       let merged = List.map (fun (k, v) ->
         match List.assoc_opt k updates with
         | Some v' -> (k, v')
         | None -> (k, v)) existing
       in
       VRecord (name, merged)
     | _ -> raise (Eval_error ("record update on non-record", !current_loc)))

  | EVariantUpdate (con, base, fields) ->
    (match eval env base with
     | VCon (con', vals) when con' = con ->
       let updates = List.map (fun (k, e) -> (k, eval env e)) fields in
       (match Hashtbl.find_opt ctor_field_order con with
        | Some order ->
          let new_vals = List.map2 (fun fn v ->
            match List.assoc_opt fn updates with
            | Some v' -> v'
            | None    -> v) order vals
          in
          VCon (con, new_vals)
        | None ->
          raise (Eval_error (con ^ " is not a named-field constructor", !current_loc)))
     | VCon (con', _) ->
       raise (Eval_error
         (Printf.sprintf "variant update expected %s, got %s" con con', !current_loc))
     | _ -> raise (Eval_error ("variant update on non-variant value", !current_loc)))

  | EArrayLit es -> VArray (Array.of_list (List.map (eval env) es))
  | EListLit es  -> VList (List.map (eval env) es)
  | EStringInterp parts ->
    let strs = List.map (function
      | InterpStr s  -> s
      | InterpExpr e -> (match eval env e with
          | VString s -> s
          | v -> pp_value v)
    ) parts in
    VString (String.concat "" strs)
  | EMapLit _ -> assert false (* eliminated by Desugar.lower_container_literals (Phase 108) *)
  | ESetLit _ -> assert false (* eliminated by Desugar.lower_container_literals (Phase 108) *)
  | EHeadAnnot (e, _) -> eval env e   (* transparent type pin (Phase 108) *)
  | ETuple es    -> VTuple (List.map (eval env) es)

  | EIndex (arr, idx) ->
    let i = match eval env idx with
      | VInt n -> n
      | _ -> raise (Eval_error ("index is not an Int", !current_loc))
    in
    (match eval env arr with
     | VArray a ->
       if i < 0 || i >= Array.length a then
         raise (Eval_error (Printf.sprintf "index %d out of bounds" i, !current_loc))
       else a.(i)
     | VList vs ->
       (match List.nth_opt vs i with
        | Some v -> v
        | None ->
          raise (Eval_error (Printf.sprintf "index %d out of bounds" i, !current_loc)))
     | VString s ->
       (* Codepoint-based (Phase 77): bound-check against the codepoint count
          and cut on codepoint boundaries, like the ESlice String arm.  Panics
          on OOB to match the array bracket.  Result is the one-codepoint VChar. *)
       let n = utf8_length s in
       if i < 0 || i >= n then
         raise (Eval_error (Printf.sprintf "index %d out of bounds" i, !current_loc))
       else
         let b_lo = utf8_byte_offset s i in
         let b_hi = utf8_byte_offset s (i + 1) in
         VChar (String.sub s b_lo (b_hi - b_lo))
     | _ -> raise (Eval_error ("index on non-array/list/string", !current_loc)))

  | EBlock stmts -> eval_block env stmts

  | EDo _ -> assert false (* eliminated by Desugar.lower_do_blocks (Phase 99) *)

  | EAnnot (e, _) -> eval env e

  | EListComp _ -> assert false (* eliminated by desugar_list_comps *)

  | EGuards _ | EFunction _ | ESection _ ->
    assert false (* eliminated by desugar_sugar *)

  | EQuestion _ -> assert false (* eliminated by desugar_questions *)

  | EAsPat _ ->
    (* Lowered to PAs by the parser in binding positions; only reachable here via
       the untyped eval path (which skips resolve) on a misplaced as-pattern. *)
    raise (Eval_error ("`@` as-pattern used outside a binding position", !current_loc))

  | ERangeList (elo, ehi, incl) ->
    let lo = match eval env elo with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi = match eval env ehi with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi' = if incl then hi + 1 else hi in
    VList (List.init (max 0 (hi' - lo)) (fun i -> VInt (lo + i)))

  | ERangeArray (elo, ehi, incl) ->
    let lo = match eval env elo with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi = match eval env ehi with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi' = if incl then hi + 1 else hi in
    VArray (Array.init (max 0 (hi' - lo)) (fun i -> VInt (lo + i)))

  | ESlice (earr, elo, ehi, incl) ->
    let lo = match eval env elo with
      | VInt n -> n
      | _ -> raise (Eval_error ("slice index must be Int", !current_loc))
    in
    let hi = match eval env ehi with
      | VInt n -> n
      | _ -> raise (Eval_error ("slice index must be Int", !current_loc))
    in
    let hi' = if incl then hi + 1 else hi in
    (match eval env earr with
     | VArray a ->
       let len = hi' - lo in
       if lo < 0 || hi' > Array.length a || len < 0 then
         raise (Eval_error (Printf.sprintf "slice [%d..%d] out of bounds" lo (hi'-1), !current_loc))
       else VArray (Array.sub a lo len)
     | VList vs ->
       VList (List.filteri (fun i _ -> i >= lo && i < hi') vs)
     | VString s ->
       (* Codepoint-based (Phase 75): bounds-check against the codepoint count,
          then cut on codepoint boundaries — byte indices would split multibyte
          chars.  Panics on OOB like the array bracket; String.slice /
          stringSlice are the clamping variants. *)
       let n = utf8_length s in
       let len = hi' - lo in
       if lo < 0 || hi' > n || len < 0 then
         raise (Eval_error (Printf.sprintf "slice [%d..%d] out of bounds" lo (hi'-1), !current_loc))
       else
         let b_lo = utf8_byte_offset s lo in
         let b_hi = utf8_byte_offset s hi' in
         VString (String.sub s b_lo (b_hi - b_lo))
     | _ -> raise (Eval_error ("slice on non-array/list/string", !current_loc)))

  | EInfix (op, l, r) ->
    let f  = lookup env op in
    let lv = eval env l in
    let rv = eval env r in
    apply (apply f lv) rv

and eval_binop env op l r =
  match op with
  | "|>" ->
    let lv = eval env l and fv = eval env r in
    apply fv lv
  | ">>" ->
    let fv = eval env l and gv = eval env r in
    VPrim (fun x -> apply gv (apply fv x))
  | "<<" ->
    let fv = eval env l and gv = eval env r in
    VPrim (fun x -> apply fv (apply gv x))
  | "&&" ->
    (match eval env l with
     | VBool false | VCon ("False", []) -> VBool false
     | VBool true  | VCon ("True", [])  -> eval env r
     | _ -> raise (Eval_error ("'&&' on non-Bool", !current_loc)))
  | "||" ->
    (match eval env l with
     | VBool true  | VCon ("True", [])  -> VBool true
     | VBool false | VCon ("False", []) -> eval env r
     | _ -> raise (Eval_error ("'||' on non-Bool", !current_loc)))
  | "::" ->
    let hv = eval env l and tv = eval env r in
    (match tv with
     | VList xs -> VList (hv :: xs)
     | _ -> raise (Eval_error ("cons (::) rhs is not a list", !current_loc)))
  | "++" ->
    let lv = eval env l and rv = eval env r in
    (* If one operand is a VMulti of differently-typed candidates (e.g. the
       polymorphic `empty` of Monoid), ground it using the other operand's
       runtime type tag.  This is what lets `acc ++ f x` in a polymorphic
       body work when acc started life as `empty`. *)
    let resolve other v = match v with
      | VMulti vs ->
        (match runtime_type_tag other with
         | None -> v
         | Some tag ->
           (match List.filter_map (function
              | VTypedImpl (t, _, _, _, inner) when t = tag -> Some inner
              | _ -> None) vs with
            | [single] -> single
            | _ -> v))
      | _ -> v
    in
    let lv = resolve rv lv in
    let rv = resolve lv rv in
    (match lv, rv with
     | VList xs, VList ys -> VList (xs @ ys)
     | VString a, VString b -> VString (a ^ b)
     | lv, rv ->
       (try apply (apply (lookup env "append") lv) rv
        with Eval_error _ ->
          raise (Eval_error ("'++' requires Semigroup (List, String, or a type with append)", !current_loc))))
  | _ ->
    let lv = eval env l and rv = eval env r in
    eval_arith op lv rv

and eval_arith op lv rv =
  match op, lv, rv with
  | "+",  VInt a,   VInt b   -> VInt (a + b)
  | "-",  VInt a,   VInt b   -> VInt (a - b)
  | "*",  VInt a,   VInt b   -> VInt (a * b)
  | "/",  VInt _,   VInt 0   -> raise (Eval_error ("division by zero", !current_loc))
  | "/",  VInt a,   VInt b   -> VInt (a / b)
  | "%",  VInt _,   VInt 0   -> raise (Eval_error ("modulo by zero", !current_loc))
  | "%",  VInt a,   VInt b   -> VInt (a mod b)
  | "+",  VFloat a, VFloat b -> VFloat (a +. b)
  | "-",  VFloat a, VFloat b -> VFloat (a -. b)
  | "*",  VFloat a, VFloat b -> VFloat (a *. b)
  | "/",  VFloat a, VFloat b -> VFloat (a /. b)
  | "%",  VFloat a, VFloat b -> VFloat (Float.rem a b)
  | "==", a, b -> VBool (a = b)
  | "!=", a, b -> VBool (a <> b)
  | "<",  a, b -> VBool (compare a b < 0)
  | ">",  a, b -> VBool (compare a b > 0)
  | "<=", a, b -> VBool (compare a b <= 0)
  | ">=", a, b -> VBool (compare a b >= 0)
  | _ ->
    raise (Eval_error
             (Printf.sprintf "unknown op '%s' for %s, %s"
                op (pp_value lv) (pp_value rv), !current_loc))

and eval_block env stmts =
  (* Bare sequential block: no monadic dispatch.  Value of the last stmt is
     the block's result. *)
  match stmts with
  | [] -> VUnit
  | [DoExpr e] -> wrap_match_errors (fun () -> eval env e)
  | [DoLet (_, _, pat, e)] ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in block", !current_loc))
     | Some _ -> VUnit)
  | [DoAssign (_, e)] ->
    let _ = wrap_match_errors (fun () -> eval env e) in VUnit
  | [DoFieldAssign (x, fields, e)] ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    (* Last stmt: a rebuilt record would be discarded, but in-place Ref
       mutations along the path still persist — so walk the path for effect. *)
    let _ = update_path (lookup env x) fields new_val in
    VUnit
  | [DoLetElse _] ->
    raise (Eval_error ("block cannot end with a let-else binding", !current_loc))
  | [DoBind _] ->
    raise (Eval_error ("`<-` is only allowed inside a `do` block", !current_loc))
  | (DoExpr e) :: rest ->
    let _ = wrap_match_errors (fun () -> eval env e) in
    eval_block env rest
  | (DoLet (_, true, PVar f, e)) :: rest ->
    (* Function-definition form: self-recursive, mirroring ELet (_, true, ...) *)
    let cell = ref VUnit in
    let rec_env = FList [(f, cell)] :: env in
    let v = wrap_match_errors (fun () -> eval rec_env e) in
    cell := v;
    eval_block rec_env rest
  | (DoLet (_, _, pat, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in block", !current_loc))
     | Some binds -> eval_block (extend env binds) rest)
  | (DoAssign (x, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    eval_block (extend env [(x, v)]) rest
  | (DoFieldAssign (x, fields, e)) :: rest ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    let updated = update_path (lookup env x) fields new_val in
    eval_block (extend env [(x, updated)]) rest
  | (DoLetElse (pat, e, alt)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> eval env alt
     | Some binds -> eval_block (extend env binds) rest)
  | (DoBind _) :: _ ->
    raise (Eval_error ("`<-` is only allowed inside a `do` block", !current_loc))

(* ── Extern / primitive dispatch table ──────────────────────────────────── *)

let unwrap_list = function
  | VList vs -> vs
  | v -> raise (Eval_error ("expected list, got: " ^ pp_value v, None))

let primitives : (string * value) list =
  [
    (* Phase 111: `print`/`println` moved into core.mdk (Medaka, Display-routed)
       over these string-only externs.  The non-VString branch is defensive —
       the Medaka type `String -> <IO> Unit` guarantees a VString in practice. *)
    ("putStr", VPrim (fun v -> match v with
       | VString s -> !output_hook s; VUnit
       | _ -> raise (Eval_error ("putStr: expected String", None))));
    ("putStrLn", VPrim (fun v -> match v with
       | VString s -> !output_hook s; !output_hook "\n"; VUnit
       | _ -> raise (Eval_error ("putStrLn: expected String", None))));
    (* `pure` is no longer a primitive — it's an ordinary Applicative interface
       method (stdlib/core.mdk), routed by its EMethodRef to the impl the
       typechecker chose (Phase 69.x-c retired the current_monad_type/pure_impls
       workaround). *)
    ("Ref",     VPrim (fun v -> VRef (ref v)));
    ("set_ref", VPrim (fun r ->
      VPrim (fun v ->
        match r with
        | VRef cell -> cell := v; VUnit
        | _ -> raise (Eval_error ("set_ref: not a Ref", None)))));
    (* `map`, `filter`, and `fold` are no longer primitives — they are
       defined in stdlib/core.mdk as regular Medaka functions. *)
    ("pi",      VFloat Float.pi);
    ("e",       VFloat (exp 1.0));
    (* Platform bounds for `impl Bounded Int`/`Bounded Char` (Phase 93).
       Int: 63-bit OCaml `int` limits.  Char: U+0000 / U+10FFFF as UTF-8,
       built the same way as `charFromCode`. *)
    ("intMinBound",  VInt min_int);
    ("intMaxBound",  VInt max_int);
    ("charMinBound", VChar "\x00");
    ("charMaxBound",
      (let b = Buffer.create 4 in
       Buffer.add_utf_8_uchar b (Uchar.of_int 0x10FFFF);
       VChar (Buffer.contents b)));
    ("readLine", VPrim (fun _ -> VString (input_line stdin)));
    ("readFile", VPrim (fun path ->
      match path with
      | VString p ->
        (try
           let ic = open_in p in
           let s = really_input_string ic (in_channel_length ic) in
           close_in ic;
           VCon ("Ok", [VString s])
         with Sys_error msg -> VCon ("Err", [VString msg]))
      | _ -> raise (Eval_error ("readFile: expected String", None))));
    ("writeFile", VPrim (fun path ->
      VPrim (fun content ->
        match path, content with
        | VString p, VString s ->
          (try
             let oc = open_out p in
             output_string oc s;
             close_out oc;
             VCon ("Ok", [VUnit])
           with Sys_error msg -> VCon ("Err", [VString msg]))
        | _ -> raise (Eval_error ("writeFile: expected String String", None)))));
    (* runCommand prog args: spawn a subprocess, capture stdout+stderr.
       Returns Ok (exitCode, stdout, stderr) on spawn success (any exit code),
       or Err osError if the process could not be created. *)
    ("runCommand", VPrim (fun prog_v ->
      VPrim (fun args_v ->
        match prog_v with
        | VString prog ->
          let rec list_to_strings = function
            | VList vs -> List.map (function VString s -> s | _ -> "") vs
            | VCon ("Cons", [VString h; tl]) -> h :: list_to_strings tl
            | VCon ("Nil", []) -> []
            | _ -> []
          in
          let str_args = list_to_strings args_v in
          let argv = Array.of_list (prog :: str_args) in
          let out_path = Filename.temp_file "mdk_cmd_out_" "" in
          let err_path = Filename.temp_file "mdk_cmd_err_" "" in
          let cleanup () =
            (try Sys.remove out_path with _ -> ());
            (try Sys.remove err_path with _ -> ())
          in
          (try
            let out_fd = Unix.openfile out_path
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
            let err_fd = Unix.openfile err_path
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
            let pid = Unix.create_process prog argv Unix.stdin out_fd err_fd in
            Unix.close out_fd;
            Unix.close err_fd;
            let (_, status) = Unix.waitpid [] pid in
            let exit_code = match status with
              | Unix.WEXITED c  -> c
              | Unix.WSIGNALED s -> 128 + s
              | Unix.WSTOPPED  s -> 128 + s
            in
            let read_temp p =
              try
                let ic = open_in_bin p in
                let s = really_input_string ic (in_channel_length ic) in
                close_in ic; s
              with _ -> ""
            in
            let stdout_s = read_temp out_path in
            let stderr_s = read_temp err_path in
            cleanup ();
            VCon ("Ok", [VTuple [VInt exit_code; VString stdout_s; VString stderr_s]])
           with Unix.Unix_error (e, _, _) ->
             cleanup ();
             VCon ("Err", [VString (Unix.error_message e)]))
        | _ -> raise (Eval_error ("runCommand: expected String", None)))));
    ("exit", VPrim (fun code ->
      match code with
      | VInt n -> Stdlib.exit n
      | _ -> raise (Eval_error ("exit: expected Int", None))));
    ("panic", VPrim (fun msg ->
      match msg with
      | VString s -> raise (Eval_error ("panic: " ^ s, !current_loc))
      | _ -> raise (Eval_error ("panic", !current_loc))));

    (* ── io Module 7 externs ───────────────────────────────────────────── *)
    (* Process args (after the script name); see Eval.program_args. *)
    ("args", VPrim (fun _ -> VList (List.map (fun s -> VString s) !program_args)));
    (* Environment variable lookup: Some value, or None when unset. *)
    ("getEnv", VPrim (fun name -> match name with
       | VString n ->
         (match Sys.getenv_opt n with
          | Some v -> VCon ("Some", [VString v])
          | None   -> VCon ("None", []))
       | _ -> raise (Eval_error ("getEnv: expected String", None))));
    (* True when a file or directory exists at the path. *)
    ("fileExists", VPrim (fun path -> match path with
       | VString p -> VBool (Sys.file_exists p)
       | _ -> raise (Eval_error ("fileExists: expected String", None))));
    (* Append to a file (creating it if absent): Ok () or Err message. *)
    ("appendFile", VPrim (fun path ->
      VPrim (fun content ->
        match path, content with
        | VString p, VString s ->
          (try
             let oc = open_out_gen [Open_append; Open_creat] 0o644 p in
             output_string oc s;
             close_out oc;
             VCon ("Ok", [VUnit])
           with Sys_error msg -> VCon ("Err", [VString msg]))
        | _ -> raise (Eval_error ("appendFile: expected String String", None)))));
    (* Directory entries (names only, unordered): Ok [name, …] or Err message. *)
    ("listDir", VPrim (fun path -> match path with
       | VString p ->
         (try VCon ("Ok", [VList (Array.to_list (Array.map (fun s -> VString s) (Sys.readdir p)))])
          with Sys_error msg -> VCon ("Err", [VString msg]))
       | _ -> raise (Eval_error ("listDir: expected String", None))));
    ("makeDir", VPrim (fun path -> match path with
       | VString p ->
         (try Unix.mkdir p 0o755; VCon ("Ok", [VUnit])
          with
          | Unix.Unix_error (Unix.EEXIST, _, _) -> VCon ("Err", [VString ("Directory already exists: " ^ p)])
          | Unix.Unix_error (e, _, _) -> VCon ("Err", [VString (Unix.error_message e)]))
       | _ -> raise (Eval_error ("makeDir: expected String", None))));
    (* stderr output (raw string), routed through error_hook. *)
    ("ePutStr", VPrim (fun v -> match v with
       | VString s -> !error_hook s; VUnit
       | _ -> raise (Eval_error ("ePutStr: expected String", None))));
    ("ePutStrLn", VPrim (fun v -> match v with
       | VString s -> !error_hook s; !error_hook "\n"; VUnit
       | _ -> raise (Eval_error ("ePutStrLn: expected String", None))));
    (* Read one line from stdin: Some line, or None at end-of-input. *)
    ("readLineOpt", VPrim (fun _ ->
      (try VCon ("Some", [VString (input_line stdin)])
       with End_of_file -> VCon ("None", []))));
    (* Read all of stdin to a single string. *)
    ("readAll", VPrim (fun _ -> VString (In_channel.input_all stdin)));
    (* Flush buffered stdout — required by the LSP stdio loop so framed
       responses reach the client before the process exits. *)
    ("flushStdout", VPrim (fun _ -> flush stdout; VUnit));
    (* Read exactly N bytes from stdin; Some s or None at EOF / short read. *)
    ("readExactly", VPrim (fun v ->
      let n = match v with VInt n -> n | _ -> raise (Eval_error ("readExactly: expected Int", None)) in
      if n <= 0 then VCon ("Some", [VString ""])
      else
        let buf = Bytes.create n in
        let rec loop pos =
          if pos >= n then pos
          else
            let got = input stdin buf pos (n - pos) in
            if got = 0 then pos
            else loop (pos + got)
        in
        let filled = loop 0 in
        if filled = 0 then VCon ("None", [])
        else if filled = n then VCon ("Some", [VString (Bytes.sub_string buf 0 n)])
        else VCon ("None", [])));
    (* Wall-clock time in seconds (gettimeofday; monotonic-ish).  Used by the
       self-hosted perf driver to bracket each pipeline stage. *)
    ("wallTimeSec", VPrim (fun _ -> VFloat (Unix.gettimeofday ())));
    (* Total GC-allocated bytes since process start (Gc.allocated_bytes).
       Used by the self-hosted perf driver as an allocation-count proxy;
       monotonically increasing, so deltas give per-phase allocation. *)
    ("allocBytes", VPrim (fun _ -> VFloat (Gc.allocated_bytes ())));
    (* Per-type Hashable hashers — specified, byte-identical to runtime/medaka_rt.c
       (the mdk_hash_ helpers).  Replace the old structural __hashRaw (Hashtbl.hash),
       which the type-erased native runtime cannot replicate.  Each primitive
       Hashable impl in core.mdk calls one of these; results are non-negative,
       in [0, 2^30). *)
    ("hashInt", VPrim (fun v -> match v with
      | VInt n -> VInt (hash_int n)
      | _ -> raise (Eval_error ("hashInt: expected Int", None))));
    ("hashString", VPrim (fun v -> match v with
      | VString s -> VInt (hash_string s)
      | _ -> raise (Eval_error ("hashString: expected String", None))));
    ("hashChar", VPrim (fun v -> match v with
      | VChar c -> VInt (hash_char c)
      | _ -> raise (Eval_error ("hashChar: expected Char", None))));
    ("hashBool", VPrim (fun v -> match v with
      | VBool b -> VInt (if b then 1 else 0)
      | _ -> raise (Eval_error ("hashBool: expected Bool", None))));
    ("hashFloat", VPrim (fun v -> match v with
      | VFloat f -> VInt (hash_float f)
      | _ -> raise (Eval_error ("hashFloat: expected Float", None))));
    (* Phase 91: terminator of a desugared guard chain.  Raising Impl_no_match
       (the same signal a failed pattern raises) makes a multi-clause function's
       VMulti dispatch fall through to the next pattern clause when this clause's
       guards all fail; if no clause matches, the boundary converts it to a
       non-exhaustive-match runtime error. *)
    ("__fallthrough__", VPrim (fun _ -> raise Impl_no_match));
    ("randomInt", VPrim (fun lo ->
      VPrim (fun hi ->
        match lo, hi with
        | VInt lo', VInt hi' ->
          let range = hi' - lo' + 1 in
          if range <= 0 then VInt lo'
          else VInt (lo' + Int64.to_int
                       (Int64.unsigned_rem (splitmix64_next ()) (Int64.of_int range)))
        | _ -> raise (Eval_error ("randomInt: expected Int Int", None)))));
    ("randomBool", VPrim (fun _ ->
      VBool (Int64.logand (splitmix64_next ()) 1L = 1L)));
    ("randomFloat", VPrim (fun _ ->
      let bits = Int64.shift_right_logical (splitmix64_next ()) 11 in
      VFloat (Int64.to_float bits *. (1.0 /. 9007199254740992.0) *. 2.0 -. 1.0)));
    ("randomChar", VPrim (fun _ ->
      let c = 32 + Int64.to_int (Int64.unsigned_rem (splitmix64_next ()) 95L) in
      VChar (String.make 1 (Char.chr c))));
    ("setSeed", VPrim (fun n ->
      match n with
      | VInt seed -> rng_state := Int64.of_int seed; VUnit
      | _ -> raise (Eval_error ("setSeed: expected Int", None))));
    ("charToStr", VPrim (fun c ->
      match c with
      | VChar s -> VString s
      | _ -> raise (Eval_error ("charToStr: expected Char", None))));
    ("intToFloat", VPrim (fun v ->
      match v with
      | VInt n -> VFloat (Float.of_int n)
      | _ -> raise (Eval_error ("intToFloat: expected Int", None))));
    ("floatToInt", VPrim (fun v ->
      match v with
      | VFloat f -> VInt (Int.of_float f)
      | _ -> raise (Eval_error ("floatToInt: expected Float", None))));
    ("intToString", VPrim (fun v ->
      match v with
      | VInt n -> VString (string_of_int n)
      | _ -> raise (Eval_error ("intToString: expected Int", None))));
    ("floatToString", VPrim (fun v ->
      match v with
      | VFloat f ->
        (* Mirror pp_value's Float case exactly so debug == println for floats. *)
        let s = Printf.sprintf "%.12g" f in
        VString (if String.exists (fun c -> c='.'||c='e'||c='E'||c='n'||c='i') s then s else s ^ ".0")
      | _ -> raise (Eval_error ("floatToString: expected Float", None))));
    ("debugStringLit", VPrim (fun v ->
      match v with
      | VString s -> VString ("\"" ^ escape_string_lit s ^ "\"")
      | _ -> raise (Eval_error ("debugStringLit: expected String", None))));
    ("debugCharLit", VPrim (fun v ->
      match v with
      | VChar c -> VString ("'" ^ escape_char_lit c ^ "'")
      | _ -> raise (Eval_error ("debugCharLit: expected Char", None))));
    ("arrayLength", VPrim (fun v ->
      match v with
      | VArray a -> VInt (Array.length a)
      | _ -> raise (Eval_error ("arrayLength: expected Array", None))));
    ("arrayMake", VPrim (fun n_v ->
      VPrim (fun x ->
        match n_v with
        | VInt n ->
          if n < 0 then raise (Eval_error ("arrayMake: negative length", None))
          else VArray (Array.make n x)
        | _ -> raise (Eval_error ("arrayMake: expected Int", None)))));
    ("arrayMakeWith", VPrim (fun n_v ->
      VPrim (fun f ->
        match n_v with
        | VInt n ->
          if n < 0 then raise (Eval_error ("arrayMakeWith: negative length", None))
          else VArray (Array.init n (fun i -> apply f (VInt i)))
        | _ -> raise (Eval_error ("arrayMakeWith: expected Int", None)))));
    ("arrayGetUnsafe", VPrim (fun i_v ->
      VPrim (fun arr ->
        match i_v, arr with
        | VInt i, VArray a -> a.(i)
        | _ -> raise (Eval_error ("arrayGetUnsafe: expected Int, Array", None)))));
    ("arraySetUnsafe", VPrim (fun i_v ->
      VPrim (fun x ->
        VPrim (fun arr ->
          match i_v, arr with
          | VInt i, VArray a -> a.(i) <- x; VUnit
          | _ -> raise (Eval_error ("arraySetUnsafe: expected Int, _, Array", None))))));
    ("arrayCopy", VPrim (fun v ->
      match v with
      | VArray a -> VArray (Array.copy a)
      | _ -> raise (Eval_error ("arrayCopy: expected Array", None))));
    ("arrayBlit", VPrim (fun src ->
      VPrim (fun srcOff_v ->
        VPrim (fun dst ->
          VPrim (fun dstOff_v ->
            VPrim (fun len_v ->
              match src, srcOff_v, dst, dstOff_v, len_v with
              | VArray sa, VInt so, VArray da, VInt dof, VInt len ->
                if len < 0
                   || so < 0 || so + len > Array.length sa
                   || dof < 0 || dof + len > Array.length da
                then raise (Eval_error ("arrayBlit: out of bounds", None))
                else (Array.blit sa so da dof len; VUnit)
              | _ -> raise (Eval_error ("arrayBlit: type mismatch", None))))))));
    ("arrayFill", VPrim (fun x ->
      VPrim (fun arr ->
        match arr with
        | VArray a -> Array.fill a 0 (Array.length a) x; VUnit
        | _ -> raise (Eval_error ("arrayFill: expected Array", None)))));
    ("arraySortBy", VPrim (fun cmp ->
      VPrim (fun arr ->
        match arr with
        | VArray a ->
          let copy = Array.copy a in
          let cmp_int x y =
            match apply (apply cmp x) y with
            | VCon ("Lt", _) -> -1
            | VCon ("Eq", _) -> 0
            | VCon ("Gt", _) -> 1
            | _ -> raise (Eval_error ("arraySortBy: comparator did not return Ordering", None))
          in
          Array.sort cmp_int copy; VArray copy
        | _ -> raise (Eval_error ("arraySortBy: expected Array", None)))));
    ("arrayFromList", VPrim (fun v ->
      match v with
      | VList xs -> VArray (Array.of_list xs)
      | _ -> raise (Eval_error ("arrayFromList: expected List", None))));
    ("arraySortInPlaceBy", VPrim (fun cmp ->
      VPrim (fun arr ->
        match arr with
        | VArray a ->
          (* Translate Medaka Ordering (Lt|Eq|Gt) to OCaml int.  OCaml's
             Array.sort is not guaranteed stable; if/when we want stable,
             swap to Array.stable_sort (no API change). *)
          let cmp_int x y =
            match apply (apply cmp x) y with
            | VCon ("Lt", _) -> -1
            | VCon ("Eq", _) -> 0
            | VCon ("Gt", _) -> 1
            | _ -> raise (Eval_error ("arraySortInPlaceBy: comparator did not return Ordering", None))
          in
          Array.sort cmp_int a; VUnit
        | _ -> raise (Eval_error ("arraySortInPlaceBy: expected Array", None)))));
    (* ── String/Char kernel (Phase 75) ─────────────────────────────────────
       String = sequence of Unicode codepoints, UTF-8 backed; Char = one
       codepoint.  Bridge to Array Char + a few codepoint-aware perf externs;
       the bulk of stdlib/string.mdk is written in Medaka on top.  No external
       dependency here — Unicode classification/case folding (uucp) lands
       separately. *)
    ("stringToChars", VPrim (fun v ->
      match v with
      | VString s ->
        VArray (Array.of_list (List.map (fun c -> VChar c) (utf8_codepoints s)))
      | _ -> raise (Eval_error ("stringToChars: expected String", None))));
    ("stringFromChars", VPrim (fun v ->
      match v with
      | VArray a ->
        let b = Buffer.create (Array.length a) in
        Array.iter (fun c -> match c with
          | VChar s -> Buffer.add_string b s
          | _ -> raise (Eval_error ("stringFromChars: expected Array Char", None))) a;
        VString (Buffer.contents b)
      | _ -> raise (Eval_error ("stringFromChars: expected Array", None))));
    ("charCode", VPrim (fun v ->
      match v with
      | VChar s ->
        if String.length s = 0 then raise (Eval_error ("charCode: empty Char", None))
        else VInt (Uchar.to_int (Uchar.utf_decode_uchar (String.get_utf_8_uchar s 0)))
      | _ -> raise (Eval_error ("charCode: expected Char", None))));
    ("charFromCode", VPrim (fun v ->
      match v with
      | VInt n ->
        if Uchar.is_valid n then
          let b = Buffer.create 4 in
          Buffer.add_utf_8_uchar b (Uchar.of_int n);
          VCon ("Some", [VChar (Buffer.contents b)])
        else VCon ("None", [])
      | _ -> raise (Eval_error ("charFromCode: expected Int", None))));
    ("stringLength", VPrim (fun v ->
      match v with
      | VString s -> VInt (utf8_length s)
      | _ -> raise (Eval_error ("stringLength: expected String", None))));
    ("stringSlice", VPrim (fun lo_v ->
      VPrim (fun hi_v ->
        VPrim (fun s_v ->
          match lo_v, hi_v, s_v with
          | VInt lo, VInt hi, VString s -> VString (utf8_slice lo hi s)
          | _ -> raise (Eval_error ("stringSlice: expected Int Int String", None))))));
    ("stringConcat", VPrim (fun v ->
      match v with
      | VList xs ->
        let b = Buffer.create 16 in
        List.iter (fun x -> match x with
          | VString s -> Buffer.add_string b s
          | _ -> raise (Eval_error ("stringConcat: expected List String", None))) xs;
        VString (Buffer.contents b)
      | _ -> raise (Eval_error ("stringConcat: expected List", None))));
    ("stringIndexOf", VPrim (fun needle_v ->
      VPrim (fun hay_v ->
        match needle_v, hay_v with
        | VString needle, VString hay ->
          (match byte_search needle hay with
           | Some b -> VCon ("Some", [VInt (utf8_cp_at_byte hay b)])
           | None -> VCon ("None", []))
        | _ -> raise (Eval_error ("stringIndexOf: expected String String", None)))));
    ("stringCompare", VPrim (fun a_v ->
      VPrim (fun b_v ->
        match a_v, b_v with
        | VString a, VString b ->
          let c = String.compare a b in
          if c < 0 then VCon ("Lt", [])
          else if c > 0 then VCon ("Gt", [])
          else VCon ("Eq", [])
        | _ -> raise (Eval_error ("stringCompare: expected String String", None)))));
    ("stringToFloat", VPrim (fun v ->
      match v with
      | VString s ->
        (match float_of_string_opt s with
         | Some f -> VCon ("Some", [VFloat f])
         | None -> VCon ("None", []))
      | _ -> raise (Eval_error ("stringToFloat: expected String", None))));
    (* ── Unicode classification & case folding (Phase 75, via uucp) ─────────
       These need the Unicode character database, which OCaml's stdlib lacks.
       charToUpper/charToLower are Char→Char (single-codepoint, identity where
       Unicode expands 1→N); stringToUpper/stringToLower do full-fidelity
       expansion at the String level. *)
    ("charIsAlpha", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 -> VBool (Uucp.Alpha.is_alphabetic (char_uchar s))
      | _ -> raise (Eval_error ("charIsAlpha: expected Char", None))));
    ("charIsSpace", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 -> VBool (Uucp.White.is_white_space (char_uchar s))
      | _ -> raise (Eval_error ("charIsSpace: expected Char", None))));
    ("charIsUpper", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 -> VBool (Uucp.Case.is_upper (char_uchar s))
      | _ -> raise (Eval_error ("charIsUpper: expected Char", None))));
    ("charIsLower", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 -> VBool (Uucp.Case.is_lower (char_uchar s))
      | _ -> raise (Eval_error ("charIsLower: expected Char", None))));
    ("charIsPunct", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 ->
        (match Uucp.Gc.general_category (char_uchar s) with
         | `Pc | `Pd | `Pe | `Pf | `Pi | `Po | `Ps -> VBool true
         | _ -> VBool false)
      | _ -> raise (Eval_error ("charIsPunct: expected Char", None))));
    ("charToUpper", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 ->
        (match Uucp.Case.Map.to_upper (char_uchar s) with
         | `Uchars [u] -> VChar (uchar_to_string u)
         | `Self | `Uchars _ -> VChar s)
      | _ -> raise (Eval_error ("charToUpper: expected Char", None))));
    ("charToLower", VPrim (fun v ->
      match v with
      | VChar s when String.length s > 0 ->
        (match Uucp.Case.Map.to_lower (char_uchar s) with
         | `Uchars [u] -> VChar (uchar_to_string u)
         | `Self | `Uchars _ -> VChar s)
      | _ -> raise (Eval_error ("charToLower: expected Char", None))));
    ("stringToUpper", VPrim (fun v ->
      match v with
      | VString s -> VString (utf8_case_fold Uucp.Case.Map.to_upper s)
      | _ -> raise (Eval_error ("stringToUpper: expected String", None))));
    ("stringToLower", VPrim (fun v ->
      match v with
      | VString s -> VString (utf8_case_fold Uucp.Case.Map.to_lower s)
      | _ -> raise (Eval_error ("stringToLower: expected String", None))));
    ("assert_snapshot", VPrim (fun name_v ->
      VPrim (fun value_v ->
        match name_v, value_v with
        | VString name, VString value ->
          let safe = String.map (fun c ->
            if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
               (c >= '0' && c <= '9') || c = '-' then c else '_') name in
          let dir  = !snapshot_dir in
          let path = Filename.concat dir (safe ^ ".snap") in
          let ensure_dir () =
            (try Unix.mkdir dir 0o755
             with Unix.Unix_error (Unix.EEXIST, _, _) -> ()) in
          if !snapshot_update then begin
            ensure_dir ();
            let oc = open_out path in
            output_string oc value; close_out oc; VUnit
          end else begin
            match (try Some (In_channel.input_all (open_in path))
                   with Sys_error _ -> None) with
            | None ->
              ensure_dir ();
              let oc = open_out path in
              output_string oc value; close_out oc; VUnit
            | Some stored ->
              if stored = value then VUnit
              else raise (Eval_error (
                Printf.sprintf
                  "snapshot mismatch for '%s':\n  stored: %s\n  actual: %s"
                  name stored value, None))
          end
        | _ -> raise (Eval_error ("assert_snapshot: expected String String", None)))));
    (* Phase 127: catch-all for test bodies that raise an OCaml-level exception.
       Allows a dogfooded Medaka runner to survive a crashing test without losing
       subsequent results (Eval_error / Impl_no_match become Fail values). *)
    ("runExpectation", VPrim (fun thunk ->
      try apply thunk VUnit
      with
      | Eval_error (msg, _) -> VCon ("Fail", [VString msg])
      | Impl_no_match -> VCon ("Fail", [VString "non-exhaustive match"])));
  ]

let () =
  let dispatch_names = List.map fst primitives in
  List.iter (fun n ->
    if not (List.mem n dispatch_names) then
      failwith ("runtime.mdk extern '" ^ n ^ "' has no OCaml impl in eval.ml")
  ) Runtime.names

(* ── Specificity helpers for impl dispatch ordering ─────────────────────── *)

(* Count free type variables in a type.  Fewer = more specific = higher priority
   in VMulti dispatch.  E.g. TyCon "List" → 0; TyApp(TyCon "Result", TyVar "e") → 1. *)
let rec count_tyvars_ty = function
  | TyVar _          -> 1
  | TyApp (a, b)     -> count_tyvars_ty a + count_tyvars_ty b
  | TyFun (a, b)     -> count_tyvars_ty a + count_tyvars_ty b
  | TyTuple ts       -> List.fold_left (fun n t -> n + count_tyvars_ty t) 0 ts
  | TyEffect (_, _, t)  -> count_tyvars_ty t
  | TyConstrained (_, t) -> count_tyvars_ty t
  | TyCon _          -> 0

let tyvars_in_args args =
  List.fold_left (fun n t -> n + count_tyvars_ty t) 0 args

(* ── Constructor thunks for data declarations ────────────────────────────── *)

let make_ctor name arity =
  if arity = 0 then VCon (name, [])
  else
    let rec build collected remaining =
      if remaining = 0 then VCon (name, List.rev collected)
      else VPrim (fun v -> build (v :: collected) (remaining - 1))
    in
    build [] arity

(* Head type constructor of a type expression — used both for ctor→type mapping
   and for tagging impl bodies (VTypedImpl) by their dispatch type. *)
let rec head_tycon = function
  | Ast.TyCon n          -> Some n
  | Ast.TyApp (a, _)     -> head_tycon a
  | Ast.TyConstrained (_, t) | Ast.TyEffect (_, _, t) -> head_tycon t
  | Ast.TyTuple _        -> Some "__tuple__"
  | _ -> None

(* ── Shared program-evaluation helpers (Phase 110) ───────────────────────────
   These factor the bodies of the single-frame `eval_program` so the
   per-module `eval_modules` can reuse them with a global/local frame split.
   The seam is the pair of `fill` functions: `eval_program` passes the same
   `fill_cell` for both; `eval_modules` routes ctor/impl/interface-default fills
   to the shared *global* frame and DFunDef/DLetGroup fills to the current
   module's *local* frame. *)

(* Populate the process-global ctor→type / field-order tables and interface
   dispatch positions for a program.  Callers clear the tables first. *)
let collect_ctors_and_dispatch program =
  List.iter (fun d -> match Ast.inner_decl d with
    | DData (_, n, _, vs, _) ->
      List.iter (fun v ->
        Hashtbl.replace ctor_to_type v.con_name n;
        (match v.con_payload with
         | ConNamed fields ->
           Hashtbl.replace ctor_field_order v.con_name
             (List.map (fun f -> f.field_name) fields)
         | ConPos _ -> ())
      ) vs
    | DNewtype (_, type_name, _, con_name, _, _) ->
      Hashtbl.replace ctor_to_type con_name type_name
    | DInterface { iface_name; type_params; methods; _ } ->
      record_iface_dispatch iface_name type_params methods
    | _ -> ()
  ) program

(* Pass 1: pre-allocate value cells so forward references resolve.  Data
   constructors and interface-method/default cells go through [add_global];
   top-level DFunDef/DLetGroup names go through [add_local]. *)
let prealloc_cells ~add_global ~add_local program =
  List.iter (fun decl ->
    match Ast.inner_decl decl with
    | DNewtype (_, _, _, con, _, _) ->
      add_global con (make_ctor con 1)
    | DData (_, _, _, variants, _) ->
      List.iter (fun v ->
        let arity = match v.con_payload with
          | ConPos tys   -> List.length tys
          | ConNamed fls -> List.length fls
        in
        add_global v.con_name (make_ctor v.con_name arity)
      ) variants
    | DFunDef (_, name, _, _) ->
      add_local name VUnit
    | DLetGroup (_, bindings) ->
      List.iter (fun (name, _) -> add_local name VUnit) bindings
    | DImpl { methods; _ } ->
      List.iter (fun (name, _, _) -> add_global name VUnit) methods
    | DInterface { methods; _ } ->
      List.iter (fun m ->
        match m.method_default with
        | None -> ()
        | Some _ -> add_global m.method_name VUnit
      ) methods
    | _ -> ()
  ) program

(* Phase 121: build the value bound for an impl method clause.  A point-free
   (no-clause-param) body for an *argument*-dispatched method is eta-expanded
   into a closure that (a) defers the body's evaluation to call time and (b)
   supplies a real parameter at the discriminating slot.  Without it, eager
   evaluation at impl-binding time can capture a not-yet-bound global as its
   VUnit cell placeholder — e.g. `toList = identity` in the prelude, where
   `identity` is filled later — and the VTypedImpl dispatch wrapper then applies
   that value as a function (`applied non-function: ()`).  Top-level point-free
   DFunDefs already dodge this via VThunk; this is the impl-method analogue.
   A return-position / nullary method (`lookup_dispatch_positions` returns [])
   has no argument to dispatch on, so it keeps its eager value shape.  `$eta`
   cannot collide with a source identifier (idents are `lower alnum*`). *)
let impl_method_value env iface_name name pats body =
  if pats <> [] then VClosure (env, pats, body)
  else match lookup_dispatch_positions iface_name name with
    | [] -> wrap_match_errors (fun () -> eval env body)
    | _  -> VClosure (env, [Ast.PVar "$eta"], Ast.EApp (body, Ast.EVar "$eta"))

(* Pass 2: evaluate one declaration's bodies.  [env] is the eval environment
   closures capture; [fill_local] installs DFunDef/DLetGroup values,
   [fill_global] installs ctor/impl/interface-default values (the same function
   for both in the single-frame case).  [impl_acc] is shared across modules so
   each interface method coalesces to one VMulti; [fundef_acc] is per-module so
   same-named top-level functions in different modules stay isolated.  Zero-arg
   DFunDef names are pushed to [deferred] to force after all impls install. *)
let eval_decl_into ~env ~fill_local ~fill_global ~impl_acc ~fundef_acc ~deferred decl =
  match Ast.inner_decl decl with
  | DFunDef (_, name, pats, body) ->
    let v = if pats = [] then begin
      deferred := name :: !deferred;
      VThunk (lazy (wrap_match_errors (fun () -> eval env body)))
    end else wrap_match_errors (fun () -> VClosure (env, pats, body)) in
    let prev = try Hashtbl.find fundef_acc name with Not_found -> [] in
    let updated = prev @ [v] in
    Hashtbl.replace fundef_acc name updated;
    fill_local name (match updated with [v] -> v | many -> VMulti many)
  | DLetGroup (_, bindings) ->
    List.iter (fun (name, clauses) ->
      let closures = List.map (fun (pats, rhs) ->
        if pats = [] then wrap_match_errors (fun () -> eval env rhs)
        else VClosure (env, pats, rhs)) clauses in
      let v = match closures with
        | [v] -> v
        | many -> VMulti many
      in
      fill_local name v
    ) bindings
  | DImpl { iface_name; type_args; methods; impl_name; _ } ->
    let score = tyvars_in_args type_args in
    if iface_name = "Arbitrary" then begin
      let type_key = match type_args with
        | [t] -> head_tycon t
        | _ -> None
      in
      match type_key with
      | None -> ()
      | Some tname ->
        (match List.find_opt (fun (n, _, _) -> n = "arbitrary") methods with
         | Some (_, pats, body) ->
           let v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                   else VClosure (env, pats, body) in
           Hashtbl.replace arbitrary_registry tname (fun () -> apply v VUnit)
         | None -> ());
        (match List.find_opt (fun (n, _, _) -> n = "shrink") methods with
         | Some (_, pats, body) ->
           let v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                   else VClosure (env, pats, body) in
           Hashtbl.replace shrink_registry tname (fun a -> apply v a)
         | None -> ())
    end;
    let impl_type_tag = match type_args with
      | t :: _ -> head_tycon t
      | [] -> None
    in
    let impl_key = Ast.impl_key ~iface:iface_name ~type_args ~name:impl_name in
    List.iter (fun (name, pats, body) ->
      let new_v = impl_method_value env iface_name name pats body in
      let positions =
        List.map ((+) (leading_dict_params pats))
          (lookup_dispatch_positions iface_name name) in
      let typed_v = match impl_type_tag with
        | Some t -> VTypedImpl (t, impl_key, positions, 0, new_v)
        | None   -> new_v
      in
      let tagged_v = match impl_name with
        | Some n -> VNamedImpl (n, typed_v)
        | None   -> typed_v
      in
      let prev = try Hashtbl.find impl_acc name with Not_found -> [] in
      let updated = prev @ [(score, tagged_v)] in
      Hashtbl.replace impl_acc name updated;
      let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
      let closures = List.map snd sorted in
      fill_global name (match closures with [v] -> v | many -> VMulti many)
    ) methods
  | DInterface { type_params; methods; _ } ->
    let score = List.length type_params in
    List.iter (fun m ->
      match m.method_default with
      | None -> ()
      | Some (pats, body) ->
        let name = m.method_name in
        let new_v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                    else VClosure (env, pats, body) in
        let prev = try Hashtbl.find impl_acc name with Not_found -> [] in
        let updated = prev @ [(score, new_v)] in
        Hashtbl.replace impl_acc name updated;
        let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
        let closures = List.map snd sorted in
        fill_global name (match closures with [v] -> v | many -> VMulti many)
    ) methods
  | _ -> ()

(* ── Evaluate a full program ─────────────────────────────────────────────── *)

(* [prelude]: when true (default, legacy/untyped callers), prepend the raw
   prelude as before.  The typed drivers pass [prelude:false] with a tree that
   already begins with the *marked + dict-passed* prelude (Method_marker.
   marked_prelude), so its `when`/`unless` route return-position `pure` through
   the dictionary mechanism — re-prepending would duplicate it (Phase 69.x-c). *)
let eval_program ?(prelude = true) program =
  let top_frame : (string * value ref) list ref = ref [] in

  let add_to_frame name v =
    top_frame := (name, ref v) :: !top_frame
  in

  (* Seed True/False: these are lexed as BOOL literals (not UPPER tokens) and
     stored as VBool, but a few code paths look them up by name as plain
     values.  Option / Result / Ordering constructors are now bound via the
     prelude's DData declarations in Pass 1 below — no need to pre-seed. *)
  add_to_frame "True"  (VBool true);
  add_to_frame "False" (VBool false);

  (* Seed with primitives *)
  List.iter (fun (name, v) -> add_to_frame name v) (List.rev primitives);
  List.iter (fun (name, v) -> add_to_frame name v) !extra_prims;

  (* Prepend stdlib/core.mdk so its data types, interfaces, and impl bodies
     are bound for the user program.  Mirrors what Typecheck.check_program
     does on the type-checking side.  Do-block bind dispatches through the
     prelude's `andThen` VMulti, so this is what makes Step 3 work.
     Skip when the program IS core (avoid duplicates). *)
  let is_core =
    let has_ordering = List.exists (fun d -> match Ast.inner_decl d with
      | DData (_, "Ordering", _, _, _) -> true | _ -> false) program in
    let has_foldable = List.exists (fun d -> match Ast.inner_decl d with
      | DInterface { iface_name = "Foldable"; _ } -> true | _ -> false) program in
    has_ordering && has_foldable
  in
  let program = if is_core || not prelude then program else Prelude.program @ program in

  (* Reverse mapping ctor → type used by runtime_type_tag for VMulti dispatch,
     plus constructor field order; and interface dispatch positions so DImpl
     decls can look up the right positions regardless of source order. *)
  Hashtbl.clear ctor_to_type;
  Hashtbl.clear ctor_field_order;
  Hashtbl.clear arbitrary_registry;
  Hashtbl.clear shrink_registry;
  Hashtbl.clear iface_dispatch;
  collect_ctors_and_dispatch program;

  (* Pass 1: pre-allocate cells.  Single frame → ctors and DFunDef/DLetGroup
     share the one [add_to_frame]. *)
  prealloc_cells ~add_global:add_to_frame ~add_local:add_to_frame program;

  let env : env = [FTable (table_of_assoc !top_frame)] in

  let fill_cell name v =
    match List.assoc_opt name !top_frame with
    | Some cell -> cell := v
    | None -> ()
  in

  (* Pass 2: evaluate all declaration bodies in declaration order.  Single
     frame → [fill_local] = [fill_global] = [fill_cell]. *)
  let impl_acc : (string, (int * value) list) Hashtbl.t = Hashtbl.create 16 in
  let fundef_acc : (string, value list) Hashtbl.t = Hashtbl.create 16 in
  let deferred_zero_params : string list ref = ref [] in

  List.iter
    (eval_decl_into ~env ~fill_local:fill_cell ~fill_global:fill_cell
       ~impl_acc ~fundef_acc ~deferred:deferred_zero_params)
    program;

  (* Force all deferred zero-param thunks in source order now that every DImpl
     has been installed.  Transitive thunk dependencies resolve automatically
     via the memoising lookup. *)
  List.iter (fun name -> ignore (lookup env name))
    (List.rev !deferred_zero_params);

  List.map (fun (k, cell) -> (k, !cell)) !top_frame

(* ── Evaluate a multi-module program with per-module name scoping (Phase 110) ─
   The flat [eval_program] merges every module into one by-name frame, so two
   modules' same-named top-level functions (e.g. map's `singleton k v` and
   array's `singleton x`) coalesce into one VMulti and mis-dispatch.  This entry
   point instead evaluates each module in its own frame chained over a shared
   global frame, mirroring typecheck's per-module scoping:

     module M's env = [ M_local ; M_imports ; global ]

   • global    — primitives, prelude, all data constructors, and every interface
                 method/impl (one coherent VMulti per method across all modules).
   • M_local   — M's own top-level DFunDef/DLetGroup bindings (the names that
                 collide across modules; isolation lives here).
   • M_imports — names M brought in via `use`, bound to the *exporting* module's
                 actual cells (shared refs, so forward/thunk references resolve).

   [modules] is the loader/marked output in dependency-first topo order (root
   last), each program already Method_marker-marked.  Returns the root module's
   top-level bindings (so `main` / doctest `__dt_i__` names are found). *)
(* Returns both the root module's local bindings (for `main` / doctest `__dt_i__`
   lookup) and the root's *full* flattened environment — local ∪ imports ∪ global
   (prelude, primitives, interface dispatch).  The prop phase (Phase 126) needs
   the full env because it evaluates each prop body *after* this returns, against
   a single frame, so imported names and prelude operators must be present. *)
let eval_modules_ex (modules : (string * string * Ast.program) list)
  : (string * value) list * (string * value) list =
  (* 1. Dict-pass the marked prelude and each module.  Dict_pass adds leading
     dict *parameters* to a constrained function's *definition*, keyed by name —
     the arity coming from the routed call sites (`collect_arities`).  Doing this
     over one *joint* tree conflates two modules that define the same name with
     different constraint arities: a `Num`-constrained `emit` in module A forces
     dict params onto an unrelated, *unconstrained* `emit` in module B, whose own
     call sites then under-apply it — silently returning a partial closure that
     is never run (Phase 134: an `<IO>` helper called from a `match` arm produced
     no output).  Fix: scope each module's arity table to the references that can
     actually resolve to *its* definitions — the module's own decls plus the
     decls of its (transitive) importers, where the external call sites of its
     exported constrained functions live.  A private constrained function (only
     referenced inside its own module, like the lexer's `emit`) is covered by the
     own-decls part; a public one referenced only by importers (like a `mk : Tag a
     => …`) is covered by the importer part.  The prelude is imported by every
     module, so it keeps the full joint scope. *)
  (* Phase 151 / Gap G: rewrite stamped comparison EBinOps into method apps on
     every typechecked tree before dict-param insertion, mirroring Dict_pass.run
     (the single-file path).  Primitive / unstamped operands stay literal EBinOp. *)
  let prelude = Dict_pass.rewrite_binops Method_marker.marked_prelude in
  let modules = List.map (fun (mid, fp, p) -> (mid, fp, Dict_pass.rewrite_binops p)) modules in
  let all_module_decls = List.concat_map (fun (_, _, p) -> p) modules in

  (* Module id → the module ids it imports directly (mirrors build_imports'
     path→module-id mapping used for value imports below). *)
  let imports_of = Hashtbl.create 16 in
  List.iter (fun (mid, _, p) ->
    let direct =
      List.filter_map (fun d -> match Ast.inner_decl d with
        | DUse (_, path) ->
          Some (match path with
            | UseName ns ->
              if List.length ns > 1
              then String.concat "." (List.rev (List.tl (List.rev ns)))
              else List.hd ns
            | UseGroup (ns, _) | UseWild ns | UseAlias (ns, _) ->
              String.concat "." ns)
        | _ -> None) p
    in
    Hashtbl.replace imports_of mid direct) modules;
  (* Transitive dependency set of [mid] (the module ids it imports, directly or
     through those imports). *)
  let rec add_deps acc mid =
    List.fold_left (fun acc dep ->
      if List.mem dep acc then acc else add_deps (dep :: acc) dep)
      acc
      (match Hashtbl.find_opt imports_of mid with Some xs -> xs | None -> [])
  in

  (* Prelude: full joint scope (every module imports it). *)
  let prelude_arities = Dict_pass.collect_arities (prelude @ all_module_decls) in
  let prelude' = List.map (Dict_pass.run_decl prelude_arities) prelude in
  (* Each module: scope = its own decls ∪ the decls of its transitive importers. *)
  let modules' =
    List.map (fun (mid, fp, p) ->
      let importer_decls =
        List.concat_map (fun (j, _, pj) ->
          if j <> mid && List.mem mid (add_deps [] j) then pj else [])
          modules in
      let arities = Dict_pass.collect_arities (p @ importer_decls) in
      (mid, fp, List.map (Dict_pass.run_decl arities) p))
      modules
  in

  (* 2. Build the shared global frame: primitives, ctors, interface dispatch +
     defaults, impls, and the evaluated prelude. *)
  let global_frame : (string * value ref) list ref = ref [] in
  let add_global name v = global_frame := (name, ref v) :: !global_frame in
  add_global "True"  (VBool true);
  add_global "False" (VBool false);
  List.iter (fun (name, v) -> add_global name v) (List.rev primitives);

  Hashtbl.clear ctor_to_type;
  Hashtbl.clear ctor_field_order;
  Hashtbl.clear arbitrary_registry;
  Hashtbl.clear shrink_registry;
  Hashtbl.clear iface_dispatch;
  let all_decls = prelude' @ List.concat_map (fun (_, _, p) -> p) modules' in
  collect_ctors_and_dispatch all_decls;

  (* Pre-allocate global cells.  Prelude names are all global (its DFunDef/
     DLetGroup too); for modules, only the *global* names (ctors, impl methods,
     interface defaults) are allocated here — each module's local DFunDef/
     DLetGroup cells are allocated per-module in Phase B. *)
  let noop _ _ = () in
  prealloc_cells ~add_global ~add_local:add_global prelude';
  List.iter (fun (_, _, p) -> prealloc_cells ~add_global ~add_local:noop p) modules';

  let fill_global name v =
    match List.assoc_opt name !global_frame with
    | Some cell -> cell := v
    | None -> ()
  in
  (* impl_acc is SHARED across prelude + every module so each interface method
     coalesces into one coherent VMulti.  fundef accumulators are per-context so
     same-named top-level functions stay isolated. *)
  let impl_acc : (string, (int * value) list) Hashtbl.t = Hashtbl.create 64 in

  (* Evaluate the prelude into the global frame.  The global frame's key set is
     frozen after prealloc above (Phase B only fills existing cells, never adds
     keys), so snapshot it into one shared Hashtbl reused by every module's
     [m_env] below — the refs are shared, so later fills remain visible. *)
  let global_table = table_of_assoc !global_frame in
  let global_env : env = [FTable global_table] in
  let prelude_fundef_acc : (string, value list) Hashtbl.t = Hashtbl.create 64 in
  let prelude_deferred : string list ref = ref [] in
  List.iter
    (eval_decl_into ~env:global_env ~fill_local:fill_global ~fill_global
       ~impl_acc ~fundef_acc:prelude_fundef_acc ~deferred:prelude_deferred)
    prelude';
  (* NB: the prelude's deferred thunks are forced *after* Phase B (below), not
     here — see the Phase 125 note at the force site.  A point-free prelude
     wrapper like `sum = fold (+) 0` (Phase 89 `relaxed`, arg-tag-dispatched)
     forced here would memoise the prelude-only `fold` VMulti before the user
     modules' impls (e.g. `impl Foldable Array`) are installed, so `sum` over an
     imported container would later find no matching impl. *)

  (* 3. Phase B: evaluate each module in topo order in its own frame. *)
  (* mod_id → that module's public top-level (name, cell) exports. *)
  let module_exports : (string, (string * value ref) list) Hashtbl.t =
    Hashtbl.create 16 in

  (* The value names a DUse pulls in, bound to the *exporting* module's cells.
     Each entry is tagged with whether the use is `pub` (so it re-exports).
     Mirrors typecheck_module's use_schemes / resolve's import resolution; names
     that resolve to a ctor / global (not in the source's value exports) are
     dropped here and reached through the env tail instead. *)
  let build_imports decls : (string * value ref * bool) list =
    let acc = ref [] in
    List.iter (fun d -> match Ast.inner_decl d with
      | DUse (is_pub, path) ->
        let mod_id_ref = match path with
          | UseName ns ->
            if List.length ns > 1
            then String.concat "." (List.rev (List.tl (List.rev ns)))
            else List.hd ns
          | UseGroup (ns, _) | UseWild ns | UseAlias (ns, _) ->
            String.concat "." ns
        in
        (match Hashtbl.find_opt module_exports mod_id_ref with
         | None -> ()
         | Some exports ->
           let imported = match path with
             | UseName ns ->
               if List.length ns > 1 then [List.hd (List.rev ns)] else []
             | UseGroup (_, ms) -> List.map fst ms
             | UseWild _ -> List.map fst exports
             | UseAlias _ -> []
           in
           List.iter (fun n ->
             match List.assoc_opt n exports with
             | Some cell -> acc := (n, cell, is_pub) :: !acc
             | None -> ()
           ) imported)
      | _ -> ()
    ) decls;
    !acc
  in

  (* This module's exported value names paired with their cells.  Resolve keys
     a value export off the `export`ed *signature* (DTypeSig), the `export`ed
     definition, or a `pub use` re-export — not off the DFunDef alone (whose
     `is_pub` is false even when its signature is exported).  Interface-method /
     extern names resolve globally, so a name with no local/imported cell is
     simply omitted (it reaches importers through the env tail). *)
  let collect_pub_exports decls local_frame imports : (string * value ref) list =
    let acc = ref [] in
    let add_name n =
      match List.assoc_opt n local_frame with
      | Some cell -> acc := (n, cell) :: !acc
      | None ->
        (match List.find_opt (fun (m, _, _) -> m = n) imports with
         | Some (_, cell, _) -> acc := (n, cell) :: !acc
         | None -> ())
    in
    List.iter (fun d -> match Ast.inner_decl d with
      | DTypeSig (true, n, _) -> add_name n
      | DExtern (true, n, _)  -> add_name n
      | DFunDef (true, n, _, _) -> add_name n
      | DLetGroup (true, bs)  -> List.iter (fun (n, _) -> add_name n) bs
      | DUse (true, _) -> ()  (* handled via re-exported imports below *)
      | _ -> ()
    ) decls;
    (* `pub use` re-exports: names imported with a public use are visible to
       this module's importers too. *)
    List.iter (fun (n, cell, is_pub) ->
      if is_pub then acc := (n, cell) :: !acc) imports;
    !acc
  in

  let last_local = ref [] in
  (* Root module's full env, captured as *cells* (not values) so the deferred-
     prelude force below is reflected; dereferenced after the loop. *)
  let root_full_cells = ref [] in
  List.iter (fun (mid, _fp, decls) ->
    (* Pre-allocate this module's local DFunDef/DLetGroup cells. *)
    let local_frame : (string * value ref) list ref = ref [] in
    let add_local name v = local_frame := (name, ref v) :: !local_frame in
    prealloc_cells ~add_global:noop ~add_local decls;

    let imports = build_imports decls in
    let import_frame = List.map (fun (n, cell, _) -> (n, cell)) imports in
    let m_env : env = [ FTable (table_of_assoc !local_frame);
                        FTable (table_of_assoc import_frame);
                        FTable global_table ] in
    let fill_local name v =
      match List.assoc_opt name !local_frame with
      | Some cell -> cell := v
      | None -> ()
    in
    let m_fundef_acc : (string, value list) Hashtbl.t = Hashtbl.create 16 in
    let m_deferred : string list ref = ref [] in
    List.iter
      (eval_decl_into ~env:m_env ~fill_local ~fill_global
         ~impl_acc ~fundef_acc:m_fundef_acc ~deferred:m_deferred)
      decls;
    List.iter (fun name -> ignore (lookup m_env name))
      (List.rev !m_deferred);

    Hashtbl.replace module_exports mid
      (collect_pub_exports decls !local_frame imports);
    last_local := List.map (fun (k, cell) -> (k, !cell)) !local_frame;
    (* local ∪ imports ∪ global, in shadowing order (local wins on List.assoc). *)
    root_full_cells := List.concat_map frame_assoc m_env
  ) modules';

  (* Phase 125: force the prelude's deferred thunks only now that *every*
     module's impls have been installed into the shared `impl_acc` / global
     interface-method cells — mirroring the flat `eval_program`, which forces
     deferred thunks only after all DImpls are in place.  Forcing earlier
     (right after the prelude phase) memoised a point-free `relaxed` wrapper
     such as `sum = fold (+) 0` against the prelude-only `fold` VMulti, so
     `sum (fromList [...])` over an imported `Foldable Array` later dispatched
     to no impl.  Per-module deferred thunks were already forced inside the
     loop above: topo order guarantees a module's wrappers only need impls from
     itself, earlier modules, and the prelude — all installed by then.  Only the
     prelude is special, because it can reference impls defined in *later*
     modules. *)
  List.iter (fun name -> ignore (lookup global_env name))
    (List.rev !prelude_deferred);

  (!last_local, List.map (fun (k, cell) -> (k, !cell)) !root_full_cells)

let eval_modules (modules : (string * string * Ast.program) list)
  : (string * value) list =
  fst (eval_modules_ex modules)

(* Full flattened root-module env (local ∪ imports ∪ global) — see eval_modules_ex. *)
let eval_modules_root_env (modules : (string * string * Ast.program) list)
  : (string * value) list =
  snd (eval_modules_ex modules)

(* ── REPL incremental interface ─────────────────────────────────────────── *)

type repl_state = {
  top_frame : (string * value ref) list ref;
  eval_env  : env ref;
}

let rec eval_repl_decl (rs : repl_state) (decl : decl) : unit =
  let add name v = rs.top_frame := (name, ref v) :: !(rs.top_frame) in
  let fill name v =
    match List.assoc_opt name !(rs.top_frame) with
    | Some cell -> cell := v
    | None -> add name v
  in
  rs.eval_env := [FList !(rs.top_frame)];
  (match decl with
   | DData (_, type_name, _, variants, _) ->
     List.iter (fun v ->
       let arity = match v.con_payload with
         | ConPos tys   -> List.length tys
         | ConNamed fls -> List.length fls
       in
       add v.con_name (make_ctor v.con_name arity);
       Hashtbl.replace ctor_to_type v.con_name type_name;
       (match v.con_payload with
        | ConNamed fields ->
          Hashtbl.replace ctor_field_order v.con_name
            (List.map (fun f -> f.field_name) fields)
        | ConPos _ -> ())
     ) variants
   | DFunDef (_, name, pats, body) ->
     add name VUnit;
     rs.eval_env := [FList !(rs.top_frame)];
     let v = wrap_match_errors (fun () ->
       if pats = [] then eval !(rs.eval_env) body
       else VClosure (!(rs.eval_env), pats, body)) in
     (* Multi-clause `f pat1 = ...` / `f pat2 = ...` entered separately at the
        REPL should dispatch via VMulti, mirroring eval_program. A value
        binding (pats = []) replaces any prior binding. *)
     let merged =
       if pats = [] then v
       else match List.assoc_opt name !(rs.top_frame) with
         | Some cell ->
           (match !cell with
            | VMulti vs        -> VMulti (vs @ [v])
            | VClosure _ as c  -> VMulti [c; v]
            | _                -> v)
         | None -> v
     in
     fill name merged
   | DImpl { iface_name; type_args; methods; impl_name; _ } ->
     let score = tyvars_in_args type_args in
     (* Reserve slots for overridable impl methods before evaluating bodies. *)
     List.iter (fun (name, _, _) ->
       match List.assoc_opt name !(rs.top_frame) with
       | None -> add name VUnit
       | Some _ -> ()
     ) methods;
     rs.eval_env := [FList !(rs.top_frame)];
     let rec head_tycon = function
       | Ast.TyCon n      -> Some n
       | Ast.TyApp (a, _) -> head_tycon a
       | Ast.TyConstrained (_, t) | Ast.TyEffect (_, _, t) -> head_tycon t
       | Ast.TyTuple _    -> Some "__tuple__"
       | _ -> None
     in
     let impl_type_tag = match type_args with
       | t :: _ -> head_tycon t
       | [] -> None
     in
     let impl_key = Ast.impl_key ~iface:iface_name ~type_args ~name:impl_name in
     List.iter (fun (name, pats, body) ->
       begin
         let new_v = impl_method_value !(rs.eval_env) iface_name name pats body in
         let positions =
          List.map ((+) (leading_dict_params pats))
            (lookup_dispatch_positions iface_name name) in
         let typed_v = match impl_type_tag with
           | Some t -> VTypedImpl (t, impl_key, positions, 0, new_v)
           | None   -> new_v
         in
         let tagged_v = match impl_name with
           | Some n -> VNamedImpl (n, typed_v)
           | None   -> typed_v
         in
         (* Merge with existing binding: extend VMulti (score-sorted) or set fresh. *)
         let merged =
           match List.assoc_opt name !(rs.top_frame) with
           | Some cell ->
             let existing = match !cell with
               | VMulti vs -> List.map (fun v -> (0, v)) vs  (* existing scores unknown; keep order *)
               | VUnit     -> []
               | old_v     -> [(0, old_v)]
             in
             let updated = existing @ [(score, tagged_v)] in
             let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
             VMulti (List.map snd sorted)
           | None -> tagged_v
         in
         fill name merged
       end
     ) methods
   | DNewtype (_, _, _, con, _, _) ->
     add con (make_ctor con 1)
   | DInterface { iface_name; type_params; methods; _ } ->
     record_iface_dispatch iface_name type_params methods;
     let score = List.length type_params in
     List.iter (fun m ->
       match m.method_default with
       | None -> ()
       | Some (pats, body) ->
         let name = m.method_name in
         (match List.assoc_opt name !(rs.top_frame) with
          | None -> add name VUnit
          | Some _ -> ());
         rs.eval_env := [FList !(rs.top_frame)];
         let new_v = if pats = [] then wrap_match_errors (fun () -> eval !(rs.eval_env) body)
                     else VClosure (!(rs.eval_env), pats, body) in
         let merged =
           match List.assoc_opt name !(rs.top_frame) with
           | Some cell ->
             let existing = match !cell with
               | VMulti vs -> List.map (fun v -> (0, v)) vs
               | VUnit     -> []
               | old_v     -> [(0, old_v)]
             in
             let updated = existing @ [(score, new_v)] in
             let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
             VMulti (List.map snd sorted)
           | None -> new_v
         in
         fill name merged
     ) methods
   | DLetGroup (_, bindings) ->
     (* Pre-allocate VUnit cells so each clause body can reference any
        group name; then fill them with closures or evaluated values. *)
     List.iter (fun (name, _) ->
       (match List.assoc_opt name !(rs.top_frame) with
        | None   -> add name VUnit
        | Some _ -> ())
     ) bindings;
     rs.eval_env := [FList !(rs.top_frame)];
     List.iter (fun (name, clauses) ->
       let closures = List.map (fun (pats, rhs) ->
         if pats = [] then wrap_match_errors (fun () -> eval !(rs.eval_env) rhs)
         else VClosure (!(rs.eval_env), pats, rhs)) clauses in
       let v = match closures with
         | [v] -> v
         | many -> VMulti many
       in
       fill name v
     ) bindings
   | DRecord _ | DTypeSig _ | DExtern _ | DUse _ | DTypeAlias _ | DProp _
   | DTest _ | DBench _ | DEffect _ -> ()
   | DAttrib (_, d) ->
     eval_repl_decl rs d)

let eval_repl_expr (rs : repl_state) (e : expr) : value =
  rs.eval_env := [FList !(rs.top_frame)];
  wrap_match_errors (fun () -> eval !(rs.eval_env) e)

let make_repl_eval_state ?(prelude = Prelude.program) () : repl_state =
  (* Seed from a full eval_program run over the prelude: that gives us the
     prelude's data types, interface methods, and impl bodies bound after
     eval_program's two-pass forward-reference handling, which the strictly
     incremental eval_repl_decl couldn't do on its own.  [prelude] defaults to
     the raw prelude; the repl driver passes the *marked + dict-passed* prelude
     (Method_marker.marked_prelude run through Dict_pass) so its constrained
     functions like `when`/`unless` carry dict params matching the EDictApp call
     sites the repl marks in user input (Phase 69.x-c).  Eval'd with
     [~prelude:false] so it isn't re-prepended.
     True/False are pre-seeded separately because they're lexed as BOOL
     literals — they have no declaration in stdlib/core.mdk. *)
  let initial_bindings = eval_program ~prelude:false prelude in
  let top_frame : (string * value ref) list ref =
    ref (List.map (fun (k, v) -> (k, ref v)) initial_bindings) in
  let add name v = top_frame := (name, ref v) :: !top_frame in
  add "True"  (VBool true);
  add "False" (VBool false);
  let eval_env = ref [FList !top_frame] in
  { top_frame; eval_env }
