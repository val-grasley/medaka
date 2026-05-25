; ── Keywords ─────────────────────────────────────────────────────────

[
  "let" "in"
  "if" "then" "else"
  "match"
  "do"
  "where" "of" "as"
] @keyword

; Type / structure keywords
["data" "record" "interface" "impl" "default"] @keyword.type

; Visibility & linkage
["pub" "extern"] @keyword.modifier

; Import
"use" @keyword.import

; The `mut` qualifier
"mut" @keyword.modifier

; ── Comments ─────────────────────────────────────────────────────────
(comment) @comment

; ── String / char literals ────────────────────────────────────────────
(string_lit) @string
(char_lit)   @string.special.symbol

; ── Numeric literals ──────────────────────────────────────────────────
(float_lit) @number.float
(int_lit)   @number

; ── Boolean / unit literals ───────────────────────────────────────────
(bool_lit) @constant.builtin

; ── Type constructors (uppercase identifiers) ─────────────────────────
; These appear in type position, constructor patterns, and expressions.
(upper) @type.constructor

; ── Declaration names ────────────────────────────────────────────────
(type_sig      name: (ident)) @function
(fun_def       name: (ident)) @function
(extern_decl   name: (ident)) @function
(impl_method   name: (ident)) @function
(iface_member  name: (ident)) @function

; Type declaration names
(data_decl       name: (upper)) @type
(record_decl     name: (upper)) @type
(interface_decl  name: (upper)) @type

; ── Record fields ─────────────────────────────────────────────────────
(record_field_decl name: (ident)) @variable.member
(record_field_expr name: (ident)) @variable.member
(field_access      field: (ident)) @variable.member

; ── Pattern variables ────────────────────────────────────────────────
(pat_atom var: (ident)) @variable

; Wildcard
"_" @variable.builtin

; ── Effect annotations: <IO> or <IO, Mut> ────────────────────────────
(effect_type (upper) @type.builtin)

; ── Impl disambiguation: @Name ───────────────────────────────────────
(impl_selection "@" @operator name: (upper) @type.builtin)

; ── Operators ────────────────────────────────────────────────────────
(binary_expr
  [ "|>" ">>" "<<" "||" "&&" "==" "!=" "<" ">" "<=" ">="
    "::" "++" "+" "-" "*" "/" ] @operator)

(binary_expr op: (backtick_ident) @operator)
(unary_expr ["-" "!"] @operator)

["=>" "->" "<-" "=" ":"] @operator
"|" @operator

; Pipe in match arms
(match_arm "=>" @operator)
(do_bind   "<-" @operator)
(type_sig  ":" @operator)

; ── Brackets ─────────────────────────────────────────────────────────
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["[|" "|]"] @punctuation.bracket

; ── Separators ───────────────────────────────────────────────────────
"," @punctuation.delimiter
"." @punctuation.delimiter

; ── Use paths ────────────────────────────────────────────────────────
(use_path (use_qual) @namespace)
