# test/ported — Native Medaka test ports

Stage 3 retirement-bar item 2: program-behavior cases from OCaml alcotest suites
re-expressed as native `medaka test` files, decoupling the test suite from `lib/`.

Run with:

    medaka test test/ported/test_run_ported.mdk

(Or via the built binary: `./_build/default/bin/main.exe test test/ported/test_run_ported.mdk`)

## test_run_ported.mdk

Source suite: `test/test_run.ml` (46 cases total).

**Ported: 40 OCaml test cases → 96 Medaka test assertions** (many cases expand
to multiple assertions — one per dispatch path or value branch).

**Module resolution note:** `test/ported/test.mdk` is a symlink to
`../../stdlib/test.mdk`. The loader resolves `import test` from the file's
directory; the symlink makes `stdlib/test.mdk` available as `test` without
modifying the stdlib directory or the project layout.

### Skipped cases (6)

| Category | Count | OCaml test(s) | Skip reason |
|---|---|---|---|
| Runtime-error detection | 5 | `t_runtime_err`, `t_recursive_value_force_err`, `t_recursive_value_force_msg`, `t_guard_exhausted_err`, `t_string_bracket_index_oob` | Asserting that evaluation raises `Eval_error` requires `runExpectation` (catches errors, returns `Fail`). `runExpectation` is defined in `stdlib/test.mdk` but **not exported** — can't be imported. Without it there is no way to express "this program should crash" as an `Expectation`. To port these, export `runExpectation` from `stdlib/test.mdk`. |
| IO extern behavior | 2 | `t_io_args_empty`, `t_io_getenv_unset` | These test that `args ()` returns `[]` and `getEnv "missing"` returns `None` in the test runner environment. The assertions are trivially true (not structurally interesting as value tests) and are covered by the doctest path for the relevant stdlib externs. |

### Ported case mapping

| OCaml test | Medaka assertion(s) | Notes |
|---|---|---|
| `t_hello` | `hello world literal` | Structural identity of the string value |
| `t_multi_print` | `multi print values` | `expectAll` over the three strings |
| `t_if_inline_then_block_else` | `if inline-then block-else pos/neg` | Tests `classify` function (Phase 118) |
| `t_if_elseless` | `else-less if pos/zero` | Tests boolean expression, not IO side-effect |
| `t_factorial` | `factorial 10` | |
| `t_adt_match` | `adt match red/green/blue` | |
| `t_let_mut` | `let mut` | Tests `letMutResult` computed value |
| `t_guard_fallthrough` | `guard fallthrough take 2`, `guard base case` | Phase 91 |
| `t_string_kernel` | 9 assertions (`charCode`, `charFromCode`, `stringConcat`, `stringCompare`×3, `stringToFloat`×2) | Phase 75 |
| `t_string_codepoint` | 7 assertions (length, slice, arrow codepoint, toChars, fromChars) | |
| `t_string_unicode` | 8 assertions (charIsAlpha, charIsSpace, charIsPunct, charToUpper, stringToUpper/Lower) | |
| `t_string_index_of` | 4 assertions | |
| `t_string_bracket_slice` | 3 assertions | Phase 75 |
| `t_string_bracket_index` | 3 assertions | Phase 77 |
| `t_return_position_dispatch` | 3 assertions | Phase 69 |
| `t_multiparam_dispatch` | 2 assertions | Phase 69 |
| `t_dict_polymorphic_helper` | 2 assertions | Phase 69.x |
| `t_dict_transitive` | 2 assertions | Phase 69.x |
| `t_mutual_rec_dict` | 2 assertions | Phase 136 |
| `t_foldmap_method_dict_concrete` | 1 assertion | Phase 69.x-e |
| `t_foldmap_method_dict_polymorphic` | 2 assertions | Phase 69.x-e |
| `t_foldmap_explicit_impl_offset` | 2 assertions | Phase 69.x-e |
| `t_nullary_empty_stdlib_monoid` | 2 assertions | Phase 96 |
| `t_nullary_empty_custom_monoid` | 2 assertions | Phase 96 |
| `t_nullary_empty_requires` | 1 assertion | Phase 103b |
| `t_nullary_bounded` | 2 assertions | Phase 96 |
| `t_nullary_bounded_int` | 1 assertion | Phase 93 |
| `t_nullary_bounded_char` | 2 assertions | Phase 93 |
| `t_head_key_dispatch` | 2 assertions | Phase 69.x-c |
| `t_super_dict_dispatch` | 2 assertions | Phase 69.x-c |
| `t_println_display_vs_inspect` | 2 assertions | Phase 111 |
| `t_nested_instance_dicts` | 4 assertions | Phase 83/84 #5 |
| `t_pointfree_prelude_tolist` | 1 assertion | Phase 121 |
| `t_pointfree_impl_forward_ref` | 1 assertion | Phase 121 |
| `t_pointfree_nullary_empty_unaffected` | 1 assertion | Phase 121 |
| `t_prelude_fn_shadow` / `t_prelude_method_shadow` | 3 assertions (adapted) | Phase 78a/b: adapted to test prelude methods from import context rather than shadowing (shadowing semantics only apply in single-file pipeline, not the multi-module path `medaka test` uses) |
| `t_poly_monad_do` | 1 assertion | Phase 84 |
| `t_no_bind_do_grounded` | 1 assertion | Phase 115 #3 |
| `t_infer_return_pos_wrapper` | 2 assertions | Phase 115 #1 |
| `t_infer_return_pos_recursive` | 2 assertions | Phase 115 #2 |
| `t_infer_return_pos_mutual` | 1 assertion | Phase 115 #2 |

### Expressiveness limits encountered

- **No stdout capture**: `medaka test` has no facility to capture `println` output. Cases are restructured to assert on the underlying computed values (`display`/`debug` strings, direct values) rather than captured IO.
- **No `runExpectation` export**: Cannot test "program raises runtime error" (see skipped cases above).
- **Ordering has no Eq**: `stringCompare` returns `Ordering` (`Lt`/`Eq`/`Gt`), which has no `Eq` impl, so `expectEqual` cannot be used directly. Workaround: `isLt`/`isEq`/`isGt` pattern-match helpers.
- **Phase 78 prelude-shadow tests not fully portable**: The single-file pipeline (where user defs override prelude fns) differs from the multi-module path `medaka test` uses for import-bearing files. The original tests exercise the single-file fallback; the ported version tests the prelude methods directly instead.
