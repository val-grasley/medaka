/* Medaka native runtime — Stage 2.4 DE-RISKING SPIKE (slices 1–3).
 *
 * This is NOT the real runtime.  It is the minimal C stub the spike's emitted
 * LLVM IR links against to prove the emit -> clang -> link -> run -> diff
 * toolchain end-to-end (see compiler/STAGE2-DESIGN.md §2.4 and the "Value
 * representation & calling convention" section of compiler/RUNTIME-DESIGN.md).
 *
 * Scope discipline (matches the emitter): integers, floats, booleans, let, if,
 * functions, (slice 3) algebraic data types + pattern matching, and (native
 * extern catalog slice 1) heap Strings + the minimal string/IO leaf externs
 * (`mdk_str_lit`, `mdk_print_str`, `mdk_int_to_string`).  ADT and String cells
 * box through the same mdk_alloc below.  No closures / records / dispatch beyond
 * what the emitter already drives.
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
/* _GNU_SOURCE: on glibc/Linux, pthread_getattr_np (used by the P0-2 fault
 * backstop to find the worker stack bounds) is only declared under it.  No-op on
 * Darwin, which uses pthread_get_stackaddr_np instead. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <math.h>
#include <string.h>
#include <stdnoreturn.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <stdint.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#include <pthread.h>
/* GC_THREADS MUST be defined before <gc.h> so Boehm exposes GC_pthread_create /
 * GC_pthread_join.  The compiler runs its whole pipeline on a large-stack worker
 * thread (see `int main` at the bottom of this file); a thread created with raw
 * pthread_create would NOT have its stack registered as a GC root, so Boehm would
 * collect still-live objects and corrupt the heap.  GC_pthread_create registers
 * the worker's stack, keeping conservative scanning correct on it. */
#define GC_THREADS
#include <gc.h>

/* Initialize Boehm once before main().  This runtime owns `int main` (bottom of
 * this file); the emitted IR's entry is `mdk_program_main`, which we run on a
 * GC_pthread_create'd large-stack worker thread.  A constructor runs first, near
 * the bottom of the process stack, which is where GC_INIT wants to capture the
 * (main-thread) stack base; the worker thread's own stack is registered
 * separately by GC_pthread_create.  GC_malloc would otherwise lazily init on its
 * first call. */
__attribute__((constructor)) static void mdk_gc_init(void) {
  GC_INIT();
  /* Perf tuning (compiler/PERF-RESULTS.md): Medaka workloads are
   * allocation-heavy and mostly short-lived (the emitter alone allocates
   * ~4200 cells/run plus every cons/closure/ADT).  The default free-space
   * divisor (3) collects aggressively to keep RSS low; we trade some memory
   * for fewer collection pauses by letting the heap grow further between GCs.
   * Env var GC_FREE_SPACE_DIVISOR still overrides this if set. */
  if (!getenv("GC_FREE_SPACE_DIVISOR")) GC_set_free_space_divisor(1);
}

/* Allocate `n` bytes in the GC heap.  Routes to Boehm's GC_malloc (conservative,
 * collected); every extern that RETURNS a Medaka value goes through this single
 * entry point, so the malloc->GC swap was one function (RUNTIME-DESIGN.md §2a).
 * GC_malloc returns >=8-byte-aligned, zeroed memory — satisfying the boxed-pointer
 * alignment contract the value rep relies on. */
void *mdk_alloc(long long n) { return GC_malloc((size_t)n); }

/* Allocate `n` bytes of POINTER-FREE memory (raw bytes / string cells).  Routes to
 * Boehm's GC_malloc_atomic: the block is never scanned for pointers during mark, so
 * the GC does not waste mark time walking string contents (the emitter produces an
 * enormous volume of transient string garbage).  Callers MUST fully initialise the
 * block before any read — GC_malloc_atomic does not zero — and the block MUST contain
 * no pointers the collector needs to follow.  String cells qualify: their header is
 * three integer words (tag, byte_len, cp_count) followed by raw UTF-8 bytes, all
 * written by mdk_str_lit; no field is a heap pointer. */
void *mdk_alloc_atomic(long long n) { return GC_malloc_atomic((size_t)n); }

/* ---- generic arity-aware closure application (partial application / PAPs) ----
 *
 * A CLOSURE cell is `[ i64 arity | i64 code_ptr | captures... ]`: field 0 is the
 * closure's callable arity (the number of value args its lifted `@mdk_lamN` define
 * takes AFTER the leading `%clos` word), field 1 the code pointer.  The emitter
 * calls a closure INLINE (`code_ptr(cw, args...)`) only when it can prove the
 * supplied count equals the runtime arity; otherwise it routes through __mdk_apply.
 *
 * A PARTIAL APPLICATION (PAP) is `[ i64 -1 | i64 orig_cw | i64 n_supplied |
 * supplied_args... ]`: the -1 header sentinel (never equals a real supplied count
 * >= 1) forces every application of a PAP through __mdk_apply, which FLATTENS it —
 * re-dispatching the original closure against (already-supplied ++ new) args.  So a
 * PAP is never called via the inline fast path and needs no per-arity trampoline. */
#define MDK_MAX_ARITY 16

typedef long long mdk_i64;

mdk_i64 __mdk_apply(mdk_i64 cw, mdk_i64 argc, const mdk_i64 *argv);

/* call `code`(cw, argv[0..argc-1]) — argc statically-typed via a small switch. */
static mdk_i64 mdk_call_exact(mdk_i64 code, mdk_i64 cw, mdk_i64 argc,
                              const mdk_i64 *a) {
  switch (argc) {
    case 0:  return ((mdk_i64(*)(mdk_i64))code)(cw);
    case 1:  return ((mdk_i64(*)(mdk_i64,mdk_i64))code)(cw,a[0]);
    case 2:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1]);
    case 3:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1],a[2]);
    case 4:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1],a[2],a[3]);
    case 5:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1],a[2],a[3],a[4]);
    case 6:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1],a[2],a[3],a[4],a[5]);
    case 7:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1],a[2],a[3],a[4],a[5],a[6]);
    case 8:  return ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)(cw,a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7]);
    default:
      /* arity > 8: saturate 8 at a time, then apply the surplus. */
      {
        mdk_i64 r = ((mdk_i64(*)(mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64,mdk_i64))code)
                      (cw,a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7]);
        return __mdk_apply(r, argc - 8, a + 8);
      }
  }
}

/* build a PAP capturing `cw` plus the `argc` args already supplied. */
static mdk_i64 mdk_make_pap(mdk_i64 cw, mdk_i64 argc, const mdk_i64 *argv) {
  mdk_i64 *cell = (mdk_i64 *)mdk_alloc((long long)(8 * (3 + argc)));
  cell[0] = -1;         /* PAP sentinel header */
  cell[1] = cw;         /* the original closure */
  cell[2] = argc;       /* number of args captured so far */
  for (mdk_i64 i = 0; i < argc; i++) cell[3 + i] = argv[i];
  return (mdk_i64)cell;
}

/* apply the closure/PAP word `cw` to `argc` args (a pointer to `argc` i64 words).
 * The single entry point for any application the emitter could not resolve to an
 * exact-arity inline call. */
mdk_i64 __mdk_apply(mdk_i64 cw, mdk_i64 argc, const mdk_i64 *argv) {
  mdk_i64 *cell = (mdk_i64 *)cw;
  if (cell[0] == -1) {
    /* PAP: flatten — combine already-supplied args with the new ones and
     * re-dispatch against the underlying closure. */
    mdk_i64 orig = cell[1];
    mdk_i64 nsup = cell[2];
    mdk_i64 total = nsup + argc;
    mdk_i64 stackbuf[2 * MDK_MAX_ARITY];
    mdk_i64 *buf = stackbuf;
    if (total > (mdk_i64)(2 * MDK_MAX_ARITY))
      buf = (mdk_i64 *)mdk_alloc((long long)(8 * total));
    for (mdk_i64 i = 0; i < nsup; i++) buf[i] = ((mdk_i64 *)cw)[3 + i];
    for (mdk_i64 i = 0; i < argc; i++) buf[nsup + i] = argv[i];
    return __mdk_apply(orig, total, buf);
  }
  {
    mdk_i64 arity = cell[0];
    mdk_i64 code = cell[1];
    if (argc == arity) return mdk_call_exact(code, cw, argc, argv);
    if (argc < arity) return mdk_make_pap(cw, argc, argv);
    /* over-application: saturate `arity`, then apply the surplus to the result. */
    {
      mdk_i64 r = mdk_call_exact(code, cw, arity, argv);
      return __mdk_apply(r, argc - arity, argv + arity);
    }
  }
}

/* Forward-declared: defined below (near mdk_putstr) alongside the rest of the
   "run drops stdout on panic" stash/flush machinery; mdk_oob is an abort path
   that needs it but is emitted earlier in this file. */
static void mdk_flush_run_stdout_on_abort(void);

noreturn void mdk_oob(void) {
  mdk_flush_run_stdout_on_abort();
  fprintf(stderr, "runtime error [E-INDEX-OOB]: index out of bounds\n");
  exit(1);
}

/* Out-of-range `arr.[lo..hi]` / `arr.[lo..=hi]` (#550).  The emitted slice used to
 * allocate `end - lo` slots and copy `a[lo + i]` with NO bounds check, so an
 * over-range slice READ OFF THE END OF THE HEAP and surfaced whatever it found —
 * including live pointers — as ordinary Ints, at exit 0.  `run` raised E-SLICE-OOB
 * all along (sliceArray, compiler/eval/eval.mdk); only the native path was unchecked.
 *
 * `lo`/`hi_incl` are RAW (already >>1-untagged) i64s, and `hi_incl` is the INCLUSIVE
 * upper bound (end - 1) so the text is byte-identical to the interpreter's
 * `slice [\{lo}..\{hiX - 1}] out of bounds`.  Unlike mdk_oob (whose message carries no
 * number, so it needs no args) exact parity with `run` is cheap here: this is an abort
 * path, so the two extra argument words cost nothing on the hot path. */
noreturn void mdk_slice_oob(long long lo, long long hi_incl) {
  mdk_flush_run_stdout_on_abort();
  fprintf(stderr, "runtime error [E-SLICE-OOB]: slice [%lld..%lld] out of bounds\n",
          lo, hi_incl);
  exit(1);
}

/* Print an Int.  Matches the tree-walker oracle: Eval.pp_value (VInt n) =
 * string_of_int n, then eval_probe adds a trailing newline. */
void mdk_print_int(long long v) { printf("%lld\n", v); }

/* Print a Bool for the VALUE-MAIN auto-print (emitPrint LTBool -> the sole caller;
 * llvm_emit.mdk's `if mainIsUnit e mty then () else emitPrint e mv mty`).
 *
 * Renders the CONSTRUCTOR names `True`/`False` — Medaka's own `impl Display Bool`
 * (stdlib/core.mdk: `display True = "True"`).  That is the contract a SHIPPING
 * binary produces: `medaka build` runs the composite-main auto-print wrap
 * (compiler/driver/main_autoprint.mdk), which rewrites `main = <e>` into
 * `main = println <e>`, so a Bool value-main renders through `display`.  The WasmGC
 * backend's peer ($mdk_print_bool in compiler/backend/wasm_preamble.mdk) already
 * writes "True"/"False", with a comment saying it MUST agree with native's
 * println/display — this function was the last holdout.
 *
 * It previously printed OCaml's `string_of_bool` ("true"/"false") to match the
 * OCaml oracle's Eval.pp_value.  That oracle was REMOVED 2026-06-26, so the
 * lowercase rendering survived only in the PRELUDE-FREE emit probes
 * (test/bin/llvm_emit_main), where no `println` is in scope and the wrap cannot
 * fire.  That is why test/diff_compiler_llvm.sh was grading a rendering no
 * `medaka build` binary can ever emit. */
void mdk_print_bool(long long v) { printf(v ? "True\n" : "False\n"); }

/* Render the canonical Medaka float lexeme into `out` (needs >= 32 bytes).
 *
 * DECIDED 2026-06-15 / REVISED 2026-07-15 (issue #57): SHORTEST-ROUND-TRIP.  The
 * lexeme is the fewest significant digits that `strtod` reads back to the
 * bit-identical double — so `debug (0.1 + 0.2)` renders "0.30000000000000004",
 * not the old "%.12g" truncation "0.3".  Digits come from `%.*e` at the smallest
 * precision whose round-trip is bit-exact (compared as uint64 bit patterns, not
 * `double ==`, so a NaN can never spuriously match).
 *
 * The EXPONENT THRESHOLD is unchanged from the historical "%.12g" rule
 * (scientific iff decimal exponent < -4 or >= 12), so whole/round values still
 * print "N.0" (100.0, not "1e+02") and only values that genuinely need >12 sig
 * digits move.  Scientific form is lowercase 'e' + sign + 2-digit-padded exponent
 * (e.g. "1e-07", "1e+20"), which the post-#51 lexer reads back.  The ".0" append
 * rule tags a bare-integer lexeme (no '.'/'e').  inf/nan pass through untouched
 * ("inf"/"-inf"/"nan"), never the loop.  This helper is the SINGLE source of truth
 * shared by mdk_print_float (bare-Float auto-print) and mdk_float_to_string (the
 * floatToString extern) — they MUST stay byte-identical, and both mirror the JS
 * host copies in test/wasm/run.js and playground/worker.js. */
static void mdk_float_lexeme(double d, char *out) {
  if (isnan(d)) { strcpy(out, "nan"); return; }
  if (isinf(d)) { strcpy(out, d < 0 ? "-inf" : "inf"); return; }
  if (d == 0.0) { strcpy(out, (1.0 / d < 0) ? "-0.0" : "0.0"); return; }

  /* shortest significant-digit count: %.*e with precision p-1 == p sig digits. */
  char sci[64];
  int p;
  for (p = 1; p <= 17; p++) {
    snprintf(sci, sizeof sci, "%.*e", p - 1, d);
    double rt = strtod(sci, NULL);
    uint64_t a, b;
    memcpy(&a, &rt, 8);
    memcpy(&b, &d, 8);
    if (a == b) break;
  }
  if (p > 17) snprintf(sci, sizeof sci, "%.*e", 16, d);

  /* parse sci = [-]d[.ddd]e(+|-)XX into sign, digit string, decimal exponent. */
  const char *s = sci;
  int neg = 0;
  if (*s == '-') { neg = 1; s++; }
  char digits[40];
  int nd = 0;
  digits[nd++] = *s++;                 /* leading significant digit */
  if (*s == '.') { s++; while (*s != 'e' && *s != 'E') digits[nd++] = *s++; }
  int exp = atoi(s + 1);               /* s points at 'e' */
  digits[nd] = '\0';
  while (nd > 1 && digits[nd - 1] == '0') digits[--nd] = '\0';  /* trim (defensive) */

  char body[80];
  if (exp < -4 || exp >= 12) {
    char mant[48];
    if (nd == 1) { mant[0] = digits[0]; mant[1] = '\0'; }
    else { mant[0] = digits[0]; mant[1] = '.'; strcpy(mant + 2, digits + 1); }
    snprintf(body, sizeof body, "%se%c%02d", mant, exp < 0 ? '-' : '+',
             exp < 0 ? -exp : exp);
  } else {
    int pp = exp + 1;                  /* digits before the decimal point */
    if (pp <= 0) {
      char z[24];
      int i;
      for (i = 0; i < -pp; i++) z[i] = '0';
      z[i] = '\0';
      snprintf(body, sizeof body, "0.%s%s", z, digits);
    } else if (pp >= nd) {
      char z[24];
      int i;
      for (i = 0; i < pp - nd; i++) z[i] = '0';
      z[i] = '\0';
      snprintf(body, sizeof body, "%s%s", digits, z);
    } else {
      char head[40];
      memcpy(head, digits, (size_t)pp);
      head[pp] = '\0';
      snprintf(body, sizeof body, "%s.%s", head, digits + pp);
    }
  }

  char full[96];
  if (neg) snprintf(full, sizeof full, "-%s", body);
  else     snprintf(full, sizeof full, "%s", body);
  if (!strpbrk(full, ".eEni")) strcat(full, ".0");  /* bare-int lexeme -> N.0 */
  strcpy(out, full);
}

/* Print a bare Float (the auto-print sink) via the shared canonical lexeme. */
void mdk_print_float(double d) {
  char buf[96];
  mdk_float_lexeme(d, buf);
  printf("%s\n", buf);
}

/* ── Strings (native extern catalog, slice 1) ────────────────────────────────
 * STRING REPRESENTATION — LOCKED 2026-06-07 (RUNTIME-DESIGN.md §4 / §7 decision
 * 2): UTF-8 bytes + a CACHED codepoint count, boxed as one GC cell:
 *
 *   offset  0:  i64 header     layout id (MDK_STR_TAG; not yet tag-tested — no
 *                              String match heads in this slice)
 *   offset  8:  i64 byte_len   number of UTF-8 bytes (raw / untagged)
 *   offset 16:  i64 cp_count   cached codepoint count  ->  stringLength is O(1)
 *   offset 24:  byte_len bytes of UTF-8, then a NUL (for cheap C interop)
 *
 * Caching cp_count is the choice §4 calls for (Medaka is codepoint-aware): it
 * makes `stringLength` INTRINSIC (a header read) rather than an O(n) scan — see
 * the §5 (rep)-row reconciliation in RUNTIME-DESIGN.md.  The cell rides the same
 * one-word-header boxed-pointer discipline (§8.1 / §8.4) as every other heap
 * value, so it is GC-managed for free under Boehm: the value word is an aligned
 * pointer (low bit 0) Boehm tracks, and the inline bytes are scanned harmlessly.
 *
 * Per §2a, every extern that RETURNS a Medaka String allocates it here, through
 * mdk_alloc -> GC_malloc, with this exact layout — it never hands back a
 * native-owned buffer.  mdk_int_to_string is the first such extern. */
#define MDK_STR_TAG 1

/* Count UTF-8 codepoints in the first `n` bytes of `p`: every byte that is not a
 * 0b10xxxxxx continuation byte starts a new codepoint. */
static long long mdk_utf8_cp_count(const char *p, long long n) {
  long long c = 0;
  for (long long i = 0; i < n; i++)
    if (((unsigned char)p[i] & 0xC0) != 0x80) c++;
  return c;
}

/* Build a boxed String cell from `byte_len` raw UTF-8 bytes; return the value
 * word (cell pointer as i64, low bit 0).  The single GC allocation every
 * String-returning extern (and the emitter's string literals) routes through. */
long long mdk_str_lit(const char *bytes, long long byte_len) {
  char *cell = (char *)mdk_alloc_atomic(24 + byte_len + 1);
  ((long long *)cell)[0] = MDK_STR_TAG;
  ((long long *)cell)[1] = byte_len;
  ((long long *)cell)[2] = mdk_utf8_cp_count(bytes, byte_len);
  memcpy(cell + 24, bytes, (size_t)byte_len);
  cell[24 + byte_len] = '\0';
  return (long long)cell;
}

/* String equality on two boxed String cells.  Returns a TAGGED Medaka Bool word
 * (3 = True, 1 = False, matching the emitter's `if b then "3" else "1"` rep), so
 * the literal-switch emitter can `icmp eq i64 r, 3` to branch.  Two strings are
 * equal iff equal byte_len and byte-identical payload (codepoint count is a cache
 * of byte content, so byte_len + memcmp is sufficient and exact). */
long long mdk_string_eq(long long a, long long b) {
  const char *ca = (const char *)a;
  const char *cb = (const char *)b;
  long long la = ((const long long *)ca)[1];
  long long lb = ((const long long *)cb)[1];
  if (la != lb) return 1;
  if (memcmp(ca + 24, cb + 24, (size_t)la) != 0) return 1;
  return 3;
}

/* Polymorphic `==`/`!=` for operands whose static LTy the emitter could not
 * recover (both default to LTInt — e.g. a `feq a b = a == b` over inferred-Float
 * params, or two String-typed params whose only use is `n == name`).
 * Discriminates at run time on the low bit / header tag, the EXACT peer of
 * mdk_value_cmp_raw's Ord discriminator (they MUST stay in lockstep):
 *   - boxed String cell (even pointer, header == MDK_STR_TAG) -> byte compare;
 *   - boxed Float cell  (even pointer, header == 2)           -> double compare
 *     (issue #181: without this arm two independently-boxed floats compared as
 *     value words — i.e. by POINTER — so `feq 0.5 0.5` was False in native);
 *   - otherwise (tagged immediates — Int/Bool/Char, nullary-ctor words) compares
 *     by value word.  Well-typed operands share a type, so testing the LEFT
 *     operand suffices (matching mdk_value_cmp_raw).  Returns a TAGGED Bool
 *     (3 = True, 1 = False), matching mdk_string_eq.  `da == db` gives IEEE
 *     semantics (NaN != NaN, -0.0 == 0.0), matching the inline `fcmp oeq` path. */
long long mdk_value_eq(long long a, long long b) {
  int a_str = ((a & 1) == 0) && ((const long long *)a)[0] == MDK_STR_TAG;
  int b_str = ((b & 1) == 0) && ((const long long *)b)[0] == MDK_STR_TAG;
  if (a_str && b_str) return mdk_string_eq(a, b);
  int a_flt = ((a & 1) == 0) && ((const long long *)a)[0] == 2;
  if (a_flt) {
    double da = ((const double *)a)[1], db = ((const double *)b)[1];
    return da == db ? 3 : 1;
  }
  return a == b ? 3 : 1;
}

/* Print a String RAW (no quoting).  Matches Eval.pp_value (VString s) = s, then
 * the oracle's trailing newline (eval_probe / compiler ppValue). */
void mdk_print_str(long long w) {
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  fwrite(cell + 24, 1, (size_t)byte_len, stdout);
  putchar('\n');
}

/* intToString : Int -> String  (LEAF, RUNTIME-DESIGN.md §5).  The argument is a
 * TAGGED immediate int word; untag (arithmetic shift), render decimal to match
 * OCaml string_of_int, and box the result through mdk_str_lit. */
long long mdk_int_to_string(long long tagged) {
  long long n = tagged >> 1;
  char buf[32];
  int len = snprintf(buf, sizeof buf, "%lld", n);
  return mdk_str_lit(buf, len);
}

long long mdk_float_to_string(double d) {
  char buf[96];
  mdk_float_lexeme(d, buf);   /* shared canonical lexeme (see mdk_float_lexeme) */
  return mdk_str_lit(buf, (long long)strlen(buf));
}

/* ---------------------------------------------------------------------------
 * BUILD-BINARY STDOUT-LOSS FIX (companion to the `medaka run` "drops stdout on
 * panic" fix below, but for a COMPILED, non-interpreter `medaka build` binary).
 *
 * A compiled binary's println/print write straight through LIBC's BUFFERED
 * stdout (mdk_fwrite_str -> fwrite(..., stdout)). Every EXIT()-based abort path
 * (mdk_panic, mdk_div_zero, mdk_oob, ...) already gets that buffer out for free,
 * since libc's exit() runs stdio's atexit flush. But the SIGSEGV/SIGBUS fault
 * handler below must call _exit(), never exit() (async-signal-safety: fflush/
 * fwrite are not on the POSIX async-signal-safe list, and calling them from a
 * signal handler risks deadlocking on stdio's lock if the crashing thread
 * already held it mid-fwrite) — and _exit() skips that flush entirely. So a
 * compiled binary that prints, then recurses into a genuine stack overflow,
 * lost every byte still sitting in libc's stdout buffer (confirmed empirically:
 * exit 134, empty stdout).
 *
 * Fix mirrors mdk_flush_run_stdout_on_abort's approach (below) exactly, adapted
 * for a native buffer instead of a GC-owned Medaka string cell: every stdout
 * write ALSO copies its bytes into a plain malloc'd, doubling-growth C buffer
 * (mdk_build_stdout_track — allocation/copy happens only in NORMAL execution,
 * NEVER inside the signal handler) and updates a pointer+length pair with plain
 * word stores. At abort time mdk_flush_build_stdout_on_fatal_signal reads that
 * pointer+length and write(2)s it — no allocation, no stdio, no locks, the same
 * discipline as mdk_flush_run_stdout_on_abort. It is called ONLY from the two
 * _exit() paths below (mdk_fault_handler's stack-overflow branch and
 * mdk_chain_previous's no-previous-handler branch) — NEVER from the exit()-based
 * abort paths, which already work correctly for a compiled binary via libc's own
 * flush; calling it there too would DOUBLE-print (once via libc's real flush,
 * once via this raw write(2)). The buffer is plain malloc/realloc, NOT
 * GC_malloc/mdk_alloc — it holds no pointers, needs no scanning, and must
 * survive independent of the GC heap.
 * ------------------------------------------------------------------------- */
static char *mdk_build_stdout_buf = NULL;
static long long mdk_build_stdout_len = 0;
static long long mdk_build_stdout_cap = 0;

static void mdk_build_stdout_track(const char *bytes, long long n) {
  if (n <= 0) return;
  if (mdk_build_stdout_len + n > mdk_build_stdout_cap) {
    long long newcap = mdk_build_stdout_cap == 0 ? 4096 : mdk_build_stdout_cap;
    while (newcap < mdk_build_stdout_len + n) newcap *= 2;
    char *nb = (char *)realloc(mdk_build_stdout_buf, (size_t)newcap);
    if (!nb) return; /* best-effort safety net: never sacrifice the real print for it */
    mdk_build_stdout_buf = nb;
    mdk_build_stdout_cap = newcap;
  }
  memcpy(mdk_build_stdout_buf + mdk_build_stdout_len, bytes, (size_t)n);
  mdk_build_stdout_len += n;
}

/* Async-signal-safe: word reads + write(2) only, no allocation, no stdio, no
   locks. Mirrors mdk_flush_run_stdout_on_abort but for the native build-stdout
   buffer above; see the block comment there for why the two must stay separate
   flush entry points despite doing the same thing. */
static void mdk_flush_build_stdout_on_fatal_signal(void) {
  const char *bytes = mdk_build_stdout_buf;
  long long len = mdk_build_stdout_len;
  while (len > 0) {
    ssize_t n = write(1, bytes, (size_t)len);
    if (n <= 0) break;
    bytes += n;
    len -= n;
  }
}

/* IO-output externs (native extern catalog slice 3).
   mdk_fwrite_str reads the string cell (bytes at offset 24, byte_len at offset 8)
   and writes to the given FILE; appends '\n' iff nl != 0. Tracks stdout writes
   (not stderr) into the fatal-signal safety-net buffer above. */
static void mdk_fwrite_str(long long w, FILE *out, int nl) {
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  if (out == stdout) mdk_build_stdout_track(cell + 24, byte_len);
  fwrite(cell + 24, 1, (size_t)byte_len, out);
  if (nl) {
    if (out == stdout) mdk_build_stdout_track("\n", 1);
    fputc('\n', out);
  }
}

void mdk_putstr(long long w)    { mdk_fwrite_str(w, stdout, 0); }
void mdk_putstrln(long long w)  { mdk_fwrite_str(w, stdout, 1); }
void mdk_eputstr(long long w)   { mdk_fwrite_str(w, stderr, 0); }
void mdk_eputstrln(long long w) { mdk_fwrite_str(w, stderr, 1); }
void mdk_flushstdout(long long w) { (void)w; fflush(stdout); }
void mdk_print_unit(void)       { printf("()\n"); }

/* ---------------------------------------------------------------------------
 * "run drops stdout on panic" fix.  `medaka run`'s tree-walking interpreter
 * buffers a program's stdout in an in-language Ref<String> (eval.mdk's
 * outputRef) and only writes it to real stdout via ONE final `putStr` call
 * after `main` returns NORMALLY (medaka_cli.mdk's `runProgramOutput`).
 * Medaka panics are NOT catchable (no exception handling, no unwind), so a
 * panicking program's buffered stdout used to be silently discarded — the
 * printed trace before the crash never reached the terminal, which made the
 * standard "does this ill-typed program actually EXECUTE" probe (`println`
 * a sentinel, then check whether it appears) blind: both `run`'s stdout AND
 * its exit code look identical whether the program ran or not.
 *
 * mdk_stash_run_stdout lets eval.mdk register the buffer's raw bytes (a
 * pointer + length into an already-allocated, GC-owned, IMMUTABLE string
 * cell -- storing the pointer performs no allocation and no observable
 * effect) after every print.  mdk_enable_run_stdout_flush is called exactly
 * once, only by the real `medaka run` CLI driver (evalModulesOutputRun /
 * evalModulesOutputAsync) -- never by the pure differential-oracle eval
 * probes, which share this exact source but never call it, so their
 * captured output (many goldens pin an EMPTY capture for a deliberately
 * panicking fixture) is unaffected.  Every abort path below -- mdk_panic,
 * mdk_div_zero, mdk_mod_zero, mdk_nonexhaustive_match, mdk_let_refute,
 * mdk_oob, and the SIGSEGV/SIGBUS fault handler for a genuine stack overflow
 * or fatal signal -- flushes the stash via write(2) before printing its own
 * diagnostic and exiting.  write(2) is async-signal-safe (unlike fflush/
 * fwrite), so the SAME flush function is safe to call from the fault
 * handler too, matching its existing "no allocation, no stdio" discipline.
 *
 * A compiled (non-interpreter) `medaka build` binary never calls
 * mdk_stash_run_stdout or mdk_enable_run_stdout_flush at all (its own
 * mdk_putstr/mdk_putstrln write straight to the real stdio `stdout` stream,
 * which `exit()` -- used by every abort path except the signal handler --
 * already flushes automatically), so the flag stays 0 and every check below
 * is a no-op for it.
 */
static volatile int mdk_run_stdout_flush_enabled = 0;
static const char *volatile mdk_run_stdout_bytes = NULL;
static volatile long long mdk_run_stdout_len = 0;

void mdk_enable_run_stdout_flush(long long w) {
  (void)w;
  mdk_run_stdout_flush_enabled = 1;
}

void mdk_stash_run_stdout(long long w) {
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  mdk_run_stdout_bytes = cell + 24;
  mdk_run_stdout_len = byte_len;
}

/* Async-signal-safe: only word-sized reads and write(2), no allocation, no
   stdio.  Clears the stash first so a re-entrant abort during the flush
   itself (or a later abort path, e.g. mdk_exit after this already ran)
   can't double-print. */
static void mdk_flush_run_stdout_on_abort(void) {
  if (!mdk_run_stdout_flush_enabled) return;
  const char *bytes = mdk_run_stdout_bytes;
  long long len = mdk_run_stdout_len;
  mdk_run_stdout_bytes = NULL;
  mdk_run_stdout_len = 0;
  while (len > 0) {
    ssize_t n = write(1, bytes, (size_t)len);
    if (n <= 0) break;
    bytes += n;
    len -= n;
  }
}

/* `panic` is BOTH the abort primitive the interpreter's `runtimePanic` uses to
   print an already-formatted, coded+located runtime diagnostic AND the lowering
   of a user's `panic "msg"` in a natively-compiled program.  The two want
   different framing: runtimePanic's string is complete (`f:L:C: runtime error
   [E-CODE]: msg`, or the `--json` envelope) and must print verbatim, whereas a
   raw user message needs the `runtime error [E-PANIC]:` banner so native matches
   the interpreter (loc still blocked on Core-IR-loc).  The interpreter marks its
   pre-formatted strings with a leading 0x01 sentinel byte (eval.mdk's
   runtimePanic); mdk_panic strips that and prints verbatim, else it adds the
   E-PANIC banner.  A user panic message never begins with 0x01. */
noreturn void mdk_panic(long long w) {
  mdk_flush_run_stdout_on_abort();
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  const char *bytes = cell + 24;
  if (byte_len > 0 && bytes[0] == '\x01') {
    fwrite(bytes + 1, 1, (size_t)(byte_len - 1), stderr);
  } else {
    fputs("runtime error [E-PANIC]: ", stderr);
    fwrite(bytes, 1, (size_t)byte_len, stderr);
  }
  fputc('\n', stderr);
  exit(1);
}

/* Integer divide/modulo by zero traps (LLVM emitter guards the divisor before
   the hardware sdiv/srem, whose zero-divisor behaviour is UB → silent garbage +
   exit 0).  Message matches the interpreter's runtimePanic MINUS the source
   location (Core IR carries no loc); nonzero exit. */
noreturn void mdk_div_zero(void) {
  mdk_flush_run_stdout_on_abort();
  fputs("runtime error [E-DIV-ZERO]: division by zero\n", stderr);
  exit(1);
}
noreturn void mdk_mod_zero(void) {
  mdk_flush_run_stdout_on_abort();
  fputs("runtime error [E-MOD-ZERO]: modulo by zero\n", stderr);
  exit(1);
}

/* Non-exhaustive match trap.  A compiled match whose decision tree matches no
   arm previously terminated the block with a bare `unreachable` (LLVM `ud2` →
   SIGTRAP, a silent signal death with no output).  The emitter now calls this
   before the `unreachable`, matching the interpreter's runtimePanic MINUS the
   source location (Core IR carries no loc — a located native trap is a
   follow-on); nonzero exit. */
noreturn void mdk_nonexhaustive_match(void) {
  mdk_flush_run_stdout_on_abort();
  fputs("runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match\n", stderr);
  exit(1);
}
/* A refutable block-`let` (`let (Some y) = e` with no `else`) whose scrutinee did
   not match the pattern.  The interpreter's blockLet runtimePanics
   "E-LET-REFUTE"; the emitter previously destructured with NO tag check → an OOB
   field load on a mismatching cell → SIGSEGV.  The emitter now tag-checks the
   head ctor and calls this noreturn trap on a miss, matching run's message MINUS
   the source location (Core IR carries no loc); nonzero exit. */
noreturn void mdk_let_refute(void) {
  mdk_flush_run_stdout_on_abort();
  fputs("runtime error [E-LET-REFUTE]: let pattern match failed\n", stderr);
  exit(1);
}
/* User `exit n`. Unlike the other abort paths above this carries no diagnostic
   -- it is a silent, coded-free process termination -- but it still needs the
   SAME mdk_flush_run_stdout_on_abort() call they all make: under `medaka run`
   stdout is buffered in the interpreter's outputRef and normally only printed
   by the CLI driver AFTER `main` returns, so a mid-`main` `exit` call would
   otherwise silently drop everything printed before it (the same class of bug
   as "run drops stdout on panic", just for a clean exit instead of a crash).
   For a compiled `medaka build` binary the call is a no-op (mdk_run_stdout_
   flush_enabled stays 0 there — see the block comment above), and libc's own
   exit() already flushes its real buffered stdout normally, so this is safe on
   both engines without double-printing. */
noreturn void mdk_exit(long long tagged) {
  mdk_flush_run_stdout_on_abort();
  exit((int)(tagged >> 1));
}

/* Concatenate a built-in List String (native extern catalog slice 5).
   Nil = odd immediate (low bit 1, stop); Cons = even pointer to [tag | head@8 | tail@16].
   head is a String cell (byte_len@8, bytes@24). Two passes: sum byte_lens, then blit;
   mdk_str_lit recomputes cp_count correctly. Empty list (Nil) -> "" string cell. */
long long mdk_string_concat(long long list) {
  long long total = 0;
  for (long long w = list; (w & 1) == 0; w = ((const long long *)w)[2])
    total += ((const long long *)(((const long long *)w)[1]))[1];
  char *buf = (char *)mdk_alloc_atomic(total + 1);
  long long off = 0;
  for (long long w = list; (w & 1) == 0; w = ((const long long *)w)[2]) {
    long long s = ((const long long *)w)[1];
    long long bl = ((const long long *)s)[1];
    memcpy(buf + off, (const char *)s + 24, (size_t)bl);
    off += bl;
  }
  return mdk_str_lit(buf, total);
}

/* Append two String cells (++ on String, E2a).
   String cell: [i64 tag | i64 byte_len | i64 cp_count | bytes...].
   Allocates one buffer, blits both byte spans, returns a new mdk_str_lit cell. */
long long mdk_string_append(long long a, long long b) {
  long long al = ((const long long *)a)[1];
  long long bl = ((const long long *)b)[1];
  long long total = al + bl;
  char *buf = (char *)mdk_alloc_atomic(total + 1);
  memcpy(buf,      (const char *)a + 24, (size_t)al);
  memcpy(buf + al, (const char *)b + 24, (size_t)bl);
  return mdk_str_lit(buf, total);
}

/* Append two persistent lists (++ on List, E2a).
   Walks xs collecting heads into a stack array, then conses them onto ys
   back-to-front so the result is xs ++ ys.  ys is shared (not copied). */
long long mdk_cons(long long head, long long tail);  /* defined below (slice 10) */
long long mdk_list_append(long long xs, long long ys) {
  long long n = 0;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2]) n++;
  if (n == 0) return ys;
  long long *heads = (long long *)mdk_alloc(8 * n);
  long long i = 0;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2])
    heads[i++] = ((const long long *)w)[1];
  long long acc = ys;
  for (long long j = n - 1; j >= 0; j--) acc = mdk_cons(heads[j], acc);
  return acc;
}

/* List index `xs.[i]` (Medaka EIndex on a List receiver).  A List is a chain of
 * Cons cells ([tag@0 | head@8 | tail@16], Nil = odd immediate), NOT an array, so
 * we walk the chain.  Mirrors the interpreter's listNthAt (eval.mdk): `i <= 0`
 * returns the current head (negative index returns the head, NOT a panic);
 * running off the end (hitting Nil) panics via @mdk_oob.  `idx` is a tagged Int
 * (>> 1 to untag).  Returns the stored head word verbatim. */
long long mdk_list_index(long long xs, long long idx) {
  long long i = idx >> 1;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2]) {
    if (i <= 0) return ((const long long *)w)[1];
    i--;
  }
  mdk_oob();
  return 0; /* unreachable */
}

/* List slice `xs.[lo..hi]` (Medaka ESlice on a List receiver).  Collects the
 * elements at indices [lo, hi) into a NEW list.  Mirrors the interpreter's
 * listSliceV/listSliceGo (eval.mdk): CLAMPS (no OOB panic) — walks with a running
 * index, keeps heads where lo <= i < hi, stops at hi or end-of-list.  `lo`/`hi`
 * are tagged Ints (>> 1 to untag); the emitter has already applied the inclusive
 * hi+1 adjustment.  Two passes (count then cons back-to-front) so the result is in
 * original order; the result is always Nil-terminated (mdk_nil). */
long long mdk_nil(void);
long long mdk_list_slice(long long xs, long long lo, long long hi) {
  long long l = lo >> 1, h = hi >> 1;
  long long n = 0, i = 0;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2], i++) {
    if (i >= h) break;
    if (i >= l) n++;
  }
  if (n == 0) return mdk_nil();
  long long *heads = (long long *)mdk_alloc(8 * n);
  long long k = 0;
  i = 0;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2], i++) {
    if (i >= h) break;
    if (i >= l) heads[k++] = ((const long long *)w)[1];
  }
  long long acc = mdk_nil();
  for (long long j = n - 1; j >= 0; j--) acc = mdk_cons(heads[j], acc);
  return acc;
}

/* Runtime header-dispatch fallback for `++` (Medaka concat) whose operand
 * static LTy the emitter cannot recover (census-B gap #3 residual: the
 * scanTriple/splitLines string-builders).  A `++` left operand is always
 * String or List, distinguishable at runtime:
 *   odd immediate           -> Nil (empty list)            -> list append
 *   even boxed, header==1    -> String (MDK_STR_TAG cell)  -> string append
 *   even boxed, header!=1    -> Cons cell                  -> list append
 * The result VALUE is always correct; the caller's static result LTy only
 * drives downstream instruction/print selection. */
long long mdk_append(long long a, long long b) {
  if ((a & 1) == 0 && ((const long long *)a)[0] == MDK_STR_TAG)
    return mdk_string_append(a, b);
  return mdk_list_append(a, b);
}

/* Array cell: [i64 count | elem0@8 | ...]; total 8*(count+1) bytes.
   count is raw (untagged); Int args are tagged (>> 1 to untag).
   Native extern catalog slice 7 (array leaf). */
long long mdk_array_make(long long n_tagged, long long x) {
  long long n = n_tagged >> 1;
  long long *cell = (long long *)mdk_alloc(8 * (n + 1));
  cell[0] = n;
  for (long long i = 0; i < n; i++) cell[i + 1] = x;
  return (long long)cell;
}
long long mdk_array_copy(long long src) {
  const long long *s = (const long long *)src;
  long long n = s[0];
  long long *cell = (long long *)mdk_alloc(8 * (n + 1));
  memcpy(cell, s, (size_t)(8 * (n + 1)));
  return (long long)cell;
}
void mdk_array_blit(long long src, long long so_t, long long dst,
                    long long dof_t, long long len_t) {
  const long long *s = (const long long *)src;
  long long *d = (long long *)dst;
  memmove(d + 1 + (dof_t >> 1), s + 1 + (so_t >> 1),
          (size_t)(8 * (len_t >> 1)));
}
void mdk_array_fill(long long x, long long arr) {
  long long *a = (long long *)arr;
  long long n = a[0];
  for (long long i = 0; i < n; i++) a[i + 1] = x;
}
long long mdk_array_from_list(long long list) {
  long long n = 0;
  for (long long w = list; (w & 1) == 0; w = ((const long long *)w)[2]) n++;
  long long *cell = (long long *)mdk_alloc(8 * (n + 1));
  cell[0] = n;
  long long i = 0;
  for (long long w = list; (w & 1) == 0; w = ((const long long *)w)[2])
    cell[++i] = ((const long long *)w)[1];
  return (long long)cell;
}

/* Char scalar externs (native extern catalog slice 8).
 * Char = immediate codepoint word: word = (codepoint << 1) | 1 (same tag as Int).
 * charCode is INTRINSIC (identity re-type) — no C helper needed.
 * mdk_print_char: auto-print a Char main value (UTF-8 bytes + newline).
 * mdk_char_to_str: charToStr — encode codepoint to a boxed String cell. */
static int mdk_utf8_encode(long long cp, char *out) {
  if (cp < 0x80) { out[0]=(char)cp; return 1; }
  if (cp < 0x800) {
    out[0]=(char)(0xC0|(cp>>6)); out[1]=(char)(0x80|(cp&0x3F)); return 2; }
  if (cp < 0x10000) {
    out[0]=(char)(0xE0|(cp>>12)); out[1]=(char)(0x80|((cp>>6)&0x3F));
    out[2]=(char)(0x80|(cp&0x3F)); return 3; }
  out[0]=(char)(0xF0|(cp>>18)); out[1]=(char)(0x80|((cp>>12)&0x3F));
  out[2]=(char)(0x80|((cp>>6)&0x3F)); out[3]=(char)(0x80|(cp&0x3F)); return 4;
}
void mdk_print_char(long long tagged) {
  char buf[4]; int n = mdk_utf8_encode(tagged >> 1, buf);
  fwrite(buf, 1, (size_t)n, stdout); putchar('\n');
}
long long mdk_char_to_str(long long tagged) {
  char buf[4]; int n = mdk_utf8_encode(tagged >> 1, buf);
  return mdk_str_lit(buf, n);
}

/* String↔Char + codepoint slicing (native extern catalog slice 9).
 * Char = immediate codepoint word (cp << 1) | 1 (same as Int).
 * String cell: [i64 header | i64 byte_len@8 | i64 cp_count@16 | bytes@24 | NUL]. */
static long long mdk_utf8_byte_offset(const char *p, long long byte_len,
                                      long long cpi) {
  long long b = 0, c = 0;
  while (b < byte_len && c < cpi) {
    b++;
    while (b < byte_len && ((unsigned char)p[b] & 0xC0) == 0x80) b++;
    c++;
  }
  return b;
}
static long long mdk_utf8_decode(const char *p, long long b, int *w) {
  unsigned char ch = (unsigned char)p[b];
  long long cp; int n;
  if (ch < 0x80)             { cp = ch;        n = 1; }
  else if ((ch >> 5) == 0x6) { cp = ch & 0x1F; n = 2; }
  else if ((ch >> 4) == 0xE) { cp = ch & 0x0F; n = 3; }
  else                       { cp = ch & 0x07; n = 4; }
  for (int k = 1; k < n; k++) cp = (cp << 6) | ((unsigned char)p[b+k] & 0x3F);
  *w = n; return cp;
}
long long mdk_string_to_chars(long long s) {
  const char *cell = (const char *)s;
  long long byte_len = ((const long long *)cell)[1];
  long long cp_count = ((const long long *)cell)[2];
  const char *bytes = cell + 24;
  long long *arr = (long long *)mdk_alloc(8 * (cp_count + 1));
  arr[0] = cp_count;
  long long b = 0, i = 0;
  while (b < byte_len) {
    int w; long long cp = mdk_utf8_decode(bytes, b, &w);
    arr[++i] = (cp << 1) | 1; b += w;
  }
  return (long long)arr;
}
long long mdk_string_from_chars(long long arr) {
  const long long *a = (const long long *)arr;
  long long n = a[0], total = 0; char tmp[4];
  for (long long i = 0; i < n; i++) total += mdk_utf8_encode(a[i+1] >> 1, tmp);
  char *buf = (char *)mdk_alloc(total + 1);
  long long off = 0;
  for (long long i = 0; i < n; i++) off += mdk_utf8_encode(a[i+1] >> 1, buf + off);
  return mdk_str_lit(buf, total);
}
/* stringToUtf8Bytes : String -> Array Int.  Expose the String cell's raw UTF-8
 * backing as an Array of tagged Int bytes 0..255 (O(n) copy, NO codepoint
 * re-encode).  Array cell: [i64 count | elem0@8 | ...]; Int elems are tagged. */
long long mdk_string_to_utf8_bytes(long long s) {
  const char *cell = (const char *)s;
  long long byte_len = ((const long long *)cell)[1];
  const unsigned char *bytes = (const unsigned char *)(cell + 24);
  long long *arr = (long long *)mdk_alloc(8 * (byte_len + 1));
  arr[0] = byte_len;
  for (long long i = 0; i < byte_len; i++)
    arr[i + 1] = (((long long)bytes[i]) << 1) | 1;
  return (long long)arr;
}
/* stringFromUtf8Bytes : Array Int -> String.  Blit the low 8 bits of each tagged
 * Int element into a fresh String cell.  PERMISSIVE: bytes are copied verbatim;
 * mdk_str_lit recomputes cp_count by the standard non-continuation-byte rule, so
 * valid UTF-8 round-trips byte-for-byte and codepoint-count-for-count. */
long long mdk_string_from_utf8_bytes(long long arr) {
  const long long *a = (const long long *)arr;
  long long n = a[0];
  char *buf = (char *)mdk_alloc_atomic(n + 1);
  for (long long i = 0; i < n; i++) buf[i] = (char)((a[i + 1] >> 1) & 0xFF);
  return mdk_str_lit(buf, n);
}
long long mdk_string_slice(long long lo_t, long long hi_t, long long s) {
  const char *cell = (const char *)s;
  long long byte_len = ((const long long *)cell)[1];
  long long cp_count = ((const long long *)cell)[2];
  const char *bytes = cell + 24;
  long long lo = lo_t >> 1, hi = hi_t >> 1;
  if (lo < 0) lo = 0; else if (lo > cp_count) lo = cp_count;
  if (hi < lo) hi = lo; else if (hi > cp_count) hi = cp_count;
  long long blo = mdk_utf8_byte_offset(bytes, byte_len, lo);
  long long bhi = mdk_utf8_byte_offset(bytes, byte_len, hi);
  return mdk_str_lit(bytes + blo, bhi - blo);
}

/* ── native extern catalog slice 14: ASCII char classification + case mapping ── */
/* Predicates take a tagged Char, return raw 0/1 (emitter tags to Bool). */
long long mdk_char_is_alpha(long long t) {
  long long c = t >> 1;
  return ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) ? 1 : 0;
}
long long mdk_char_is_space(long long t) {
  long long c = t >> 1;
  return (c == ' ' || (c >= 9 && c <= 13)) ? 1 : 0;
}
long long mdk_char_is_upper(long long t) {
  long long c = t >> 1;
  return (c >= 'A' && c <= 'Z') ? 1 : 0;
}
long long mdk_char_is_lower(long long t) {
  long long c = t >> 1;
  return (c >= 'a' && c <= 'z') ? 1 : 0;
}
/* charIsPunct matches Unicode general categories Pc/Pd/Pe/Pf/Pi/Po/Ps for ASCII.
   Several ASCII chars that C's ispunct() includes are Unicode symbols (Sm/Sc/Sk):
   $ + < = > ^ ` | ~  — these return 0. */
long long mdk_char_is_punct(long long t) {
  long long c = t >> 1;
  switch ((int)c) {
    case '!': case '"': case '#': case '%': case '&': case '\'':
    case '(': case ')': case '*': case ',': case '-': case '.':
    case '/': case ':': case ';': case '?': case '@': case '[':
    case '\\': case ']': case '_': case '{': case '}': return 1;
    default: return 0;
  }
}
long long mdk_char_to_upper(long long t) {
  long long c = t >> 1;
  if (c >= 'a' && c <= 'z') c -= 32;
  return (c << 1) | 1;
}
long long mdk_char_to_lower(long long t) {
  long long c = t >> 1;
  if (c >= 'A' && c <= 'Z') c += 32;
  return (c << 1) | 1;
}
/* Byte-wise ASCII case map: bytes >=0x80 (UTF-8 lead/continuation) are left
   untouched, so multibyte codepoints pass through unchanged. */
long long mdk_string_to_upper(long long s) {
  const char *cell = (const char *)s;
  long long bl = ((const long long *)cell)[1];
  const char *src = cell + 24;
  char *buf = (char *)mdk_alloc(bl + 1);
  for (long long i = 0; i < bl; i++) {
    char c = src[i];
    buf[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
  }
  return mdk_str_lit(buf, bl);
}
long long mdk_string_to_lower(long long s) {
  const char *cell = (const char *)s;
  long long bl = ((const long long *)cell)[1];
  const char *src = cell + 24;
  char *buf = (char *)mdk_alloc(bl + 1);
  for (long long i = 0; i < bl; i++) {
    char c = src[i];
    buf[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
  }
  return mdk_str_lit(buf, bl);
}

/* ── Reserved ADT tags + cell constructors (native extern catalog, slice 10) ──
 * The runtime ADTs (List, Option, Result, Ordering) get FIXED composite tags so a C
 * extern can construct their cells with a tag a later Medaka `match` agrees with.
 * These MUST stay in sync with compiler/llvm_emit.mdk `reservedTag` / `ctorTagShift`:
 *   cellTag = (reservedTypeBase + typeId) * 2^32 + ordinal.
 * Nullary ctors are IMMEDIATE ((tag<<1)|1, RUNTIME-DESIGN §8.1); ctors with fields
 * are boxed cells [i64 tag | field… ] (fields at offset 8*(i+1)), matching
 * emitCtorAlloc.  Ordinals follow core.mdk: Option = Some|None, Result = Ok|Err,
 * Ordering = Lt|Eq|Gt; List = Cons|Nil. */
#define MDK_TAG_SHIFT     4294967296LL          /* 2^32 — ctorTagShift */
#define MDK_RESERVED_BASE 65536LL               /* reservedTypeBase */
#define MDK_TAG(tid, ord) (((MDK_RESERVED_BASE + (tid)) * MDK_TAG_SHIFT) + (ord))
#define MDK_TAG_CONS MDK_TAG(0, 0)
#define MDK_TAG_NIL  MDK_TAG(0, 1)
#define MDK_TAG_SOME MDK_TAG(1, 0)
#define MDK_TAG_NONE MDK_TAG(1, 1)
#define MDK_TAG_OK   MDK_TAG(2, 0)
#define MDK_TAG_ERR  MDK_TAG(2, 1)
#define MDK_TAG_LT   MDK_TAG(3, 0)
#define MDK_TAG_EQ   MDK_TAG(3, 1)
#define MDK_TAG_GT   MDK_TAG(3, 2)

/* Nullary ctors — immediate words. */
long long mdk_none(void) { return (MDK_TAG_NONE << 1) | 1; }
long long mdk_nil(void)  { return (MDK_TAG_NIL  << 1) | 1; }
long long mdk_lt(void)   { return (MDK_TAG_LT   << 1) | 1; }
long long mdk_eq(void)   { return (MDK_TAG_EQ   << 1) | 1; }
long long mdk_gt(void)   { return (MDK_TAG_GT   << 1) | 1; }

/* Ctors with fields — boxed cells [tag | field…]. */
long long mdk_some(long long x) {
  long long *c = (long long *)mdk_alloc(16); c[0] = MDK_TAG_SOME; c[1] = x;
  return (long long)c;
}
long long mdk_ok(long long x) {
  long long *c = (long long *)mdk_alloc(16); c[0] = MDK_TAG_OK; c[1] = x;
  return (long long)c;
}
long long mdk_err(long long x) {
  long long *c = (long long *)mdk_alloc(16); c[0] = MDK_TAG_ERR; c[1] = x;
  return (long long)c;
}
long long mdk_cons(long long head, long long tail) {
  long long *c = (long long *)mdk_alloc(24); c[0] = MDK_TAG_CONS; c[1] = head; c[2] = tail;
  return (long long)c;
}

/* charFromCode : Int -> Option Char — slice-10 canary.  Valid scalar value (0..0x10FFFF
 * excluding the UTF-16 surrogate range, matching OCaml Uchar.is_valid) -> Some (Char
 * immediate); otherwise None.  Exercises both the boxed Some and immediate None
 * reserved tags end-to-end against the oracle. */
long long mdk_char_from_code(long long n_tagged) {
  long long n = n_tagged >> 1;
  if (n >= 0 && n <= 0x10FFFF && !(n >= 0xD800 && n <= 0xDFFF))
    return mdk_some((n << 1) | 1);   /* Some (Char immediate) */
  return mdk_none();
}

/* slice 11: ADT-returning string externs. */

/* Box a double as a Float cell [header=2 | double], matching emitter boxFloat. */
static long long mdk_box_float(double d) {
  long long *c = (long long *)mdk_alloc(16);
  c[0] = 2; ((double *)c)[1] = d; return (long long)c;
}

/* ── G3: polymorphic `Num a =>` arithmetic (runtime numeric dispatch) ─────────
 * A `Num a =>`-constrained function (`double x = x + x`) is monomorphic at the
 * IR level: its operand could be an immediate Int (odd word, low bit 1) OR a
 * boxed Float (even pointer to {header=2, double}).  The emitter cannot pick
 * int- vs float-instructions statically (the param type is the type variable
 * `a`), so for LTNum operands it emits a call to these helpers, which discriminate
 * on the low bit — exactly the discipline `mdk_append` uses for `++`.  At a
 * CONCRETE Int or Float type the emitter keeps its specialized inline IR (these
 * helpers are never reached), so every byte-diff gate is unchanged.
 *
 * Both operands of one `Num` op share a type (well-typed), so testing the LEFT
 * operand's tag suffices.  Int untag = >>1 (arithmetic); re-tag = (n<<1)|1. */
static inline int mdk_is_int(long long w) { return (w & 1) != 0; }

long long mdk_num_add(long long l, long long r) {
  if (mdk_is_int(l)) return (((l >> 1) + (r >> 1)) << 1) | 1;
  return mdk_box_float(((double *)l)[1] + ((double *)r)[1]);
}
long long mdk_num_sub(long long l, long long r) {
  if (mdk_is_int(l)) return (((l >> 1) - (r >> 1)) << 1) | 1;
  return mdk_box_float(((double *)l)[1] - ((double *)r)[1]);
}
long long mdk_num_mul(long long l, long long r) {
  if (mdk_is_int(l)) return (((l >> 1) * (r >> 1)) << 1) | 1;
  return mdk_box_float(((double *)l)[1] * ((double *)r)[1]);
}
long long mdk_num_div(long long l, long long r) {
  if (mdk_is_int(l)) {
    if ((r >> 1) == 0) mdk_div_zero();
    return (((l >> 1) / (r >> 1)) << 1) | 1;
  }
  return mdk_box_float(((double *)l)[1] / ((double *)r)[1]);
}
long long mdk_num_mod(long long l, long long r) {
  if (mdk_is_int(l)) {
    if ((r >> 1) == 0) mdk_mod_zero();
    return (((l >> 1) % (r >> 1)) << 1) | 1;
  }
  double a = ((double *)l)[1], b = ((double *)r)[1];
  /* #345: fmod, not `a - b*trunc(a/b)`.  The trunc-cast overflows i64 when
   * |a/b| > ~9.2e18 (e.g. 1e300 % 7) -> UB garbage -> silent wrong answer.
   * fmod matches every other `%` path (frem inline emit, mdk_float_rem, eval). */
  return mdk_box_float(fmod(a, b));
}
/* floatRem : Float -> Float -> Float — fmod, which is bit-for-bit LLVM `frem`
 * (the inline emit for `Float % Float`) so the interpreter's `%` matches build. */
double mdk_float_rem(double a, double b) {
  return fmod(a, b);
}

/* libm math shims (native/LLVM only) — each a thin wrapper over math.h.
 * The evaluator (compiler/eval/eval.mdk) calls these via the runtime.mdk
 * externs; the LLVM emitter emits direct `call double @mdk_<name>(...)`. */
double mdk_sqrt(double a) { return sqrt(a); }
double mdk_cbrt(double a) { return cbrt(a); }
double mdk_exp(double a) { return exp(a); }
double mdk_log(double a) { return log(a); }
double mdk_log2(double a) { return log2(a); }
double mdk_log10(double a) { return log10(a); }
double mdk_sin(double a) { return sin(a); }
double mdk_cos(double a) { return cos(a); }
double mdk_tan(double a) { return tan(a); }
double mdk_asin(double a) { return asin(a); }
double mdk_acos(double a) { return acos(a); }
double mdk_atan(double a) { return atan(a); }
double mdk_sinh(double a) { return sinh(a); }
double mdk_cosh(double a) { return cosh(a); }
double mdk_tanh(double a) { return tanh(a); }
double mdk_floor(double a) { return floor(a); }
double mdk_ceil(double a) { return ceil(a); }
double mdk_round(double a) { return round(a); }
double mdk_trunc(double a) { return trunc(a); }
double mdk_pow(double a, double b) { return pow(a, b); }
double mdk_atan2(double a, double b) { return atan2(a, b); }
double mdk_hypot(double a, double b) { return hypot(a, b); }

/* Print a polymorphic numeric value (LTNum result of `Num a =>` arithmetic):
 * dispatch on the runtime tag like the arithmetic helpers above. */
void mdk_print_num(long long w) {
  if (mdk_is_int(w)) mdk_print_int(w >> 1);
  else mdk_print_float(((double *)w)[1]);
}

long long mdk_string_to_float(long long s) {
  const char *cell = (const char *)s;
  long long bl = ((const long long *)cell)[1];
  const char *bytes = cell + 24;
  if (bl == 0) return mdk_none();
  char *end; errno = 0;
  double d = strtod(bytes, &end);
  if (end != bytes + bl) return mdk_none();
  return mdk_some(mdk_box_float(d));
}

long long mdk_string_index_of(long long needle, long long hay) {
  const char *nc = (const char *)needle, *hc = (const char *)hay;
  long long nl = ((const long long *)nc)[1], hl = ((const long long *)hc)[1];
  const char *nb = nc + 24, *hb = hc + 24;
  if (nl == 0) return mdk_some(1);   /* empty needle -> index 0 (Int immediate) */
  for (long long b = 0; b + nl <= hl; b++)
    if (memcmp(hb + b, nb, (size_t)nl) == 0) {
      long long cp = mdk_utf8_cp_count(hb, b);
      return mdk_some((cp << 1) | 1);
    }
  return mdk_none();
}

long long mdk_string_compare(long long a, long long b) {
  const char *ac = (const char *)a, *bc = (const char *)b;
  long long al = ((const long long *)ac)[1], bl = ((const long long *)bc)[1];
  long long m = al < bl ? al : bl;
  int c = memcmp(ac + 24, bc + 24, (size_t)m);
  if (c == 0) c = (al < bl) ? -1 : (al > bl) ? 1 : 0;
  return c < 0 ? mdk_lt() : c > 0 ? mdk_gt() : mdk_eq();
}

/* Raw three-way string compare: -1 / 0 / 1 as a PLAIN i64 (NOT a tagged Ordering
 * cell).  Backs the emitter's string ordering operators (`<`/`>`/`<=`/`>=`): the
 * emitted IR does `icmp <pred> i64 (mdk_string_compare_raw a b), 0`, mirroring the
 * `cmp <pred> 0` idiom a C `strcmp` caller uses.  (mdk_string_compare returns an
 * Ordering ADT for the `Ord String.compare` method; this is the operator path.) */
long long mdk_string_compare_raw(long long a, long long b) {
  const char *ac = (const char *)a, *bc = (const char *)b;
  long long al = ((const long long *)ac)[1], bl = ((const long long *)bc)[1];
  long long m = al < bl ? al : bl;
  int c = memcmp(ac + 24, bc + 24, (size_t)m);
  if (c == 0) c = (al < bl) ? -1 : (al > bl) ? 1 : 0;
  return c < 0 ? -1 : c > 0 ? 1 : 0;
}

/* Polymorphic three-way compare over operands whose static LTy the emitter could
 * not recover — both default to LTInt, e.g. a String/Float bound through a tuple
 * destructure inside a recursive list walk (`k <= k2` where `(k,_)`/`(k2,_)` came
 * from `(String,String)` pair fields).  An inline integer `icmp` there compares
 * boxed-String/Float POINTERS as ints — pointer-identity ordering, the heap-ADDRESS
 * bug.  This is the ordering analog of mdk_value_eq: discriminate at run time on
 * the low bit / header tag and return a PLAIN -1/0/1 i64 (like
 * mdk_string_compare_raw).  Both operands of one Ord op share a type (well-typed),
 * so testing the LEFT operand suffices:
 *   - boxed String cell (even pointer, header == MDK_STR_TAG) -> byte compare;
 *   - boxed Float cell  (even pointer, header == 2)           -> double compare;
 *   - otherwise (tagged immediate: Int/Bool/Char, or a ctor word) -> word compare
 *     of the untagged (>>1) immediates, matching the inline Int icmp path.
 * At a CONCRETE Int/Float/String type the emitter keeps its specialized inline
 * IR (the `==` peer is mdk_value_eq, which carries the same String/Float/word
 * arms — keep the two in lockstep), so this is reached only at a genuinely
 * type-unknown site.
 *
 * ⚠️ #305: the Float arm is NOT IEEE — an unordered (NaN) pair collapses to 0,
 * which reads as EQ.  A three-way -1/0/1 cannot express unorderedness at all, so
 * this function MUST NOT back a relational operator: `<`/`<=`/`>`/`>=` go through
 * mdk_value_lt/le/gt/ge, which take the Float arm themselves and only fall back
 * here for the String/immediate shapes (where -1/0/1 is exact). */
long long mdk_value_cmp_raw(long long a, long long b) {
  int a_str = ((a & 1) == 0) && ((const long long *)a)[0] == MDK_STR_TAG;
  if (a_str) return mdk_string_compare_raw(a, b);
  int a_flt = ((a & 1) == 0) && ((const long long *)a)[0] == 2;
  if (a_flt) {
    double da = ((const double *)a)[1], db = ((const double *)b)[1];
    return da < db ? -1 : da > db ? 1 : 0;
  }
  long long ia = a >> 1, ib = b >> 1;
  return ia < ib ? -1 : ia > ib ? 1 : 0;
}

/* #305 (S0) — IEEE relational predicates for the TYPE-LOST ordering path.
 * EMITTER-SEMANTICS §4 N5/N6: `<` `<=` `>` `>=` at Float are PRIMITIVE IEEE
 * predicates on EVERY path (all four FALSE at NaN) and must never be derived
 * from `compare`/value_cmp.  The 3-way -1/0/1 Ordering that mdk_value_cmp_raw
 * returns STRUCTURALLY CANNOT express NaN's unorderedness — its Float arm
 * collapses an unordered pair to 0 (EQ), so a caller doing `cmp <= 0` read
 * `nan <= nan` as TRUE.  These four answer the relational question DIRECTLY
 * for a boxed-Float operand (the same f64 compare as the inline `fcmp ole`/…
 * the emitter uses when it CAN see Float statically — so the type-lost and
 * static paths now agree), and delegate every other shape (String cell /
 * tagged immediate) to the 3-way, which is exact for those.  Returns a TAGGED
 * Bool (3 = True, 1 = False), matching mdk_value_eq.
 *
 * mdk_value_cmp_raw KEEPS its Float arm: it is a three-way answer, still used
 * for the non-Float shapes below.  But it is NOT IEEE at NaN and must never
 * again be made to back a relational operator — that is exactly bug #305.
 * (`compare`/`min`/`max`/`sort` never route here; they go through the Ord
 * dict.  Whether `compare` at NaN should be IEEE totalOrder is issue #360.) */
static int mdk_value_is_float(long long a) {
  return ((a & 1) == 0) && ((const long long *)a)[0] == 2;
}

long long mdk_value_lt(long long a, long long b) {
  if (mdk_value_is_float(a))
    return ((const double *)a)[1] < ((const double *)b)[1] ? 3 : 1;
  return mdk_value_cmp_raw(a, b) < 0 ? 3 : 1;
}

long long mdk_value_le(long long a, long long b) {
  if (mdk_value_is_float(a))
    return ((const double *)a)[1] <= ((const double *)b)[1] ? 3 : 1;
  return mdk_value_cmp_raw(a, b) <= 0 ? 3 : 1;
}

long long mdk_value_gt(long long a, long long b) {
  if (mdk_value_is_float(a))
    return ((const double *)a)[1] > ((const double *)b)[1] ? 3 : 1;
  return mdk_value_cmp_raw(a, b) > 0 ? 3 : 1;
}

long long mdk_value_ge(long long a, long long b) {
  if (mdk_value_is_float(a))
    return ((const double *)a)[1] >= ((const double *)b)[1] ? 3 : 1;
  return mdk_value_cmp_raw(a, b) >= 0 ? 3 : 1;
}

/* slice 12: args + env ---------------------------------------------------- */
static int    mdk_argc = 0;
static char **mdk_argv = 0;
void mdk_set_args(int argc, char **argv) { mdk_argc = argc; mdk_argv = argv; }

/* args : Unit -> List String — argv[1..] as Cons cells, built back-to-front. */
long long mdk_args(long long unit_ignored) {
  (void)unit_ignored;
  long long acc = mdk_nil();
  for (int i = mdk_argc - 1; i >= 1; i--)
    acc = mdk_cons(mdk_str_lit(mdk_argv[i], (long long)strlen(mdk_argv[i])), acc);
  return acc;
}

/* getEnv : String -> Option String.  name cell is NUL-terminated at +24. */
long long mdk_get_env(long long name) {
  const char *v = getenv((const char *)name + 24);
  if (v == 0) return mdk_none();
  return mdk_some(mdk_str_lit(v, (long long)strlen(v)));
}

/* slice 13: file IO + stdin readers --------------------------------------- */

/* Helper: String cell from a NUL-terminated C string. */
static long long mdk_str_cstr(const char *s) {
  return mdk_str_lit(s, (long long)strlen(s));
}

/* readFile : String -> Result String String — Ok content / Err msg.
 * fopen(2) happily opens a directory for reading, but SEEK_END+ftell then
 * reports an absurd size (LONG_MAX on ext4), which overflows mdk_alloc and
 * sends the GC after ~2^63 bytes — and even where it doesn't, fread on a
 * directory FD silently returns 0, so the caller would get a quiet "" for a
 * directory instead of an error.  Reject directories up front with S_ISDIR
 * (already used for fileType/stat below), mirroring the existing
 * mdk_err(mdk_str_cstr(strerror(errno))) shape. */
long long mdk_read_file(long long path) {
  const char *p = (const char *)path + 24;
  struct stat st;
  if (stat(p, &st) == 0 && S_ISDIR(st.st_mode))
    return mdk_err(mdk_str_cstr("Is a directory"));
  FILE *f = fopen(p, "rb");
  if (!f) return mdk_err(mdk_str_cstr(strerror(errno)));
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *buf = (char *)mdk_alloc(n + 1);
  size_t got = fread(buf, 1, (size_t)n, f); fclose(f);
  return mdk_ok(mdk_str_lit(buf, (long long)got));
}

/* readFileBytes : String -> Result String (Array Int) — raw bytes, no decode.
 * Builds an Array cell [len, b0<<1|1, b1<<1|1, ...] of TAGGED int byte values
 * 0..255 (mirrors mdk_array_from_list element tagging).
 * Same directory guard as mdk_read_file — see comment there. */
long long mdk_read_file_bytes(long long path) {
  const char *p = (const char *)path + 24;
  struct stat st;
  if (stat(p, &st) == 0 && S_ISDIR(st.st_mode))
    return mdk_err(mdk_str_cstr("Is a directory"));
  FILE *f = fopen(p, "rb");
  if (!f) return mdk_err(mdk_str_cstr(strerror(errno)));
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  unsigned char *buf = (unsigned char *)mdk_alloc(n + 1);
  size_t got = fread(buf, 1, (size_t)n, f); fclose(f);
  long long *cell = (long long *)mdk_alloc(8 * ((long long)got + 1));
  cell[0] = (long long)got;
  for (size_t i = 0; i < got; i++) cell[i + 1] = (((long long)buf[i]) << 1) | 1;
  return mdk_ok((long long)cell);
}

/* Bitwise / shift primitives.  Args arrive UNTAGGED (emitter untagInts them)
 * and the result is retagged by the emitter (tagInt: (r<<1)|1, which discards
 * the top bit so bitNot matches OCaml lnot on the 63-bit rep).  shiftRight is
 * LOGICAL: >> on the untagged non-negative 63-bit value == OCaml lsr for the
 * non-negative (binary-decoding) case. */
long long mdk_bit_and(long long a, long long b)    { return a & b; }
long long mdk_bit_or(long long a, long long b)     { return a | b; }
long long mdk_bit_xor(long long a, long long b)    { return a ^ b; }
long long mdk_shift_left(long long a, long long b)  { return a << b; }
long long mdk_shift_right(long long a, long long b) { return a >> b; }
long long mdk_bit_not(long long a)                 { return ~a; }

static long long mdk_write_impl(long long path, long long content, const char *mode) {
  const char *p = (const char *)path + 24;
  const char *c = (const char *)content + 24;
  long long cl = ((const long long *)content)[1];
  FILE *f = fopen(p, mode);
  if (!f) return mdk_err(mdk_str_cstr(strerror(errno)));
  fwrite(c, 1, (size_t)cl, f); fclose(f);
  return mdk_ok(1);  /* Ok () — Unit field, value irrelevant */
}

/* writeFile : String -> String -> Result String Unit — truncating write. */
long long mdk_write_file(long long path, long long content)  { return mdk_write_impl(path, content, "wb"); }
/* appendFile : String -> String -> Result String Unit — append (create if absent). */
long long mdk_append_file(long long path, long long content) { return mdk_write_impl(path, content, "ab"); }

/* writeFileBytes : String -> Array Int -> Result String Unit — write raw bytes.
 * arr[0] = length; arr[i+1] = tagged int byte ((byte << 1)|1) for i in 0..len-1.
 * Untag each element: (elem >> 1) & 0xFF.  Byte-clean write counterpart of
 * mdk_read_file_bytes. */
long long mdk_write_file_bytes(long long path, long long arr) {
  const char *p = (const char *)path + 24;
  const long long *a = (const long long *)arr;
  long long n = a[0];
  FILE *f = fopen(p, "wb");
  if (!f) return mdk_err(mdk_str_cstr(strerror(errno)));
  for (long long i = 0; i < n; i++) {
    unsigned char b = (unsigned char)((a[i + 1] >> 1) & 0xFF);
    fputc(b, f);
  }
  fclose(f);
  return mdk_ok(1);  /* Ok () — Unit field, value irrelevant */
}

/* fileExists : String -> Bool — raw 0/1, emitter tags via tagInt. */
long long mdk_file_exists(long long path) {
  return access((const char *)path + 24, F_OK) == 0 ? 1 : 0;
}

/* canonicalizePath : String -> String — realpath(3); input unchanged on failure
 * (matches the OCaml oracle's `try Unix.realpath p with _ -> p`). */
long long mdk_canonicalize_path(long long path) {
  const char *p = (const char *)path + 24;
  char buf[PATH_MAX];
  if (realpath(p, buf) != 0) return mdk_str_cstr(buf);
  return mdk_str_cstr(p);
}

/* listDir : String -> Result String (List String).
 * OCaml Sys.readdir excludes "." and ".." — skip them for correctness. */
long long mdk_list_dir(long long path) {
  const char *p = (const char *)path + 24;
  DIR *d = opendir(p);
  if (!d) return mdk_err(mdk_str_cstr(strerror(errno)));
  long long acc = mdk_nil(); struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    acc = mdk_cons(mdk_str_cstr(e->d_name), acc);
  }
  closedir(d);
  return mdk_ok(acc);
}

/* makeDir : String -> Result String Unit — mkdir 0755. */
long long mdk_make_dir(long long path) {
  const char *p = (const char *)path + 24;
  if (mkdir(p, 0755) == 0) return mdk_ok(1);  /* Ok () */
  return mdk_err(mdk_str_cstr(strerror(errno)));
}

/* removeFile : String -> Result String Unit — unlink(2). */
long long mdk_remove_file(long long path) {
  const char *p = (const char *)path + 24;
  if (unlink(p) == 0) return mdk_ok(1);  /* Ok () */
  return mdk_err(mdk_str_cstr(strerror(errno)));
}

/* rename : String -> String -> Result String Unit — rename(2) old new. */
long long mdk_rename(long long oldp, long long newp) {
  const char *o = (const char *)oldp + 24;
  const char *n = (const char *)newp + 24;
  if (rename(o, n) == 0) return mdk_ok(1);  /* Ok () */
  return mdk_err(mdk_str_cstr(strerror(errno)));
}

/* removeDir : String -> Result String Unit — rmdir(2); empty dir only. */
long long mdk_remove_dir(long long path) {
  const char *p = (const char *)path + 24;
  if (rmdir(p) == 0) return mdk_ok(1);  /* Ok () */
  return mdk_err(mdk_str_cstr(strerror(errno)));
}

/* runCommand : String -> List String -> Result (Int, String, String) String.
 * Spawns prog with args, captures stdout+stderr via temp files.
 * Ok (exitCode, stdout, stderr) on spawn success; Err osError on fork/exec fail.
 * Tuple cell layout: [header=TUPLE_TAG, tagged_exitcode, stdout_str, stderr_str].
 * TUPLE_TAG = hashName("$tuple") = djb2 of "$tuple" = 6950939912435. */
#define MDK_TUPLE_TAG 6950939912435LL

static long long mdk_read_temp(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return mdk_str_cstr("");
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *buf = (char *)mdk_alloc((size_t)(n + 1));
  size_t got = fread(buf, 1, (size_t)n, f); fclose(f);
  return mdk_str_lit(buf, (long long)got);
}

/* Convert a Medaka List String (linked Cons/Nil cells) into a NULL-terminated
 * C argv array.  The first slot is reserved for prog (filled by caller). */
static char **mdk_list_to_argv(long long list, int *argc_out) {
  /* Count elements first. */
  int n = 0; long long cur = list;
  while (!(cur & 1)) {  /* not an immediate (Nil is immediate) */
    long long tag = ((long long *)cur)[0];
    if (tag == MDK_TAG_CONS) { n++; cur = ((long long *)cur)[2]; } else break;
  }
  /* Allocate argv: prog + n args + NULL. */
  char **argv = (char **)malloc((size_t)(n + 2) * sizeof(char *));
  argv[0] = NULL; /* filled by caller */
  cur = list;
  for (int i = 0; i < n; i++) {
    long long cell = (long long)cur;
    long long str  = ((long long *)cell)[1];
    argv[i + 1] = (char *)str + 24;  /* UTF-8 bytes start at offset 24 */
    cur = ((long long *)cell)[2];
  }
  argv[n + 1] = NULL;
  if (argc_out) *argc_out = n + 1;
  return argv;
}

long long mdk_run_command(long long prog_w, long long args_w) {
  const char *prog = (const char *)prog_w + 24;
  /* Build argv: prog followed by the Medaka List String args. */
  int argc = 0;
  char **argv = mdk_list_to_argv(args_w, &argc);
  argv[0] = (char *)prog;

  /* Temp files for captured stdout/stderr. */
  char out_path[] = "/tmp/mdk_cmd_out_XXXXXX";
  char err_path[] = "/tmp/mdk_cmd_err_XXXXXX";
  int out_fd = mkstemp(out_path);
  int err_fd = mkstemp(err_path);
  if (out_fd < 0 || err_fd < 0) {
    free(argv);
    if (out_fd >= 0) { close(out_fd); unlink(out_path); }
    if (err_fd >= 0) { close(err_fd); unlink(err_path); }
    return mdk_err(mdk_str_cstr("mkstemp failed"));
  }

  pid_t pid = fork();
  if (pid < 0) {
    /* fork failed */
    close(out_fd); close(err_fd);
    unlink(out_path); unlink(err_path);
    free(argv);
    return mdk_err(mdk_str_cstr(strerror(errno)));
  }
  if (pid == 0) {
    /* child: redirect stdout/stderr then exec */
    dup2(out_fd, STDOUT_FILENO);
    dup2(err_fd, STDERR_FILENO);
    close(out_fd); close(err_fd);
    execvp(prog, argv);
    /* exec failed — write errno message to stderr (already dup'd) and exit */
    const char *msg = strerror(errno);
    write(STDERR_FILENO, msg, strlen(msg));
    _exit(127);
  }
  /* parent: wait for child */
  close(out_fd); close(err_fd);
  free(argv);
  int wstatus = 0;
  waitpid(pid, &wstatus, 0);
  int code = WIFEXITED(wstatus)   ? WEXITSTATUS(wstatus)
           : WIFSIGNALED(wstatus) ? 128 + WTERMSIG(wstatus) : 1;

  long long stdout_s = mdk_read_temp(out_path);
  long long stderr_s = mdk_read_temp(err_path);
  unlink(out_path); unlink(err_path);

  /* Box the 3-tuple (exitCode, stdout, stderr). */
  long long *tup = (long long *)mdk_alloc(4 * 8);
  tup[0] = MDK_TUPLE_TAG;
  tup[1] = ((long long)code << 1) | 1;  /* tagged int */
  tup[2] = stdout_s;
  tup[3] = stderr_s;
  return mdk_ok((long long)tup);
}

/* executablePath : Unit -> String — absolute path of the running executable,
 * used to derive an exe-relative default MEDAKA_ROOT for a relocated binary
 * (DISTRIBUTION-DESIGN.md D1).  Linux: readlink /proc/self/exe.  macOS:
 * _NSGetExecutablePath (may itself be a relative path or contain symlinks) —
 * realpath(3) resolves both platforms' raw path to a canonical absolute form,
 * mirroring mdk_canonicalize_path's fallback-to-raw-on-failure shape. */
long long mdk_executable_path(long long unit_ignored) {
  (void)unit_ignored;
  char buf[PATH_MAX];
#ifdef __APPLE__
  uint32_t size = sizeof(buf);
  if (_NSGetExecutablePath(buf, &size) != 0) return mdk_str_cstr("");
#else
  ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n < 0) return mdk_str_cstr("");
  buf[n] = '\0';
#endif
  char resolved[PATH_MAX];
  if (realpath(buf, resolved) != 0) return mdk_str_cstr(resolved);
  return mdk_str_cstr(buf);
}

/* buildFingerprint : Unit -> String — the compiler-source fingerprint THIS
 * binary was built from.  test/build_native_medaka.sh computes it (find
 * compiler -name '*.mdk' | sort | hash names+contents) and bakes it into the
 * ./medaka link with -DMEDAKA_SRC_FP=<hex>.  The `-D` reaches ONLY this C
 * compile of medaka_rt.c — never the emitter IR — so it is fixpoint/seed-safe.
 * Empty on every path that does not bake it (cold seed bootstrap, oracle
 * builds, a shipped/relocated binary); the driver reads "" as "skip the check"
 * (issue #89). */
#define MDK_FP_STR2(x) #x
#define MDK_FP_STR(x) MDK_FP_STR2(x)
long long mdk_build_fingerprint(long long unit_ignored) {
  (void)unit_ignored;
#ifdef MEDAKA_SRC_FP
  return mdk_str_cstr(MDK_FP_STR(MEDAKA_SRC_FP));
#else
  return mdk_str_cstr("");
#endif
}

/* statFile : String -> Result String (Int, Bool, Bool, Float).
 * stat(2) the path; Ok (sizeBytes, isDir, isFile, mtimeSeconds) or Err strerror.
 * 4-tuple cell layout mirrors mdk_run_command's 3-tuple: [TUPLE_TAG, e0..e3].
 * Bool uses the native tagged encoding (True=3, False=1); Float is boxed. */
long long mdk_stat_file(long long path) {
  const char *p = (const char *)path + 24;
  struct stat st;
  if (stat(p, &st) != 0) return mdk_err(mdk_str_cstr(strerror(errno)));
  long long *tup = (long long *)mdk_alloc(5 * 8);
  tup[0] = MDK_TUPLE_TAG;
  tup[1] = (((long long)st.st_size) << 1) | 1;   /* tagged Int size */
  tup[2] = S_ISDIR(st.st_mode) ? 3 : 1;          /* Bool isDir */
  tup[3] = S_ISREG(st.st_mode) ? 3 : 1;          /* Bool isFile */
  tup[4] = mdk_box_float((double)st.st_mtime);   /* Float mtimeSeconds */
  return mdk_ok((long long)tup);
}

/* stdin readers — implemented, NOT fixtured (gate doesn't pipe stdin). */

/* readLine : Unit -> String — one line, newline stripped. */
long long mdk_read_line(long long u) {
  (void)u;
  char *line = 0; size_t cap = 0; ssize_t n = getline(&line, &cap, stdin);
  if (n < 0) { free(line); return mdk_str_cstr(""); }
  if (n > 0 && line[n-1] == '\n') n--;
  long long r = mdk_str_lit(line, (long long)n); free(line); return r;
}

/* readLineOpt : Unit -> Option String — Some line / None at EOF. */
long long mdk_read_line_opt(long long u) {
  (void)u;
  char *line = 0; size_t cap = 0; ssize_t n = getline(&line, &cap, stdin);
  if (n < 0) { free(line); return mdk_none(); }
  if (n > 0 && line[n-1] == '\n') n--;
  long long r = mdk_some(mdk_str_lit(line, (long long)n)); free(line); return r;
}

/* readExactly : Int -> Option String — read exactly N bytes; None at EOF or short read. */
long long mdk_read_exactly(long long n_tagged) {
  long long n = n_tagged >> 1;  /* untag Int */
  if (n <= 0) return mdk_some(mdk_str_lit("", 0));
  char *buf = (char *)malloc((size_t)n);
  size_t total = 0;
  while (total < (size_t)n) {
    size_t got = fread(buf + total, 1, (size_t)n - total, stdin);
    if (got == 0) break;
    total += got;
  }
  if (total == 0) { free(buf); return mdk_none(); }
  if ((long long)total < n) { free(buf); return mdk_none(); }
  long long r = mdk_some(mdk_str_lit(buf, (long long)total)); free(buf); return r;
}

/* readAll : Unit -> String — all of stdin. */
long long mdk_read_all(long long u) {
  (void)u;
  size_t cap = 4096, len = 0; char *buf = (char *)malloc(cap);
  for (;;) {
    if (len == cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
    size_t got = fread(buf + len, 1, cap - len, stdin); len += got;
    if (got == 0) break;
  }
  long long r = mdk_str_lit(buf, (long long)len); free(buf); return r;
}

/* ── RNG — deterministic SplitMix64 (native extern catalog, Tier D) ───────────
 * The SAME algorithm runs in the tree-walker oracle (lib/eval.ml splitmix64_next),
 * seeded identically, so random* output is byte-identical per seed and stable
 * across backends (project decision 2026-06-07). State is a uint64; default 0;
 * mdk_set_seed sets it. Range semantics preserved from the old oracle: randomInt
 * INCLUSIVE [lo,hi]; randomFloat in [-1,1); randomChar ASCII [32,126]. */
static unsigned long long mdk_rng_state = 0;

static unsigned long long mdk_next_u64(void) {
  mdk_rng_state += 0x9E3779B97F4A7C15ULL;
  unsigned long long z = mdk_rng_state;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

void mdk_set_seed(long long tagged) {        /* setSeed : Int -> Unit */
  mdk_rng_state = (unsigned long long)(tagged >> 1);
}
/* randomInt : Int -> Int -> Int (INCLUSIVE).  Returns a RAW int — the emitter tags it. */
long long mdk_random_int(long long lo_t, long long hi_t) {
  long long lo = lo_t >> 1, hi = hi_t >> 1;
  long long range = hi - lo + 1;
  if (range <= 0) return lo;
  return lo + (long long)(mdk_next_u64() % (unsigned long long)range);
}
long long mdk_random_bool(long long u) { (void)u;  /* RAW 0/1 — emitter tags to Bool */
  return (long long)(mdk_next_u64() & 1ULL);
}
long long mdk_random_float(long long u) { (void)u;  /* boxed Float word */
  unsigned long long bits = mdk_next_u64() >> 11;
  return mdk_box_float((double)bits * (1.0 / 9007199254740992.0) * 2.0 - 1.0);
}
long long mdk_random_char(long long u) { (void)u;  /* RAW codepoint — emitter tags to Char */
  return 32 + (long long)(mdk_next_u64() % 95ULL);
}

/* ── Hashable per-type hashers — SPECIFIED, byte-identical to lib/eval.ml ──────
 * The old structural `__hashRaw` (OCaml Hashtbl.hash) can't run here: this runtime
 * is type-erased, so one i64 word can't tell a tagged Int from a String pointer
 * and so can't content-hash a boxed value (equal Strings would pointer-hash
 * differently → hash_map String keys break).  Fix (the RNG playbook): each typed
 * `Hashable` impl calls one of these, specified IDENTICALLY here and in
 * lib/eval.ml (hash_*), so the hash is byte-identical across backends.  All math
 * is uint64 + masked to [0, 2^30) — NON-NEGATIVE (hash_map does `hash % cap`).
 * Each helper takes the NATIVE arg the emitter unpacks (untagged int / codepoint /
 * String cell pointer / double) and returns a RAW int the emitter tags. */
#define MDK_HASH_MASK 0x3FFFFFFFULL   /* 2^30 - 1 */

/* SplitMix64 finalizer, as a pure mixer.  == hash_mix64 (OCaml). */
static unsigned long long mdk_hash_mix64(unsigned long long x) {
  unsigned long long z = x + 0x9E3779B97F4A7C15ULL;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}
/* hashInt : Int -> Int.  `n` is the UNTAGGED int (emitter untags). */
long long mdk_hash_int(long long n) {
  return (long long)(mdk_hash_mix64((unsigned long long)n) & MDK_HASH_MASK);
}
/* hashChar : Char -> Int.  `cp` is the UNTAGGED codepoint — same mix as hashInt. */
long long mdk_hash_char(long long cp) {
  return (long long)(mdk_hash_mix64((unsigned long long)cp) & MDK_HASH_MASK);
}
/* hashBool : Bool -> Int.  `b` is 0/1 (already non-negative). */
long long mdk_hash_bool(long long b) { return b ? 1 : 0; }
/* hashFloat : Float -> Int.  `d` is the unboxed double; bit-cast to u64 then mix.
 * -0.0 and 0.0 have distinct bit patterns and so hash differently — acceptable. */
long long mdk_hash_float(double d) {
  unsigned long long bits; memcpy(&bits, &d, 8);
  return (long long)(mdk_hash_mix64(bits) & MDK_HASH_MASK);
}
/* hashString : String -> Int.  FNV-1a over the cell's raw UTF-8 bytes (byte_len@8,
 * bytes@24).  offset basis 0xCBF29CE484222325, prime 0x100000001B3. */
long long mdk_hash_string(long long w) {
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  const unsigned char *bytes = (const unsigned char *)(cell + 24);
  unsigned long long h = 0xCBF29CE484222325ULL;
  for (long long i = 0; i < byte_len; i++)
    h = (h ^ (unsigned long long)bytes[i]) * 0x100000001B3ULL;
  return (long long)(h & MDK_HASH_MASK);
}

/* intBitsToFloat : Int -> Float.  Reinterpret the 64-bit pattern of the
 * (untagged) Medaka Int `n` as an IEEE 754 double and return a boxed Float.
 * The emitter calls untagInt before passing `n`, so `n` is the raw value. */
long long mdk_int_bits_to_float(long long n) {
  double d; memcpy(&d, &n, 8);
  return mdk_box_float(d);
}
/* bytesToFloat64 : Array Int -> Int -> Float.  Read 8 bytes big-endian from
 * a Medaka Array-of-Int cell starting at element index `off`.
 * Array cell layout: [i64 count | i64 elem0 | i64 elem1 | ...].
 * Each element is a TAGGED Medaka Int (value * 2 + 1); untag by >> 1.
 * `off` is also a tagged int passed from the emitter (untagged before call).
 * Returns a boxed Float. */
long long mdk_bytes_to_float64(long long arr_word, long long off) {
  const long long *a = (const long long *)arr_word;
  /* a[0] = count (raw, untagged); `off` is already untagged (emitter untags it).
   * Reads 8 elements a[1+off+0..7]; bounds-check to prevent an OOB heap read. */
  if (off < 0 || off + 8 > a[0]) mdk_oob();
  /* a[0] = count; a[1+i] = element i (TAGGED: raw >> 1 to get byte value) */
  unsigned long long bits =
    ((unsigned long long)((a[1 + off + 0] >> 1) & 0xFF) << 56) |
    ((unsigned long long)((a[1 + off + 1] >> 1) & 0xFF) << 48) |
    ((unsigned long long)((a[1 + off + 2] >> 1) & 0xFF) << 40) |
    ((unsigned long long)((a[1 + off + 3] >> 1) & 0xFF) << 32) |
    ((unsigned long long)((a[1 + off + 4] >> 1) & 0xFF) << 24) |
    ((unsigned long long)((a[1 + off + 5] >> 1) & 0xFF) << 16) |
    ((unsigned long long)((a[1 + off + 6] >> 1) & 0xFF) <<  8) |
    ((unsigned long long)((a[1 + off + 7] >> 1) & 0xFF)      );
  double d; memcpy(&d, &bits, 8);
  return mdk_box_float(d);
}

/* floatToBytes64 : Float -> Array Int.  Encode `d` as 8 big-endian IEEE 754
 * bytes and return a Medaka Array of 8 tagged Ints (each 0..255).
 * The emitter calls unboxFloat before passing, so `d` arrives as a raw double.
 * Array cell layout: [i64 count=8 | tagged_byte0 | ... | tagged_byte7].
 * Tagged Int encoding: (byte << 1) | 1 (same as all Medaka Int immediates). */
long long mdk_float_to_bytes64(double d) {
  unsigned long long bits;
  memcpy(&bits, &d, 8);
  long long *cell = (long long *)mdk_alloc(8 * 9);  /* 9 words: count + 8 elems */
  cell[0] = 8;  /* count (raw, untagged) */
  for (long long i = 0; i < 8; i++) {
    unsigned char b = (unsigned char)((bits >> (8 * (7 - i))) & 0xFF);
    cell[i + 1] = ((long long)b << 1) | 1;  /* tag as Medaka Int */
  }
  return (long long)cell;
}

/* ── debug literal externs — quoted/escaped rendering, byte-exact, no oracle ───
 * Mirror escape_string_lit / escape_char_lit in lib/eval.ml (the same escapes the
 * lexer's read_string/read_char understand), so `debug` of a String/Char round-
 * trips to valid source.  Output is boxed via mdk_str_lit. */

/* Append the escaped form of one byte to buf[*off], advancing *off. */
static void mdk_escape_byte(char *buf, long long *off, unsigned char c, char quote) {
  switch (c) {
    case '\\': buf[(*off)++]='\\'; buf[(*off)++]='\\'; break;
    case '\n': buf[(*off)++]='\\'; buf[(*off)++]='n';  break;
    case '\t': buf[(*off)++]='\\'; buf[(*off)++]='t';  break;
    case '\r': buf[(*off)++]='\\'; buf[(*off)++]='r';  break;
    case '\0': buf[(*off)++]='\\'; buf[(*off)++]='0';  break;
    default:
      if (c == (unsigned char)quote) { buf[(*off)++]='\\'; buf[(*off)++]=(char)c; }
      else buf[(*off)++]=(char)c;
  }
}
/* debugStringLit : String -> String  ->  "\"" + escape(bytes) + "\"" */
long long mdk_debug_string_lit(long long w) {
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  const unsigned char *bytes = (const unsigned char *)(cell + 24);
  char *buf = (char *)mdk_alloc(2 + 2 * byte_len + 1);  /* worst case 2 bytes/char */
  long long off = 0;
  buf[off++] = '"';
  for (long long i = 0; i < byte_len; i++) mdk_escape_byte(buf, &off, bytes[i], '"');
  buf[off++] = '"';
  return mdk_str_lit(buf, off);
}
/* debugCharLit : Char -> String  ->  "'" + escape(codepoint) + "'".  `cp` UNTAGGED.
 * Escape the control bytes like escape_char_lit; otherwise UTF-8-encode the cp. */
long long mdk_debug_char_lit(long long cp) {
  char enc[4]; int n = mdk_utf8_encode(cp, enc);
  char buf[16]; long long off = 0;
  buf[off++] = '\'';
  if (n == 1) mdk_escape_byte(buf, &off, (unsigned char)enc[0], '\'');
  else for (int i = 0; i < n; i++) buf[off++] = enc[i];
  buf[off++] = '\'';
  return mdk_str_lit(buf, off);
}

/* ── perf / instrumentation externs ────────────────────────────────────────────
 * wallTimeSec : Unit -> <IO> Float   — wall-clock seconds (gettimeofday).
 * allocBytes  : Unit -> <IO> Float   — total GC-heap bytes allocated since start.
 * Both return a boxed Float word (mdk_box_float), identical ABI to randomFloat. */

long long mdk_wall_time_sec(long long u) { (void)u;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return mdk_box_float((double)tv.tv_sec + (double)tv.tv_usec * 1e-6);
}

long long mdk_alloc_bytes(long long u) { (void)u;
  return mdk_box_float((double)GC_get_total_bytes());
}

/* monotonicSec : Unit -> <Clock> Float — monotonic clock seconds (immune to
 * wall-clock adjustment).  clock_gettime(CLOCK_MONOTONIC) is POSIX and available
 * on macOS.  Boxed Float, same ABI as wallTimeSec. */
long long mdk_monotonic_sec(long long u) { (void)u;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return mdk_box_float((double)ts.tv_sec + (double)ts.tv_nsec * 1e-9);
}

/* sleepMs : Int -> <Clock> Unit — sleep N milliseconds via nanosleep.  `ms_t` is
 * the TAGGED Int (>>1 to untag), mirroring mdk_set_seed's ABI.  Returns nothing. */
void mdk_sleep_ms(long long ms_t) {
  long long ms = ms_t >> 1;
  if (ms <= 0) return;
  struct timespec req;
  req.tv_sec = ms / 1000;
  req.tv_nsec = (ms % 1000) * 1000000L;
  nanosleep(&req, NULL);
}

/* ── Networking (NET-DESIGN.md) ──────────────────────────────────────────────
 * Thin blocking BSD-socket shims mirroring the file-extern ABI: String args at
 * ptr+24, tagged Int args (>>1 to untag), Result via mdk_ok/mdk_err, errno mapped
 * through strerror.  fds traffic as tagged Int ((fd<<1)|1) exactly like every Int.
 * Native-only; the wasm backend rejects the whole net set. */

#define MDK_NET_UNTAG(x) ((int)((long long)(x) >> 1))
#define MDK_NET_TAG(v)   ((((long long)(v)) << 1) | 1)

/* Belt-and-suspenders SIGPIPE guard (F7): ignore process-wide so a write to a
 * closed peer surfaces as EPIPE (a Result Err) instead of killing the process.
 * Per-socket SO_NOSIGPIPE / per-send MSG_NOSIGNAL below add the platform-specific
 * belt.  Runs before main via the constructor attribute. */
__attribute__((constructor)) static void mdk_net_sigpipe_init(void) {
  signal(SIGPIPE, SIG_IGN);
}

/* netResolve : String -> Result String (List String) — getaddrinfo -> numeric IPs. */
long long mdk_net_resolve(long long host_cell) {
  const char *host = (const char *)host_cell + 24;
  struct addrinfo hints = {0}, *res, *ai;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int gai = getaddrinfo(host, NULL, &hints, &res);
  if (gai != 0) return mdk_err(mdk_str_cstr(gai_strerror(gai)));
  long long acc = mdk_nil();
  char buf[INET6_ADDRSTRLEN];
  for (ai = res; ai; ai = ai->ai_next) {
    const char *s = NULL;
    if (ai->ai_family == AF_INET)
      s = inet_ntop(AF_INET, &((struct sockaddr_in *)ai->ai_addr)->sin_addr, buf, sizeof buf);
    else if (ai->ai_family == AF_INET6)
      s = inet_ntop(AF_INET6, &((struct sockaddr_in6 *)ai->ai_addr)->sin6_addr, buf, sizeof buf);
    if (s) acc = mdk_cons(mdk_str_cstr(s), acc);
  }
  freeaddrinfo(res);
  return mdk_ok(acc);
}

/* netTcpConnect : host -> port -> Result String Int (connected fd). */
long long mdk_net_tcp_connect(long long host_cell, long long port_tagged) {
  const char *host = (const char *)host_cell + 24;
  char port[16]; snprintf(port, sizeof port, "%d", MDK_NET_UNTAG(port_tagged));
  struct addrinfo hints = {0}, *res, *ai;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int gai = getaddrinfo(host, port, &hints, &res);
  if (gai != 0) return mdk_err(mdk_str_cstr(gai_strerror(gai)));
  int fd = -1, last = 0;
  for (ai = res; ai; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) { last = errno; continue; }
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
    last = errno; close(fd); fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) return mdk_err(mdk_str_cstr(strerror(last)));
#ifdef SO_NOSIGPIPE
  { int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on); }
#endif
  return mdk_ok(MDK_NET_TAG(fd));
}

/* netTcpListen : bindAddr -> port (0=ephemeral) -> Result String Int (listening fd). */
long long mdk_net_tcp_listen(long long addr_cell, long long port_tagged) {
  const char *addr = (const char *)addr_cell + 24;
  char port[16]; snprintf(port, sizeof port, "%d", MDK_NET_UNTAG(port_tagged));
  struct addrinfo hints = {0}, *res;
  hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
  int gai = getaddrinfo(addr[0] ? addr : NULL, port, &hints, &res);
  if (gai != 0) return mdk_err(mdk_str_cstr(gai_strerror(gai)));
  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if (fd < 0) { int e = errno; freeaddrinfo(res); return mdk_err(mdk_str_cstr(strerror(e))); }
  { int on = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on); }
  if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, 128) != 0) {
    int e = errno; close(fd); freeaddrinfo(res); return mdk_err(mdk_str_cstr(strerror(e)));
  }
  freeaddrinfo(res);
  return mdk_ok(MDK_NET_TAG(fd));
}

/* netListenPort : fd -> Result String Int (actual bound port; for port-0 ephemeral). */
long long mdk_net_listen_port(long long fd_tagged) {
  struct sockaddr_storage ss; socklen_t len = sizeof ss;
  if (getsockname(MDK_NET_UNTAG(fd_tagged), (struct sockaddr *)&ss, &len) != 0)
    return mdk_err(mdk_str_cstr(strerror(errno)));
  int port = (ss.ss_family == AF_INET6)
    ? ntohs(((struct sockaddr_in6 *)&ss)->sin6_port)
    : ntohs(((struct sockaddr_in  *)&ss)->sin_port);
  return mdk_ok(MDK_NET_TAG(port));
}

/* netTcpAccept : listening fd -> Result String Int (accepted connection fd; blocks). */
long long mdk_net_tcp_accept(long long lis_tagged) {
  int c = accept(MDK_NET_UNTAG(lis_tagged), NULL, NULL);
  if (c < 0) return mdk_err(mdk_str_cstr(strerror(errno)));
#ifdef SO_NOSIGPIPE
  { int on = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on); }
#endif
  return mdk_ok(MDK_NET_TAG(c));
}

/* netSend : fd -> Array Int -> Result String Int (count written).
 * Array cell = [len (raw), tagged byte...]; untag each byte to 0..255. */
long long mdk_net_send(long long fd_tagged, long long arr) {
  const long long *a = (const long long *)arr;
  long long n = a[0];
  unsigned char *buf = (unsigned char *)mdk_alloc(n ? n : 1);
  for (long long i = 0; i < n; i++) buf[i] = (unsigned char)((a[i + 1] >> 1) & 0xFF);
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags = MSG_NOSIGNAL;
#endif
  ssize_t w = send(MDK_NET_UNTAG(fd_tagged), buf, (size_t)n, flags);
  if (w < 0) return mdk_err(mdk_str_cstr(strerror(errno)));
  return mdk_ok(MDK_NET_TAG((long long)w));
}

/* netRecv : fd -> maxBytes -> Result String (Array Int).  Empty Array = EOF/peer-closed.
 * Array cell = [len (raw), tagged byte...] matching mdk_read_file_bytes. */
long long mdk_net_recv(long long fd_tagged, long long max_tagged) {
  long long max = max_tagged >> 1;
  unsigned char *buf = (unsigned char *)mdk_alloc(max > 0 ? max : 1);
  ssize_t r = recv(MDK_NET_UNTAG(fd_tagged), buf, (size_t)(max > 0 ? max : 0), 0);
  if (r < 0) return mdk_err(mdk_str_cstr(strerror(errno)));
  long long *cell = (long long *)mdk_alloc(8 * (r + 1));
  cell[0] = (long long)r;
  for (ssize_t i = 0; i < r; i++) cell[i + 1] = (((long long)buf[i]) << 1) | 1;
  return mdk_ok((long long)cell);
}

/* netShutdown : fd -> how (0=read,1=write,2=both) -> Result String Unit. */
long long mdk_net_shutdown(long long fd_tagged, long long how_tagged) {
  int how = MDK_NET_UNTAG(how_tagged);
  int sw = how == 0 ? SHUT_RD : (how == 1 ? SHUT_WR : SHUT_RDWR);
  if (shutdown(MDK_NET_UNTAG(fd_tagged), sw) != 0 && errno != ENOTCONN)
    return mdk_err(mdk_str_cstr(strerror(errno)));
  return mdk_ok(1);  /* Ok () */
}

/* netClose : fd -> Result String Unit — close(2); idempotent-safe. */
long long mdk_net_close(long long fd_tagged) {
  int fd = MDK_NET_UNTAG(fd_tagged);
  if (fd < 0) return mdk_ok(1);
  if (close(fd) != 0 && errno != EBADF) return mdk_err(mdk_str_cstr(strerror(errno)));
  return mdk_ok(1);  /* Ok () */
}

/* netSetTimeout : fd -> milliseconds (0=blocking) -> Result String Unit.
 * Installs SO_RCVTIMEO + SO_SNDTIMEO so a hung peer surfaces as a Result Err. */
long long mdk_net_set_timeout(long long fd_tagged, long long ms_tagged) {
  long long ms = ms_tagged >> 1;
  int fd = MDK_NET_UNTAG(fd_tagged);
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) != 0)
    return mdk_err(mdk_str_cstr(strerror(errno)));
  if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv) != 0)
    return mdk_err(mdk_str_cstr(strerror(errno)));
  return mdk_ok(1);  /* Ok () */
}

/* ---------------------------------------------------------------------------
 * Process entry.  The emitted IR's entry point is `mdk_program_main` (renamed
 * from `@main` in compiler/backend/llvm_emit.mdk); this runtime owns the real
 * C `main`.  We run the whole Medaka pipeline on a dedicated worker thread with
 * a 256 MB stack: Medaka's lexer/parser recurse deeply, and the Linux default
 * 8 MB thread stack overflows on large inputs (macOS previously baked a 512 MB
 * stack via the Mach-O-only `-Wl,-stack_size` link flag, which GNU ld rejects).
 * Self-provisioning the stack here removes the reliance on that link flag on
 * both platforms.
 *
 * The worker MUST be created via GC_pthread_create (GC_THREADS is defined above
 * <gc.h>) so Boehm registers the worker's stack as a GC root; a raw
 * pthread_create'd thread would be invisible to the collector and its live
 * objects would be reclaimed mid-run. */
extern int mdk_program_main(int argc, char **argv);

struct mdk_main_args {
  int argc;
  char **argv;
  int ret;
};

/* ---------------------------------------------------------------------------
 * P0-2: "no silent death" signal backstop.  The tree-walking interpreter and
 * deeply-recursive compiled programs can exhaust the 256 MB worker stack; the
 * kernel then delivers SIGSEGV/SIGBUS and, with no handler, the process dies
 * with a bare signal and ZERO output.  We install a SIGSEGV/SIGBUS handler on a
 * dedicated `sigaltstack` (so it can run even when the worker stack is fully
 * exhausted) that prints a clean, coded diagnostic and exits nonzero.
 *
 * Boehm coexistence: without incremental mode (we never call
 * GC_enable_incremental), Boehm does not keep a live SIGSEGV handler during
 * normal operation on the run path.  We nonetheless install AFTER GC_INIT (the
 * `__attribute__((constructor)) mdk_gc_init` runs before `main`) and capture the
 * previous handler via sigaction; for any fault that is NOT stack-overflow-shaped
 * we CHAIN to that previous handler (so a legitimate GC-owned fault, if one ever
 * exists, is still serviced), and only if there is none do we print a generic
 * message and exit — never a silent death.  Only signal-async-safe calls
 * (write/_exit) run in the handler; no allocation, no stdio. */
static char mdk_sigaltstack[256 * 1024];   /* alt stack for the fault handler */
static char *mdk_stack_lo = NULL;          /* worker stack low  address */
static char *mdk_stack_hi = NULL;          /* worker stack high address */
static struct sigaction mdk_old_segv;
static struct sigaction mdk_old_bus;

/* Is `addr` within (or just below the guard page of) the worker stack? */
static int mdk_addr_near_stack(void *addr) {
  if (!addr || !mdk_stack_lo || !mdk_stack_hi) return 0;
  char *a = (char *)addr;
  /* Allow a slack window below the mapped stack for the guard region. */
  return a >= (mdk_stack_lo - (1 << 20)) && a <= mdk_stack_hi;
}

static void mdk_chain_previous(int sig, siginfo_t *info, void *uctx) {
  struct sigaction *old = (sig == SIGBUS) ? &mdk_old_bus : &mdk_old_segv;
  if (old->sa_flags & SA_SIGINFO) {
    if (old->sa_sigaction) { old->sa_sigaction(sig, info, uctx); return; }
  } else if (old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN) {
    old->sa_handler(sig);
    return;
  }
  /* No previous handler: no silent death — print generic and exit nonzero.
     mdk_flush_run_stdout_on_abort is async-signal-safe (word reads + write(2)
     only, no allocation, no stdio) — see its definition near mdk_putstr.
     mdk_flush_build_stdout_on_fatal_signal is its build-binary counterpart
     (same discipline; see its definition near mdk_fwrite_str) — both are
     no-ops unless the corresponding engine actually populated their buffer, so
     calling both here is safe regardless of which engine is running. */
  mdk_flush_run_stdout_on_abort();
  mdk_flush_build_stdout_on_fatal_signal();
  static const char m[] =
    "runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)\n";
  write(2, m, sizeof(m) - 1);
  _exit(139);
}

static void mdk_fault_handler(int sig, siginfo_t *info, void *uctx) {
  if (mdk_addr_near_stack(info ? info->si_addr : NULL)) {
    mdk_flush_run_stdout_on_abort();
    mdk_flush_build_stdout_on_fatal_signal();
    static const char m[] =
      "runtime error [E-STACK-OVERFLOW]: stack overflow (recursion too deep)\n";
    write(2, m, sizeof(m) - 1);
    _exit(134);
  }
  mdk_chain_previous(sig, info, uctx);
}

/* Install the alt stack (per-thread) + the SIGSEGV/SIGBUS handlers.  Called on
 * the worker thread, after its stack bounds have been recorded. */
static void mdk_install_fault_handler(void) {
  stack_t ss;
  ss.ss_sp = mdk_sigaltstack;
  ss.ss_size = sizeof(mdk_sigaltstack);
  ss.ss_flags = 0;
  if (sigaltstack(&ss, NULL) != 0) return;  /* best-effort; skip if unavailable */

  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = mdk_fault_handler;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, &mdk_old_segv);
  sigaction(SIGBUS, &sa, &mdk_old_bus);
}

/* Record the running (worker) thread's stack bounds for the fault handler. */
static void mdk_record_stack_bounds(void) {
#ifdef __APPLE__
  void *hi = pthread_get_stackaddr_np(pthread_self());  /* high addr (top) */
  size_t sz = pthread_get_stacksize_np(pthread_self());
  mdk_stack_hi = (char *)hi;
  mdk_stack_lo = (char *)hi - sz;
#else
  pthread_attr_t at;
  if (pthread_getattr_np(pthread_self(), &at) == 0) {
    void *base;
    size_t sz;
    if (pthread_attr_getstack(&at, &base, &sz) == 0) {
      mdk_stack_lo = (char *)base;
      mdk_stack_hi = (char *)base + sz;
    }
    pthread_attr_destroy(&at);
  }
#endif
}

static void *mdk_main_thread(void *p) {
  struct mdk_main_args *a = (struct mdk_main_args *)p;
  mdk_record_stack_bounds();
  mdk_install_fault_handler();
  a->ret = mdk_program_main(a->argc, a->argv);
  return NULL;
}

int main(int argc, char **argv) {
  struct mdk_main_args a;
  a.argc = argc;
  a.argv = argv;
  a.ret = 0;

  pthread_attr_t attr;
  if (pthread_attr_init(&attr) != 0) {
    fprintf(stderr, "medaka: pthread_attr_init failed\n");
    return 1;
  }
  /* 256 MB: comfortably over the ~32 MB (-O2) / ~128 MB (-O0) measured need. */
  if (pthread_attr_setstacksize(&attr, (size_t)256 * 1024 * 1024) != 0) {
    fprintf(stderr, "medaka: pthread_attr_setstacksize failed\n");
    return 1;
  }

  pthread_t tid;
  int rc = GC_pthread_create(&tid, &attr, mdk_main_thread, &a);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    fprintf(stderr, "medaka: GC_pthread_create failed\n");
    return 1;
  }
  GC_pthread_join(tid, NULL);
  return a.ret;
}
