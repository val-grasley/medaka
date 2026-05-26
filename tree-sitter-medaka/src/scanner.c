#include "tree_sitter/parser.h"
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>

/* Token types — order must match the externals array in grammar.js */
typedef enum {
    NEWLINE,
    INDENT,
    DEDENT,
    INTERP_OPEN,  /* "prefix\{  — opening quote through first \{  */
    INTERP_MID,   /* }middle\{  — closing } through next \{        */
    INTERP_END,   /* }suffix"   — closing } through closing quote  */
} TokenType;

/*
 * Scanner state.
 *
 * The pending queue holds tokens that were decided on at the last newline
 * but haven't been emitted yet (multi-level dedent can produce several
 * tokens from a single newline boundary).
 *
 * Critical invariant: the queue is PEEKED before dequeuing — a token is
 * only consumed once it is confirmed to be valid in the current parser
 * state.  This prevents losing tokens when tree-sitter calls scan() in a
 * state where, e.g., NEWLINE is not yet valid.
 */
#define STACK_MAX   256
#define PENDING_MAX 512

typedef struct {
    uint32_t indent_stack[STACK_MAX];
    uint32_t stack_depth;
    uint8_t  pending[PENDING_MAX];
    uint32_t pending_head;
    uint32_t pending_count;
} Scanner;

/* ── queue helpers ───────────────────────────────────────────────────── */

static void enqueue(Scanner *s, TokenType t) {
    if (s->pending_count < PENDING_MAX) {
        uint32_t tail = (s->pending_head + s->pending_count) % PENDING_MAX;
        s->pending[tail] = (uint8_t)t;
        s->pending_count++;
    }
}

/* Peek without dequeuing */
static TokenType peek_queue(const Scanner *s) {
    return (TokenType)s->pending[s->pending_head];
}

static TokenType dequeue(Scanner *s) {
    TokenType t = (TokenType)s->pending[s->pending_head];
    s->pending_head = (s->pending_head + 1) % PENDING_MAX;
    s->pending_count--;
    return t;
}

/* ── life-cycle ──────────────────────────────────────────────────────── */

void *tree_sitter_medaka_external_scanner_create(void) {
    Scanner *s = (Scanner *)malloc(sizeof(Scanner));
    if (!s) return NULL;
    s->indent_stack[0] = 0;
    s->stack_depth = 1;
    s->pending_head = 0;
    s->pending_count = 0;
    return s;
}

void tree_sitter_medaka_external_scanner_destroy(void *payload) {
    free(payload);
}

unsigned tree_sitter_medaka_external_scanner_serialize(void *payload, char *buf) {
    Scanner *s = (Scanner *)payload;
    unsigned n = 0;
    /* 1 byte for depth */
    buf[n++] = (char)(s->stack_depth & 0xFF);
    for (uint32_t i = 0; i < s->stack_depth && n + 4 <= 1024; i++) {
        uint32_t v = s->indent_stack[i];
        buf[n++] = (char)((v >> 24) & 0xFF);
        buf[n++] = (char)((v >> 16) & 0xFF);
        buf[n++] = (char)((v >>  8) & 0xFF);
        buf[n++] = (char)( v        & 0xFF);
    }
    /* Serialise the pending queue (in logical order: head first).
     * We must persist it because tree-sitter serialises/deserialises the
     * scanner state between EVERY external-token call, so any queued tokens
     * that weren't yet valid would be silently lost. */
    buf[n++] = (char)(s->pending_count & 0xFF);
    for (uint32_t i = 0; i < s->pending_count && n < 1024; i++) {
        uint32_t idx = (s->pending_head + i) % PENDING_MAX;
        buf[n++] = s->pending[idx];
    }
    return n;
}

void tree_sitter_medaka_external_scanner_deserialize(void *payload,
                                                      const char *buf,
                                                      unsigned len) {
    Scanner *s = (Scanner *)payload;
    s->stack_depth = 1;
    s->indent_stack[0] = 0;
    s->pending_head = 0;
    s->pending_count = 0;
    if (len == 0) return;
    unsigned n = 0;
    s->stack_depth = (uint32_t)(unsigned char)buf[n++];
    if (s->stack_depth == 0 || s->stack_depth > STACK_MAX) {
        s->stack_depth = 1;
        return;
    }
    for (uint32_t i = 0; i < s->stack_depth && n + 4 <= len; i++) {
        uint32_t v = ((uint32_t)(unsigned char)buf[n]   << 24)
                   | ((uint32_t)(unsigned char)buf[n+1] << 16)
                   | ((uint32_t)(unsigned char)buf[n+2] <<  8)
                   | ((uint32_t)(unsigned char)buf[n+3]);
        s->indent_stack[i] = v;
        n += 4;
    }
    /* Restore the pending queue */
    if (n < len) {
        uint32_t count = (uint32_t)(unsigned char)buf[n++];
        if (count > PENDING_MAX) count = PENDING_MAX;
        s->pending_head = 0;
        s->pending_count = 0;
        for (uint32_t i = 0; i < count && n < len; i++) {
            s->pending[i] = (uint8_t)buf[n++];
            s->pending_count++;
        }
    }
}

/* ── helpers ─────────────────────────────────────────────────────────── */

static void skip(TSLexer *lexer) {
    lexer->advance(lexer, true);
}

/* ── scan ────────────────────────────────────────────────────────────── */

bool tree_sitter_medaka_external_scanner_scan(void *payload,
                                               TSLexer *lexer,
                                               const bool *valid_symbols) {
    Scanner *s = (Scanner *)payload;

    /* ── String interpolation tokens ───────────────────────────────── */

    /* INTERP_OPEN: scan "prefix\{  — starts at '"', ends after consuming '\{'.
     * Skip leading whitespace first (extras are handled by the internal lexer
     * but the external scanner sees raw positions). */
    if (valid_symbols[INTERP_OPEN]) {
        while (lexer->lookahead == ' ' || lexer->lookahead == '\t')
            lexer->advance(lexer, true); /* skip as whitespace */
        if (lexer->lookahead == '"') {
            lexer->advance(lexer, false); /* consume opening '"' */
            while (!lexer->eof(lexer)) {
                int32_t c = lexer->lookahead;
                if (c == '"') return false; /* plain string, no interpolation */
                if (c == '\\') {
                    lexer->advance(lexer, false);
                    if (lexer->lookahead == '{') {
                        lexer->advance(lexer, false); /* consume '{' */
                        lexer->result_symbol = INTERP_OPEN;
                        return true;
                    }
                    /* other escape — skip the escaped character */
                    if (!lexer->eof(lexer)) lexer->advance(lexer, false);
                    continue;
                }
                lexer->advance(lexer, false);
            }
            return false;
        }
    }

    /* INTERP_MID / INTERP_END: both start with '}' after an interpolated expr.
     * Scan forward to decide: '\{' → MID, '"' → END.
     * When both are valid (grammar is in an ambiguous state), we scan and
     * emit whichever delimiter we find first. */
    if ((valid_symbols[INTERP_MID] || valid_symbols[INTERP_END])
            && lexer->lookahead == '}') {
        lexer->advance(lexer, false); /* consume '}' */
        while (!lexer->eof(lexer)) {
            int32_t c = lexer->lookahead;
            if (c == '\\') {
                lexer->advance(lexer, false);
                if (lexer->lookahead == '{') {
                    lexer->advance(lexer, false);
                    if (valid_symbols[INTERP_MID]) {
                        lexer->result_symbol = INTERP_MID;
                        return true;
                    }
                    return false;
                }
                if (!lexer->eof(lexer)) lexer->advance(lexer, false);
                continue;
            }
            if (c == '"') {
                lexer->advance(lexer, false); /* consume closing '"' */
                if (valid_symbols[INTERP_END]) {
                    lexer->result_symbol = INTERP_END;
                    return true;
                }
                return false;
            }
            lexer->advance(lexer, false);
        }
        return false;
    }

    /* ── Indent / dedent / newline tokens ───────────────────────────── */

    bool any_indent = valid_symbols[NEWLINE] ||
                      valid_symbols[INDENT]  ||
                      valid_symbols[DEDENT];

    /* If none of our tokens are valid right now, bail immediately without
     * touching the lookahead. */
    if (!any_indent) return false;

    /* ── 1. Drain pending queue ──────────────────────────────────────── */
    if (s->pending_count > 0) {
        TokenType t = peek_queue(s);
        if (valid_symbols[t]) {
            dequeue(s);
            lexer->result_symbol = t;
            return true;
        }
        /* The queued token is not valid yet — let the parser make progress
         * (it will call us again later when it is valid). */
        return false;
    }

    /* ── 2. We need a real newline in the source to trigger indentation ── */
    if (lexer->lookahead != '\n' && lexer->lookahead != '\r') {
        /* EOF: close remaining indent levels */
        if (lexer->eof(lexer) && s->stack_depth > 1) {
            if (valid_symbols[DEDENT]) {
                s->stack_depth--;
                lexer->result_symbol = DEDENT;
                return true;
            }
        }
        return false;
    }

    /* ── 3. Consume the newline and measure the next non-blank line's indent.
     *
     * We consume all consecutive newline characters with advance() (not skip)
     * so the emitted token has non-zero width.  Tree-sitter ignores zero-width
     * external tokens when they don't match the current parse state, which
     * would leave the raw '\n' character for the regular lexer — but '\n' is
     * not in the grammar's extras and cannot be skipped there, leading to
     * spurious ERROR nodes.  Making the token wide ensures the '\n' bytes are
     * consumed as part of whichever structural token we emit.
     *
     * Blank lines that follow are also consumed here before mark_end so that
     * the token spans up to (but not including) the first real content.
     * Leading whitespace on the indented line is left for the regular lexer,
     * which skips it via the extras pattern /[ \t\n\r]+/.
     */

    /* Consume the triggering newline (and any immediately following blank
     * lines) as part of the token. */
    while (lexer->lookahead == '\n' || lexer->lookahead == '\r') {
        lexer->advance(lexer, false);
    }

    /* Mark the token end here — everything up to this point (all the consumed
     * newlines) becomes part of the emitted token's source extent. */
    lexer->mark_end(lexer);

    /* Now peek ahead (skip, not advance) to measure the indent of the first
     * non-blank, non-whitespace line.  These peek-skips do NOT extend the
     * token because mark_end has already been called. */
    uint32_t col = 0;
    bool found_content = false;
    while (!lexer->eof(lexer)) {
        if (lexer->lookahead == ' ') {
            col++;
            skip(lexer);
        } else if (lexer->lookahead == '\t') {
            col = (col / 8 + 1) * 8;
            skip(lexer);
        } else if (lexer->lookahead == '\n' || lexer->lookahead == '\r') {
            /* Another blank line — reset column counter and keep peeking. */
            col = 0;
            skip(lexer);
        } else {
            found_content = true;
            break;
        }
    }

    /* EOF (possibly after blank lines): close all indent levels */
    if (!found_content) {
        if (s->stack_depth > 1) {
            /* Queue: NEWLINE then (DEDENT NEWLINE)* for each level */
            enqueue(s, NEWLINE);
            while (s->stack_depth > 1) {
                s->stack_depth--;
                enqueue(s, DEDENT);
                enqueue(s, NEWLINE);
            }
            TokenType t = dequeue(s);
            if (valid_symbols[t]) {
                lexer->result_symbol = t;
                return true;
            }
        } else if (valid_symbols[NEWLINE]) {
            lexer->result_symbol = NEWLINE;
            return true;
        }
        return false;
    }

    uint32_t current = s->indent_stack[s->stack_depth - 1];

    if (col > current) {
        /* Indent */
        if (s->stack_depth < STACK_MAX) {
            s->indent_stack[s->stack_depth++] = col;
        }
        if (valid_symbols[INDENT]) {
            lexer->result_symbol = INDENT;
            return true;
        }
        return false;

    } else if (col < current) {
        /* Dedent (potentially multiple levels) */
        enqueue(s, NEWLINE);
        while (s->stack_depth > 1 && s->indent_stack[s->stack_depth - 1] > col) {
            s->stack_depth--;
            enqueue(s, DEDENT);
            enqueue(s, NEWLINE);
        }
        TokenType t = dequeue(s);
        if (valid_symbols[t]) {
            lexer->result_symbol = t;
            return true;
        }
        return false;

    } else {
        /* Same level */
        if (valid_symbols[NEWLINE]) {
            lexer->result_symbol = NEWLINE;
            return true;
        }
        return false;
    }
}
