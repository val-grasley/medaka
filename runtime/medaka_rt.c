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
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdnoreturn.h>
#include <unistd.h>
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

/* Append two String cells (++ on String, E2a).
   String cell: [i64 tag | i64 byte_len | i64 cp_count | bytes...].
   Allocates one buffer, blits both byte spans, returns a new mdk_str_lit cell. */
long long mdk_string_append(long long a, long long b) {
  long long al = ((const long long *)a)[1];
  long long bl = ((const long long *)b)[1];
  long long total = al + bl;
  char *buf = (char *)mdk_alloc(total + 1);
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
 * These MUST stay in sync with selfhost/llvm_emit.mdk `reservedTag` / `ctorTagShift`:
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

/* readFile : String -> Result String String — Ok content / Err msg. */
long long mdk_read_file(long long path) {
  const char *p = (const char *)path + 24;
  FILE *f = fopen(p, "rb");
  if (!f) return mdk_err(mdk_str_cstr(strerror(errno)));
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *buf = (char *)mdk_alloc(n + 1);
  size_t got = fread(buf, 1, (size_t)n, f); fclose(f);
  return mdk_ok(mdk_str_lit(buf, (long long)got));
}

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

/* fileExists : String -> Bool — raw 0/1, emitter tags via tagInt. */
long long mdk_file_exists(long long path) {
  return access((const char *)path + 24, F_OK) == 0 ? 1 : 0;
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
