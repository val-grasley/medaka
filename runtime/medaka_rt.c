/* Medaka native runtime — Stage 2.4 DE-RISKING SPIKE (slices 1–3).
 *
 * This is NOT the real runtime.  It is the minimal C stub the spike's emitted
 * LLVM IR links against to prove the emit -> clang -> link -> run -> diff
 * toolchain end-to-end (see selfhost/STAGE2-DESIGN.md §2.4 and the "Value
 * representation & calling convention" section of selfhost/RUNTIME-DESIGN.md).
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
  char *cell = (char *)mdk_alloc(24 + byte_len + 1);
  ((long long *)cell)[0] = MDK_STR_TAG;
  ((long long *)cell)[1] = byte_len;
  ((long long *)cell)[2] = mdk_utf8_cp_count(bytes, byte_len);
  memcpy(cell + 24, bytes, (size_t)byte_len);
  cell[24 + byte_len] = '\0';
  return (long long)cell;
}

/* Print a String RAW (no quoting).  Matches Eval.pp_value (VString s) = s, then
 * the oracle's trailing newline (eval_probe / selfhost ppValue). */
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
  char buf[64];
  snprintf(buf, sizeof buf, "%.12g", d);
  if (!strchr(buf, '.') && !strchr(buf, 'e') &&
      !strchr(buf, 'n') && !strchr(buf, 'i')) /* skip nan/inf */
    strcat(buf, ".");
  return mdk_str_lit(buf, (long long)strlen(buf));
}

/* IO-output externs (native extern catalog slice 3).
   mdk_fwrite_str reads the string cell (bytes at offset 24, byte_len at offset 8)
   and writes to the given FILE; appends '\n' iff nl != 0. */
static void mdk_fwrite_str(long long w, FILE *out, int nl) {
  const char *cell = (const char *)w;
  long long byte_len = ((const long long *)cell)[1];
  fwrite(cell + 24, 1, (size_t)byte_len, out);
  if (nl) fputc('\n', out);
}

void mdk_putstr(long long w)    { mdk_fwrite_str(w, stdout, 0); }
void mdk_putstrln(long long w)  { mdk_fwrite_str(w, stdout, 1); }
void mdk_eputstr(long long w)   { mdk_fwrite_str(w, stderr, 0); }
void mdk_eputstrln(long long w) { mdk_fwrite_str(w, stderr, 1); }
void mdk_print_unit(void)       { printf("()\n"); }

noreturn void mdk_panic(long long w) { mdk_fwrite_str(w, stderr, 1); exit(1); }
noreturn void mdk_exit(long long tagged) { exit((int)(tagged >> 1)); }

/* Concatenate a built-in List String (native extern catalog slice 5).
   Nil = odd immediate (low bit 1, stop); Cons = even pointer to [tag | head@8 | tail@16].
   head is a String cell (byte_len@8, bytes@24). Two passes: sum byte_lens, then blit;
   mdk_str_lit recomputes cp_count correctly. Empty list (Nil) -> "" string cell. */
long long mdk_string_concat(long long list) {
  long long total = 0;
  for (long long w = list; (w & 1) == 0; w = ((const long long *)w)[2])
    total += ((const long long *)(((const long long *)w)[1]))[1];
  char *buf = (char *)mdk_alloc(total + 1);
  long long off = 0;
  for (long long w = list; (w & 1) == 0; w = ((const long long *)w)[2]) {
    long long s = ((const long long *)w)[1];
    long long bl = ((const long long *)s)[1];
    memcpy(buf + off, (const char *)s + 24, (size_t)bl);
    off += bl;
  }
  return mdk_str_lit(buf, total);
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
