/**
 * Tree-sitter grammar for Medaka.
 *
 * Indentation is handled by an external scanner (src/scanner.c) that emits
 * _newline / _indent / _dedent as structural tokens.
 *
 * Rules prefixed with _ are "hidden" (transparent) nodes — they don't appear
 * in the concrete syntax tree and their children surface directly in the
 * parent node.  This keeps the CST clean for editors and query writers.
 */

module.exports = grammar({
  name: 'medaka',

  /* External tokens — order must match the TokenType enum in scanner.c */
  externals: $ => [
    $._newline,
    $._indent,
    $._dedent,
    $._interp_open,   /* "prefix\{  — opening quote through first \{  */
    $._interp_mid,    /* }middle\{  — closing } through next \{        */
    $._interp_end,    /* }suffix"   — closing } through closing quote  */
  ],

  /* Whitespace (including newlines) and comments are extras — skipped between
   * all tokens.  The external scanner intercepts '\n' first whenever a
   * structural token (NEWLINE / INDENT / DEDENT) is valid in the current
   * parse state and consumes it as part of that token.  When no structural
   * token is valid (e.g. blank lines between top-level declarations), the
   * regular lexer skips the '\n' via this extras rule. */
  extras: $ => [
    /[ \t\n\r]+/,
    $.comment,
  ],

  /* GLR conflicts: parser uses all interpretations simultaneously */
  conflicts: $ => [
    /* `Upper {` — record_create vs map_lit vs set_lit vs record_pat vs expr */
    [$._expr, $.pat_atom, $.record_create, $.map_lit, $.set_lit],
    [$._expr, $.record_create, $.map_lit, $.set_lit],
    [$._expr, $.pat_atom, $.record_create],
    [$._expr, $.record_create],
    [$.record_create, $.map_lit],
    [$.record_create, $.set_lit],
    [$.map_lit, $.set_lit],
    [$.pat_atom, $.map_lit, $.set_lit],
    /* lambda vs application: `f x =>` */
    [$.lambda_expr, $.expr_app],
    /* type_sig and fun_def both start with ident */
    [$.type_sig, $.fun_def],
    /* iface_member: method sig vs default impl */
    [$.iface_member],
    /* pat_atom vs expr in do-blocks (`ident ::` etc.) */
    [$._expr, $.pat_atom],
    /* do_bind (pat <- expr) vs do_stmt_expr (expr) */
    [$.do_bind, $.do_stmt_expr],
    /* do_assign (ident = expr) vs do_stmt_expr (expr = ...) */
    [$.do_assign, $.do_stmt_expr],
    /* binary_expr vs expr_app on right-hand side */
    [$.binary_expr, $.expr_app],
    /* pat_app vs expr_app for constructor application */
    [$.pat_app, $.expr_app],
    /* pat_app vs _expr for patterns in do-binds */
    [$.pat_app, $._expr],
    /* list pattern vs list expression */
    [$.pat_atom, $.list_expr],
    /* unit pat `()` vs unit_expr `()` */
    [$.pat_atom, $.unit_expr],
    /* pat_as vs pat_atom/expr: ident starts all three, @ disambiguates */
    [$.pat_as, $.pat_atom],
    [$.pat_as, $._expr],
    /* list_comp vs list_expr: both start with [expr, | disambiguates */
    [$.list_comp, $.list_expr],
    /* lc_qual guard form is just _expr — needs GLR to try both */
    [$.lc_qual, $._expr],
    /* record_pat_field: ident vs ident = pat; pun form same start as _expr */
    [$.record_pat_field],
    [$.record_pat_field, $._expr],
    /* where_body starts with _expr; needs lookahead for `where` keyword */
    [$.where_body, $._expr],
    /* record pattern in pat_atom vs record_create in _expr */
    [$.pat_atom, $.record_create],
    /* guard_arm `|` vs data_variant_line `|` in block context */
    [$.type_sig, $.fun_def, $.guard_arm],
  ],

  word: $ => $.ident,

  rules: {

    /* ═══════════════════════════════════════════════════
     * Source file
     * ═══════════════════════════════════════════════════ */

    source_file: $ => seq(
      repeat($._newline),
      repeat($._declaration),
    ),

    /* _declaration is transparent — its child appears directly in source_file */
    _declaration: $ => choice(
      $.type_sig,
      $.fun_def,
      $.data_decl,
      $.record_decl,
      $.type_alias_decl,
      $.newtype_decl,
      $.interface_decl,
      $.impl_decl,
      $.import_decl,
      $.extern_decl,
    ),

    /* export on its own line (Idris style) or inline before a declaration */
    _export_marker: $ => choice(
      seq('export', $._newline),
      'export',
    ),

    /* ═══════════════════════════════════════════════════
     * Terminals
     * ═══════════════════════════════════════════════════ */

    ident:          $ => /[a-z_][a-zA-Z0-9_']*/,
    upper:          $ => /[A-Z][a-zA-Z0-9_']*/,
    backtick_ident: $ => /`[a-z_][a-zA-Z0-9_']*`/,

    /* float before int so "3.14" matches float, not "3" then ".14" */
    float_lit:  $ => /[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?/,
    int_lit:    $ => /[0-9]+/,
    /* \\[^{] matches any escape except \{ so interp_string wins for "...\{...}" */
    string_lit: $ => /"([^"\\]|\\[^{])*"/,
    char_lit:   $ => /'([^'\\]|\\.)'/,
    bool_lit:   $ => choice('True', 'False'),

    comment: $ => /--[^\n]*/,

    literal: $ => choice(
      $.float_lit,
      $.int_lit,
      $.string_lit,
      $.char_lit,
      $.bool_lit,
    ),

    /* ═══════════════════════════════════════════════════
     * Types
     * ═══════════════════════════════════════════════════ */

    /* _type_expr is transparent — callers get ty_fun / ty_app / ty_atom */
    _type_expr: $ => choice(
      $.ty_fun,
      $.ty_app,
      $.ty_atom,
    ),

    ty_fun: $ => prec.right(1, seq(
      field('arg', choice($.ty_app, $.ty_atom)),
      '->',
      field('result', choice($.ty_fun, $.ty_app, $.ty_atom)),
    )),

    /* Flat type application: `List Int` → (ty_app (ty_atom List) (ty_atom Int)) */
    ty_app: $ => prec.left(2, seq(
      field('constructor', $.ty_atom),
      repeat1(field('arg', $.ty_atom)),
    )),

    ty_atom: $ => choice(
      $.upper,
      $.ident,
      seq('(', $._type_expr, ')'),
      /* Tuple type: (a, b) */
      seq('(', $._type_expr, ',', $._type_expr, repeat(seq(',', $._type_expr)), ')'),
      $.effect_type,
    ),

    /* <IO> String  or  <IO, Mut> String */
    effect_type: $ => seq(
      '<',
      field('effect', $.upper),
      repeat(seq(',', field('effect', $.upper))),
      '>',
      field('type', $.ty_atom),
    ),

    /* ═══════════════════════════════════════════════════
     * Patterns
     * ═══════════════════════════════════════════════════ */

    pat: $ => choice(
      $.pat_as,
      $.pat_cons,
      $.pat_app,
      $.pat_atom,
    ),

    /* name @ pattern — alias binding */
    pat_as: $ => seq(
      field('name', $.ident),
      '@',
      field('pat', $.pat),
    ),

    pat_cons: $ => prec.right(6, seq(
      field('head', choice($.pat_app, $.pat_atom)),
      '::',
      field('tail', $.pat),
    )),

    /* Constructor application: Some x  or  Ok (a, b) */
    pat_app: $ => prec.left(11, seq(
      field('constructor', $.upper),
      repeat1(field('arg', $.pat_atom)),
    )),

    pat_atom: $ => choice(
      field('var', $.ident),
      '_',
      field('constructor', $.upper),
      $.literal,
      seq('(', ')'),
      seq('(', $.pat, ')'),
      seq('(', $.pat, ',', $.pat, repeat(seq(',', $.pat)), ')'),
      seq('[', ']'),
      seq('[', $.pat, repeat(seq(',', $.pat)), ']'),
      /* Record pattern: Point { x, y }  or  Point { x = px, ... } */
      seq(field('type', $.upper), '{', $.record_pat_fields, '}'),
    ),

    /* Record pattern fields: supports puns (field), bindings (field = pat), and rest (...) */
    record_pat_fields: $ => choice(
      '...',
      seq(
        $.record_pat_field,
        repeat(seq(',', $.record_pat_field)),
        optional(seq(',', '...')),
      ),
    ),

    /* A single field in a record pattern */
    record_pat_field: $ => choice(
      seq(field('name', $.ident), '=', field('pat', $.pat)),
      field('name', $.ident),
    ),

    /* ═══════════════════════════════════════════════════
     * Declarations
     * ═══════════════════════════════════════════════════ */

    /* f : Int -> Int */
    type_sig: $ => seq(
      optional($._export_marker),
      field('name', $.ident),
      ':',
      field('type', $._type_expr),
      $._newline,
    ),

    /* export? name pat* = body
     * export? name pat*\n  | guard = body\n  ... */
    fun_def: $ => seq(
      optional($._export_marker),
      field('name', $.ident),
      repeat(field('param', $.pat_atom)),
      choice(
        seq('=', field('body', $._fun_body)),
        seq($._indent, repeat1($.guard_arm), $._dedent),
      ),
      $._newline,
    ),

    /* Guard arm:  | condition = body */
    guard_arm: $ => seq(
      '|',
      field('guard', $._expr),
      '=',
      field('body', $._fun_body),
      $._newline,
    ),

    /* _fun_body is transparent: callers see the concrete expression directly */
    _fun_body: $ => choice(
      $._expr,
      /* expr where\n  binding*  — local where-clause */
      $.where_body,
      /* Indented-stmts form (desugars to do-block, no `do` keyword) */
      $.do_body,
    ),

    /* expr\n  where\n    bindings */
    where_body: $ => seq(
      field('expr', $._expr),
      'where',
      $._indent,
      repeat1($.where_binding),
      $._dedent,
    ),

    /* A single binding in a where clause: name params = body */
    where_binding: $ => seq(
      field('name', $.ident),
      repeat(field('param', $.pat_atom)),
      '=',
      field('body', $._fun_body),
      $._newline,
    ),

    /* Indented statement block without the `do` keyword — equivalent to do-block */
    do_body: $ => seq(
      $._indent,
      repeat1($.stmt),
      $._dedent,
    ),

    /* data Bool = True | False
     * data Option a = Some a | None
     * data Shape
     *   | Circle Float           */
    data_decl: $ => seq(
      optional($._export_marker),
      'data',
      field('name', $.upper),
      repeat(field('type_param', $.ident)),
      choice(
        seq('=', $.data_variant, repeat(seq('|', $.data_variant)),
            optional($.deriving_clause), $._newline),
        seq($._indent, repeat1($.data_variant_line), $._dedent,
            optional($.deriving_clause), $._newline),
      ),
    ),

    deriving_clause: $ => seq(
      'deriving',
      '(',
      field('iface', $.upper),
      repeat(seq(',', field('iface', $.upper))),
      ')',
    ),

    data_variant: $ => seq(
      field('name', $.upper),
      repeat(field('arg', $.ty_atom)),
    ),

    data_variant_line: $ => seq(
      '|',
      field('name', $.upper),
      repeat(field('arg', $.ty_atom)),
      $._newline,
    ),

    /* record Person
     *   name : String            */
    record_decl: $ => seq(
      optional($._export_marker),
      'record',
      field('name', $.upper),
      repeat(field('type_param', $.ident)),
      $._indent,
      repeat1($.record_field_decl),
      $._dedent,
      optional($.deriving_clause),
      $._newline,
    ),

    record_field_decl: $ => seq(
      field('name', $.ident),
      ':',
      field('type', $._type_expr),
      $._newline,
    ),

    /* type Name = String
     * type Parser a = String -> Option (a, String) */
    type_alias_decl: $ => seq(
      optional($._export_marker),
      'type',
      field('name', $.upper),
      repeat(field('type_param', $.ident)),
      '=',
      field('rhs', $._type_expr),
      $._newline,
    ),

    /* newtype Age = MkAge Int deriving (Show) */
    newtype_decl: $ => seq(
      optional($._export_marker),
      'newtype',
      field('name', $.upper),
      repeat(field('type_param', $.ident)),
      '=',
      field('constructor', $.upper),
      field('type', $.ty_atom),
      optional($.deriving_clause),
      $._newline,
    ),

    /* interface Show a where
     *   show : a -> String       */
    interface_decl: $ => seq(
      optional($._export_marker),
      optional('default'),
      'interface',
      field('name', $.upper),
      repeat(field('type_param', $.ident)),
      optional($.iface_super),
      'where',
      $._indent,
      repeat1($.iface_member),
      $._dedent,
      $._newline,
    ),

    iface_super: $ => seq(
      'requires',
      $.iface_super_entry,
      repeat(seq(',', $.iface_super_entry)),
    ),

    iface_super_entry: $ => seq(
      field('name', $.upper),
      repeat(field('type_param', $.ident)),
    ),

    iface_member: $ => choice(
      seq(field('name', $.ident), ':', $._type_expr, $._newline),
      seq(field('name', $.ident), repeat($.pat_atom), '=', $._fun_body, $._newline),
    ),

    /* impl Show Int where
     *   show n = ...
     * impl myEq of Eq Int where  (named) */
    impl_decl: $ => seq(
      optional($._export_marker),
      optional('default'),
      'impl',
      choice(
        seq(field('impl_name', $.ident), 'of', field('iface', $.upper),
            repeat1(field('type_arg', $.ty_atom)),
            optional($.impl_requires), 'where'),
        seq(field('iface', $.upper), repeat1(field('type_arg', $.ty_atom)),
            optional($.impl_requires), 'where'),
      ),
      $._indent,
      repeat1($.impl_method),
      $._dedent,
      $._newline,
    ),

    impl_requires: $ => seq(
      'requires',
      $.impl_requires_entry,
      repeat(seq(',', $.impl_requires_entry)),
    ),

    impl_requires_entry: $ => seq(
      field('iface', $.upper),
      repeat1(field('type_arg', $.ty_atom)),
    ),

    impl_method: $ => seq(
      field('name', $.ident),
      repeat(field('param', $.pat_atom)),
      '=',
      field('body', $._fun_body),
      $._newline,
    ),

    /* import list.{map, filter}
     * import utils as U
     * export import core.*      */
    import_decl: $ => seq(
      optional('export'),
      'import',
      $.import_path,
      $._newline,
    ),

    import_path: $ => choice(
      seq($.import_qual, '.{', $.ident, repeat(seq(',', $.ident)), '}'),
      seq($.import_qual, '.*'),
      seq($.import_qual, 'as', choice($.upper, $.ident)),
      $.import_qual,
    ),

    import_qual: $ => seq(
      choice($.ident, $.upper),
      repeat(seq('.', choice($.ident, $.upper))),
    ),

    /* extern println : String -> <IO> Unit
     * extern Ref : a -> Ref a            (constructor-style extern, Phase 18) */
    extern_decl: $ => seq(
      optional($._export_marker),
      'extern',
      field('name', choice($.ident, $.upper)),
      ':',
      field('type', $._type_expr),
      $._newline,
    ),

    /* ═══════════════════════════════════════════════════
     * Expressions
     * ═══════════════════════════════════════════════════ */

    /* _expr is transparent — the concrete expression node surfaces directly */
    _expr: $ => choice(
      $.type_annotation,
      $.lambda_expr,
      $.let_expr,
      $.if_expr,
      $.match_expr,
      $.do_expr,
      $.binary_expr,
      $.unary_expr,
      $.expr_app,
      $.field_access,
      $.index_expr,
      $.record_create,
      $.record_update,
      $.map_lit,
      $.set_lit,
      $.operator_section,
      $.impl_selection,
      $.tuple_expr,
      $.list_comp,
      $.list_expr,
      $.array_expr,
      $.interp_string,
      $.literal,
      $.ident,
      $.upper,
      seq('(', $._expr, ')'),
      $.unit_expr,
    ),

    unit_expr: $ => seq('(', ')'),

    type_annotation: $ => prec(-1, seq(
      $._expr, ':', $._type_expr,
    )),

    lambda_expr: $ => prec.right(0, seq(
      field('param', $.pat_atom),
      '=>',
      field('body', $._expr),
    )),

    let_expr: $ => prec.right(0, choice(
      seq('let', 'mut', field('pat', $.pat), '=',
          field('value', $._expr), 'in', field('body', $._expr)),
      seq('let', field('pat', $.pat), '=',
          field('value', $._expr), 'in', field('body', $._expr)),
      seq('let', field('name', $.ident), repeat1(field('param', $.pat_atom)),
          '=', field('value', $._expr), 'in', field('body', $._expr)),
    )),

    if_expr: $ => prec.right(0, seq(
      'if',   field('condition', $._expr),
      'then', field('then', $._expr),
      'else', field('else', $._expr),
    )),

    match_expr: $ => prec.right(0, seq(
      'match',
      field('scrutinee', $._expr),
      $._indent,
      repeat1($.match_arm),
      $._dedent,
    )),

    match_arm: $ => seq(
      field('pattern', $.pat),
      optional(seq('if', field('guard', $._expr))),
      '=>',
      field('body', $._expr),
      optional(seq('where', $._indent, repeat1($.where_binding), $._dedent)),
      $._newline,
    ),

    /* do\n  stmt* */
    do_expr: $ => prec.right(0, seq(
      'do',
      $._indent,
      repeat1($.stmt),
      $._dedent,
    )),

    /* Binary operators — flat rule, Python-style */
    binary_expr: $ => choice(
      prec.left(1,  seq(field('left', $._expr), '|>',  field('right', $._expr))),
      prec.left(2,  seq(field('left', $._expr), '>>',  field('right', $._expr))),
      prec.left(2,  seq(field('left', $._expr), '<<',  field('right', $._expr))),
      prec.left(3,  seq(field('left', $._expr), '||',  field('right', $._expr))),
      prec.left(4,  seq(field('left', $._expr), '&&',  field('right', $._expr))),
      prec.left(5,  seq(field('left', $._expr), '==',  field('right', $._expr))),
      prec.left(5,  seq(field('left', $._expr), '!=',  field('right', $._expr))),
      prec.left(5,  seq(field('left', $._expr), '<',   field('right', $._expr))),
      prec.left(5,  seq(field('left', $._expr), '>',   field('right', $._expr))),
      prec.left(5,  seq(field('left', $._expr), '<=',  field('right', $._expr))),
      prec.left(5,  seq(field('left', $._expr), '>=',  field('right', $._expr))),
      prec.right(6, seq(field('left', $._expr), '::',  field('right', $._expr))),
      prec.left(7,  seq(field('left', $._expr), '++',  field('right', $._expr))),
      prec.left(7,  seq(field('left', $._expr), '<>',  field('right', $._expr))),
      prec.left(8,  seq(field('left', $._expr), '+',   field('right', $._expr))),
      prec.left(8,  seq(field('left', $._expr), '-',   field('right', $._expr))),
      prec.left(9,  seq(field('left', $._expr), '*',   field('right', $._expr))),
      prec.left(9,  seq(field('left', $._expr), '/',   field('right', $._expr))),
      prec.left(9,  seq(field('left', $._expr), '%',   field('right', $._expr))),
      prec.left(10, seq(field('left', $._expr),
                        field('op', $.backtick_ident),
                        field('right', $._expr))),
    ),

    /* Unary: must beat expr_app (prec 12) so `-e` reduces before application */
    unary_expr: $ => choice(
      prec(15, seq(field('op', '-'), field('operand', $._expr))),
      prec(15, seq(field('op', '!'), field('operand', $._expr))),
    ),

    /* Function application — left-associative, highest after postfix */
    expr_app: $ => prec.left(12, seq(
      field('function', $._expr),
      field('argument', $._expr),
    )),

    /* Field access: expr.field */
    field_access: $ => prec.left(13, seq(
      field('object', $._expr),
      '.',
      field('field', $.ident),
    )),

    /* Array index: expr.[idx] */
    index_expr: $ => prec.left(13, seq(
      field('object', $._expr),
      '.',
      '[',
      field('index', $._expr),
      ']',
    )),

    /* TypeName { field = val, ... } */
    record_create: $ => seq(
      field('type', $.upper),
      '{',
      $.record_field_expr,
      repeat(seq(',', $.record_field_expr)),
      '}',
    ),

    /* { base | field = val, ... } */
    record_update: $ => seq(
      '{',
      field('base', $._expr),
      '|',
      $.record_field_expr,
      repeat(seq(',', $.record_field_expr)),
      '}',
    ),

    record_field_expr: $ => seq(
      field('name', $.ident),
      '=',
      field('value', $._expr),
    ),

    /* Map { k => v, ... }  — Phase 16 collection literals */
    map_lit: $ => seq(
      field('constructor', $.upper),
      '{',
      $.map_entry,
      repeat(seq(',', $.map_entry)),
      '}',
    ),

    map_entry: $ => seq(
      field('key', $._expr),
      '=>',
      field('value', $._expr),
    ),

    /* Set { e, ... } */
    set_lit: $ => seq(
      field('constructor', $.upper),
      '{',
      $._expr,
      repeat(seq(',', $._expr)),
      '}',
    ),

    /* Operator section: (+5) → \x -> x + 5 */
    operator_section: $ => seq(
      '(',
      field('op', $.section_op),
      field('operand', $._expr),
      ')',
    ),

    section_op: $ => choice(
      '+', '*', '/', '%', '==', '!=', '<', '>', '<=', '>=',
      '&&', '||', '::', '++', '<>', '|>', '>>', '<<',
    ),

    /* @Name — impl disambiguation hint */
    impl_selection: $ => seq('@', field('name', $.upper)),

    /* (a, b, c) */
    tuple_expr: $ => seq(
      '(',
      $._expr,
      ',',
      $._expr,
      repeat(seq(',', $._expr)),
      ')',
    ),

    /* [x | x <- xs, x > 0]  — list comprehension */
    list_comp: $ => seq(
      '[',
      field('expr', $._expr),
      '|',
      $.lc_qual,
      repeat(seq(',', $.lc_qual)),
      ']',
    ),

    /* A single list comprehension qualifier */
    lc_qual: $ => choice(
      seq(field('pat', $.pat), '<-', field('value', $._expr)),
      seq('let', 'mut', field('pat', $.pat), '=', field('value', $._expr)),
      seq('let', field('pat', $.pat), '=', field('value', $._expr)),
      field('guard', $._expr),
    ),

    /* [1, 2, 3]  or  [] */
    list_expr: $ => seq(
      '[',
      optional(seq($._expr, repeat(seq(',', $._expr)))),
      ']',
    ),

    /* [| 1, 2, 3 |]  or  [| |] */
    array_expr: $ => seq(
      '[|',
      optional(seq($._expr, repeat(seq(',', $._expr)))),
      '|]',
    ),

    /* "hello \{name}, you are \{age} years old!"
     * External tokens carry the string segments; expressions are parsed normally. */
    interp_string: $ => seq(
      $._interp_open,
      $._expr,
      repeat(seq($._interp_mid, $._expr)),
      $._interp_end,
    ),

    /* ═══════════════════════════════════════════════════
     * Do-notation statements
     * ═══════════════════════════════════════════════════ */

    stmt: $ => choice(
      $.do_bind,
      $.do_let,
      $.do_let_mut,
      $.do_assign,
      $.do_stmt_expr,
    ),

    /* pat <- expr */
    do_bind: $ => seq(
      field('pat', $.pat),
      '<-',
      field('value', $._expr),
      $._newline,
    ),

    /* let x = expr */
    do_let: $ => seq(
      'let',
      field('pat', $.pat),
      '=',
      field('value', $._expr),
      $._newline,
    ),

    /* let mut x = expr */
    do_let_mut: $ => seq(
      'let', 'mut',
      field('pat', $.pat),
      '=',
      field('value', $._expr),
      $._newline,
    ),

    /* x = expr  (reassignment of let-mut var) */
    do_assign: $ => seq(
      field('name', $.ident),
      '=',
      field('value', $._expr),
      $._newline,
    ),

    /* expr  (discard result) */
    do_stmt_expr: $ => seq(
      field('value', $._expr),
      $._newline,
    ),
  },
});
