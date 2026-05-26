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

; Superconstraint keyword
"requires" @keyword.type

; Deriving keyword
"deriving" @keyword.type

; Visibility & linkage
["export" "extern"] @keyword.modifier

; Import
"import" @keyword.import

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

; ── Type variables (lowercase in type position) ───────────────────────
; Match ident inside ty_atom — these are type variables, not value bindings.
(ty_atom (ident)) @type.parameter

; Type params in declaration headers
(data_decl      type_param: (ident)) @type.parameter
(record_decl    type_param: (ident)) @type.parameter
(interface_decl type_param: (ident)) @type.parameter

; ── Type constructors (uppercase in type position) ────────────────────
(ty_atom (upper)) @type
(ty_app  constructor: (ty_atom (upper))) @type

; ── Interface / typeclass names ───────────────────────────────────────
; Declaration name
(interface_decl name: (upper)) @module

; Usage in impl and superconstraint
(impl_decl          iface: (upper)) @module
(iface_super_entry  name:  (upper)) @module
(impl_requires_entry iface: (upper)) @module

; Deriving list
(deriving_clause iface: (upper)) @module

; ── Type declaration names ────────────────────────────────────────────
(data_decl   name: (upper)) @type.definition
(record_decl name: (upper)) @type.definition

; ── Data constructors ─────────────────────────────────────────────────
; In variant declarations
(data_variant      name: (upper)) @constructor
(data_variant_line name: (upper)) @constructor

; In patterns
(pat_app  constructor: (upper)) @constructor
(pat_atom constructor: (upper)) @constructor

; Default: remaining uppercase nodes in expression position
(upper) @constructor

; ── Declaration names ────────────────────────────────────────────────
(type_sig      name: (ident)) @function
(fun_def       name: (ident)) @function
(extern_decl   name: (ident)) @function
(extern_decl   name: (upper)) @function
(impl_method   name: (ident)) @function
(iface_member  name: (ident)) @function

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
(impl_selection "@" @operator name: (upper) @module)

; ── Operators ────────────────────────────────────────────────────────
(binary_expr
  [ "|>" ">>" "<<" "||" "&&" "==" "!=" "<" ">" "<=" ">="
    "::" "++" "<>" "+" "-" "*" "/" "%" ] @operator)

(binary_expr op: (backtick_ident) @operator)
(unary_expr ["-" "!"] @operator)

["=>" "->" "<-" "=" ":"] @operator
"|" @operator

; Pipe in match arms
(match_arm "=>" @operator)
(do_bind   "<-" @operator)
(type_sig  ":" @operator)

; Map literal fat-arrow
(map_entry "=>" @operator)

; ── Brackets ─────────────────────────────────────────────────────────
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["[|" "|]"] @punctuation.bracket

; ── Separators ───────────────────────────────────────────────────────
"," @punctuation.delimiter
"." @punctuation.delimiter

; ── Import paths ─────────────────────────────────────────────────────
(import_path (import_qual) @namespace)
