/* Medaka native runtime — Stage 2.4 DE-RISKING SPIKE (slices 1–3).
 *
 * This is NOT the real runtime.  It is the minimal C stub the spike's emitted
 * LLVM IR links against to prove the emit -> clang -> link -> run -> diff
 * toolchain end-to-end (see selfhost/STAGE2-DESIGN.md §2.4 and the "Value
 * representation & calling convention" section of selfhost/RUNTIME-DESIGN.md).
 *
 * Scope discipline (matches the emitter): integers, floats, booleans, let, if,
 * functions, and (slice 3) algebraic data types + pattern matching — the latter
 * box constructor cells through the same mdk_alloc below.  No closures / records
 * / dispatch / GC.
 *
 * VALUE REPRESENTATION (PROVISIONAL — see RUNTIME-DESIGN.md, revisable):
 *   A Medaka value is a uniform 64-bit word (`i64` in the IR).
 *     - Integers are IMMEDIATE: word = (n << 1) | 1   (low bit 1 => tagged int).
 *       63-bit signed range; untag = word >> 1 (arithmetic).
 *     - Booleans reuse the immediate-int encoding (0 / 1) — slice 1 is statically
 *       typed, so the emitter picks the print routine by static type and never
 *       needs to tell a Bool from an Int at runtime.  A polymorphic rep will need
 *       to (a documented limitation surfaced by this spike).
 *     - Floats are BOXED: word is a pointer (low bit 0, malloc is >=8-aligned) to
 *       a 16-byte heap cell { i64 header = TAG_FLOAT, double payload }.  This is
 *       what surfaces "floats don't fit in a tagged-int word" -> the alloc below.
 *     - ADT values are BOXED (slice 3): word is a pointer to a cell
 *       { i64 tag (constructor name hashed), field0, field1, ... } — one 8-byte
 *       word each.  Same boxed-pointer discipline as Float, extended to n fields;
 *       allocated through the same mdk_alloc.
 *
 * The tag arithmetic lives in the EMITTED IR (so the cost is visible); these
 * helpers take/return *native* C scalars (the emitter untags/unboxes first).
 *
 * GC: the spike now runs on the Boehm conservative collector (bdw-gc).  mdk_alloc
 *   routes to GC_malloc; immediates are odd words (low bit 1), so Boehm never
 *   mistakes an Int/Char/Bool/Unit/nullary-ctor for a pointer, and every boxed
 *   value is an 8-byte-aligned real pointer Boehm tracks natively
 *   (RUNTIME-DESIGN.md §8.0 fact 3, §8.1).  Precise GC remains future work.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdnoreturn.h>
#include <gc.h>

/* Initialize Boehm once before main().  The emitted IR owns `main`, so we can't
 * call GC_INIT() from it; a constructor runs first, near the bottom of the stack,
 * which is where GC_INIT wants to capture the stack base (recommended on macOS).
 * GC_malloc would otherwise lazily init on its first call. */
__attribute__((constructor)) static void mdk_gc_init(void) { GC_INIT(); }

/* Allocate `n` bytes in the GC heap.  Routes to Boehm's GC_malloc (conservative,
 * collected); every extern that RETURNS a Medaka value goes through this single
 * entry point, so the malloc->GC swap was one function (RUNTIME-DESIGN.md §2a).
 * GC_malloc returns >=8-byte-aligned, zeroed memory — satisfying the boxed-pointer
 * alignment contract the value rep relies on. */
void *mdk_alloc(long long n) { return GC_malloc((size_t)n); }

noreturn void mdk_oob(void) {
  fprintf(stderr, "array index out of bounds\n");
  exit(1);
}

/* Print an Int.  Matches the tree-walker oracle: Eval.pp_value (VInt n) =
 * string_of_int n, then eval_probe adds a trailing newline. */
void mdk_print_int(long long v) { printf("%lld\n", v); }

/* Print a Bool.  Matches Eval.pp_value (VBool b) = string_of_bool b. */
void mdk_print_bool(long long v) { printf(v ? "true\n" : "false\n"); }

/* Print a Float.  Must reproduce Eval.pp_value (VFloat f) byte-for-byte:
 * OCaml string_of_float is valid_float_lexem (sprintf "%.12g" f) — i.e. "%.12g"
 * then a trailing "." appended when the lexeme would otherwise read as an int
 * (no '.'/'e').  pp_value then appends ".0" only if still no '.'/'e', which the
 * trailing-"." already prevents.  So: "%.12g", and append one "." if integral. */
void mdk_print_float(double d) {
  char buf[64];
  snprintf(buf, sizeof buf, "%.12g", d);
  if (!strchr(buf, '.') && !strchr(buf, 'e') &&
      !strchr(buf, 'n') && !strchr(buf, 'i')) /* skip nan/inf */
    strcat(buf, ".");
  printf("%s\n", buf);
}
