# META
source_lines=2189
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted Medaka lexer — Stage 1 port of `lib/lexer.mll`.
--
-- STATUS: tokenizer ported — int/float/string/char literals (with escapes
-- `\n \t \r \0 \\ \"`, char-only `\'`, and the `\u{…}` unicode escape in *both*
-- string and char literals — mirroring lib/lexer.mll's read_string /
-- read_triple_string / read_interp_continue / read_char) + hex/bin/oct ints,
-- idents/keywords, operators/punctuation, line + `{- … -}` (nestable) block
-- comments, string interpolation (`\{expr}` → INTERP_OPEN/MID/END), triple-
-- quoted strings (`""" … """` with `stripIndent` dedent + their own
-- interpolation, marked by a negative interp depth), the `@`/`AS_AT` adjacency
-- rule, and a faithful port of lib/lexer.mll's INDENT/DEDENT/NEWLINE layout
-- algorithm + else-continuation filter + leading-operator continuation + Phase
-- 137 expression-RHS continuation lines (a would-be INDENT that just continues
-- an application is suppressed; resolved in the layout pass from the previous
-- significant token + a match/record-opener flag + the deeper line's first
-- token).  Validated byte-for-byte against the OCaml reference: 16/16 curated
-- fixtures + all 13 real .mdk files (stdlib + this lexer lexing itself).
--
-- Known serialization-only differences (token value matches; only debug text
-- differs): FLOAT (`floatToString` vs `%g`) and control bytes in STRING/CHAR
-- (`debugStringLit` vs `%S`).  The only unhandled surface is *nested* string
-- interpolation (a `"…"` string inside a `\{…}` expression) — but the OCaml
-- reference rejects that too ("Unterminated string literal"), so it isn't valid
-- Medaka; there is nothing to mirror.

import support.char.{
  isSp,
  isTab,
  isNL,
  isCR,
  isQuote,
  isApos,
  isBackslash,
  isBacktick,
  isSpace,
  isDigit,
  isLower,
  isUpper,
  isAlnum,
  isHexDigit,
}
import support.util.{joinWith, compareDecMag, listLen, anyList}

public export data Token =
  -- TInt carries the parsed value AND the original source lexeme (#458): the raw
  -- span text ("0xD800", "1_000", "0b1010") so the parser can hand the printer a
  -- radix-faithful `ENumLit`.  `tokenToString`/token-dump goldens render only the
  -- value, so the lexer diff goldens are unaffected.
  | TInt Int String
  | TFloat Float
  | TString String
  | TChar String
  | TBool Bool
  | TInterpOpen String
  | TInterpMid String
  | TInterpEnd String
  | TIdent String
  | TUpper String
  | TBacktickIdent String
  | TLet
  | TRec
  | TWith
  | TMut
  | TIn
  | TIf
  | TThen
  | TElse
  | TMatch
  | TData
  | TRecord
  | TInterface
  | TDefault
  | TImpl
  | TImport
  | TExport
  | TPublic
  | TWhere
  | TOf
  | TRequires
  | TDo
  | TAs
  | TExtern
  | TDeriving
  | TType
  | TNewtype
  | TProp
  | TTest
  | TBench
  | TEffect
  | TFunction
  | TPlus
  | TMinus
  | TMinusTight
  | TStar
  | TSlash
  | TSlashEq
  | TMod
  | TEqEq
  | TNeq
  | TLt
  | TGt
  | TLeq
  | TGeq
  | TAnd
  | TOr
  | TCons
  | TPlusPlus
  | TPipeRight
  | TRCompose
  | TLCompose
  | TFatArrow
  | TArrow
  | TLArrow
  | TAt
  | TBang
  | TAsAt
  | TEqual
  | TColon
  | TColonEq
  | TComma
  | TDot
  | TPipe
  | TUnderscore
  | TLParen
  | TRParen
  | TLBracket
  | TLBracketTight
  | TRBracket
  | TLBrace
  | TRBrace
  | TLArray
  | TRArray
  | TDotLBrace
  | TDotStar
  | TEllipsis
  | TDotDot
  | TDotDotEq
  | TNewline
  | TIndent
  | TDedent
  | TEof
  | TLexError String
deriving (Eq)

-- Mirrors `lib/lexer.mll` `token_to_string`.  String-bearing tokens use
-- `debugStringLit` (the `%S`-style quoted/escaped form); ints use `intToString`.
export tokenToString : Token -> String
tokenToString (TInt n _) = "INT " ++ intToString n
tokenToString (TFloat f) = "FLOAT " ++ floatToString f
tokenToString (TString s) = "STRING " ++ debugStringLit s
tokenToString (TChar s) = "CHAR " ++ debugStringLit s
tokenToString (TBool True) = "BOOL true"
tokenToString (TBool False) = "BOOL false"
tokenToString (TInterpOpen s) = "INTERP_OPEN " ++ debugStringLit s
tokenToString (TInterpMid s) = "INTERP_MID " ++ debugStringLit s
tokenToString (TInterpEnd s) = "INTERP_END " ++ debugStringLit s
tokenToString (TIdent s) = "IDENT " ++ debugStringLit s
tokenToString (TUpper s) = "UPPER " ++ debugStringLit s
tokenToString (TBacktickIdent s) = "BACKTICK_IDENT " ++ debugStringLit s
tokenToString TLet = "LET"
tokenToString TRec = "REC"
tokenToString TWith = "WITH"
tokenToString TMut = "MUT"
tokenToString TIn = "IN"
tokenToString TIf = "IF"
tokenToString TThen = "THEN"
tokenToString TElse = "ELSE"
tokenToString TMatch = "MATCH"
tokenToString TData = "DATA"
tokenToString TRecord = "RECORD"
tokenToString TInterface = "INTERFACE"
tokenToString TDefault = "DEFAULT"
tokenToString TImpl = "IMPL"
tokenToString TImport = "IMPORT"
tokenToString TExport = "EXPORT"
tokenToString TPublic = "PUBLIC"
tokenToString TWhere = "WHERE"
tokenToString TOf = "OF"
tokenToString TRequires = "REQUIRES"
tokenToString TDo = "DO"
tokenToString TAs = "AS"
tokenToString TExtern = "EXTERN"
tokenToString TDeriving = "DERIVING"
tokenToString TType = "TYPE"
tokenToString TNewtype = "NEWTYPE"
tokenToString TProp = "PROP"
tokenToString TTest = "TEST"
tokenToString TBench = "BENCH"
tokenToString TEffect = "EFFECT"
tokenToString TFunction = "FUNCTION"
tokenToString TPlus = "PLUS"
tokenToString TMinus = "MINUS"
tokenToString TMinusTight = "MINUS_TIGHT"
tokenToString TStar = "STAR"
tokenToString TSlash = "SLASH"
tokenToString TSlashEq = "SLASHEQ"
tokenToString TMod = "MOD"
tokenToString TEqEq = "EQ_EQ"
tokenToString TNeq = "NEQ"
tokenToString TLt = "LT"
tokenToString TGt = "GT"
tokenToString TLeq = "LEQ"
tokenToString TGeq = "GEQ"
tokenToString TAnd = "AND"
tokenToString TOr = "OR"
tokenToString TCons = "CONS"
tokenToString TPlusPlus = "PLUSPLUS"
tokenToString TPipeRight = "PIPE_RIGHT"
tokenToString TRCompose = "RCOMPOSE"
tokenToString TLCompose = "LCOMPOSE"
tokenToString TFatArrow = "FAT_ARROW"
tokenToString TArrow = "ARROW"
tokenToString TLArrow = "LARROW"
tokenToString TAt = "AT"
tokenToString TBang = "BANG"
tokenToString TAsAt = "AS_AT"
tokenToString TEqual = "EQUAL"
tokenToString TColon = "COLON"
tokenToString TColonEq = "COLONEQ"
tokenToString TComma = "COMMA"
tokenToString TDot = "DOT"
tokenToString TPipe = "PIPE"
tokenToString TUnderscore = "UNDERSCORE"
tokenToString TLParen = "LPAREN"
tokenToString TRParen = "RPAREN"
tokenToString TLBracket = "LBRACKET"
tokenToString TLBracketTight = "LBRACKET_TIGHT"
tokenToString TRBracket = "RBRACKET"
tokenToString TLBrace = "LBRACE"
tokenToString TRBrace = "RBRACE"
tokenToString TLArray = "LARRAY"
tokenToString TRArray = "RARRAY"
tokenToString TDotLBrace = "DOT_LBRACE"
tokenToString TDotStar = "DOT_STAR"
tokenToString TEllipsis = "ELLIPSIS"
tokenToString TDotDot = "DOTDOT"
tokenToString TDotDotEq = "DOTDOT_EQ"
tokenToString TNewline = "NEWLINE"
tokenToString TIndent = "INDENT"
tokenToString TDedent = "DEDENT"
tokenToString TEof = "EOF"
tokenToString (TLexError s) = "LEX_ERROR " ++ debugStringLit s

-- User-facing rendering of a token for error messages (e.g. "unexpected
-- `println`"), as opposed to `tokenToString`'s debug format ("IDENT
-- println"). Identifier-like/punctuation tokens render their surface
-- spelling in backticks; literal categories render as a phrase (`a number`);
-- layout/synthetic tokens render as a plain phrase (`end of input`) since
-- they have no surface spelling a user typed.
export describeToken : Token -> String
describeToken (TInt _ _) = "a number"
describeToken (TFloat _) = "a number"
describeToken (TString _) = "a string"
describeToken (TChar _) = "a character literal"
describeToken (TBool True) = "`true`"
describeToken (TBool False) = "`false`"
describeToken (TInterpOpen _) = "a string"
describeToken (TInterpMid _) = "a string"
describeToken (TInterpEnd _) = "a string"
describeToken (TIdent s) = "`" ++ s ++ "`"
describeToken (TUpper s) = "`" ++ s ++ "`"
describeToken (TBacktickIdent s) = "`" ++ s ++ "`"
describeToken TLet = "`let`"
describeToken TRec = "`rec`"
describeToken TWith = "`with`"
describeToken TMut = "`mut`"
describeToken TIn = "`in`"
describeToken TIf = "`if`"
describeToken TThen = "`then`"
describeToken TElse = "`else`"
describeToken TMatch = "`match`"
describeToken TData = "`data`"
describeToken TRecord = "`record`"
describeToken TInterface = "`interface`"
describeToken TDefault = "`default`"
describeToken TImpl = "`impl`"
describeToken TImport = "`import`"
describeToken TExport = "`export`"
describeToken TPublic = "`public`"
describeToken TWhere = "`where`"
describeToken TOf = "`of`"
describeToken TRequires = "`requires`"
describeToken TDo = "`do`"
describeToken TAs = "`as`"
describeToken TExtern = "`extern`"
describeToken TDeriving = "`deriving`"
describeToken TType = "`type`"
describeToken TNewtype = "`newtype`"
describeToken TProp = "`prop`"
describeToken TTest = "`test`"
describeToken TBench = "`bench`"
describeToken TEffect = "`effect`"
describeToken TFunction = "`function`"
describeToken TPlus = "`+`"
describeToken TMinus = "`-`"
describeToken TMinusTight = "`-`"
describeToken TStar = "`*`"
describeToken TSlash = "`/`"
describeToken TSlashEq = "`/=`"
describeToken TMod = "`%`"
describeToken TEqEq = "`==`"
describeToken TNeq = "`!=`"
describeToken TLt = "`<`"
describeToken TGt = "`>`"
describeToken TLeq = "`<=`"
describeToken TGeq = "`>=`"
describeToken TAnd = "`&&`"
describeToken TOr = "`||`"
describeToken TCons = "`::`"
describeToken TPlusPlus = "`++`"
describeToken TPipeRight = "`|>`"
describeToken TRCompose = "`>>`"
describeToken TLCompose = "`<<`"
describeToken TFatArrow = "`=>`"
describeToken TArrow = "`->`"
describeToken TLArrow = "`<-`"
describeToken TAt = "`@`"
describeToken TBang = "`!`"
describeToken TAsAt = "`@`"
describeToken TEqual = "`=`"
describeToken TColon = "`:`"
describeToken TColonEq = "`:=`"
describeToken TComma = "`,`"
describeToken TDot = "`.`"
describeToken TPipe = "`|`"
describeToken TUnderscore = "`_`"
describeToken TLParen = "`(`"
describeToken TRParen = "`)`"
describeToken TLBracket = "`[`"
describeToken TLBracketTight = "`[`"
describeToken TRBracket = "`]`"
describeToken TLBrace = "`{`"
describeToken TRBrace = "`}`"
describeToken TLArray = "`[|`"
describeToken TRArray = "`|]`"
describeToken TDotLBrace = "`.{`"
describeToken TDotStar = "`.*`"
describeToken TEllipsis = "`...`"
describeToken TDotDot = "`..`"
describeToken TDotDotEq = "`..=`"
describeToken TNewline = "a line break"
describeToken TIndent = "an indent"
describeToken TDedent = "a dedent"
describeToken TEof = "end of input"
describeToken (TLexError s) = s

-- ── Raw scanner output ──────────────────────────────────────────────────
-- The scanner produces real tokens interleaved with `RNewline col` markers
-- (one per significant source line break, carrying the indentation of the
-- following line). A second `layout` pass turns those markers into
-- INDENT/DEDENT/NEWLINE per the OCaml `handle_indent` algorithm.
-- `RComment startPos text` carries a captured comment out-of-band: `startPos`
-- is the source char offset of the opening `--`/`{-`, `text` the full lexeme
-- (including the `--` / `{- … -}` delimiters, matching lib/lexer.mll's
-- `c_text`).  These markers are produced by the comment arms of `scanAt` and
-- *stripped before the layout pass* (`stripComments`), so the Token stream the
-- parser consumes is byte-identical to before — comments are purely a side
-- channel.  `collectComments` re-reads the raw stream to surface them.
-- `RTok tok startOff endOff` carries the source char offsets of the token's
-- lexeme: `startOff` is the first char (0-based), `endOff` is one past the last
-- char (= the next scan position), so `end - start = token length in chars`.
-- `tokenize` discards both offsets (token stream byte-identical). `tokenizeWithLines`
-- uses only `startOff` (to derive a 1-based line).
-- `RNewline col off` carries the offset of the newline char that ended
-- the preceding line, so synthetic NEWLINE/INDENT/DEDENT tokens inserted by the
-- layout pass get a source line too.
data RawTok = RTok Token Int Int | RNewline Int Int | RComment Int String

-- ── Character classification: ASCII Char -> Bool predicates now live in
-- support/char.mdk (imported at the top of this module).

-- ── Low-level source access ─────────────────────────────────────────────
at : Array Char -> Int -> Char
at src i = arrayGetUnsafe i src

is2 : Array Char -> Int -> Int -> Char -> Char -> Bool
is2 src len pos a b = pos + 1 < len && at src pos == a && at src (pos + 1) == b

is3 : Array Char -> Int -> Int -> Char -> Char -> Char -> Bool
is3 src len pos a b c = pos + 2 < len
  && at src pos == a
  && at src (pos + 1) == b
  && at src (pos + 2) == c

substr : Array Char -> Int -> Int -> String
substr src start endp =
  stringFromChars (arrayMakeWith (endp - start) (i => at src (start + i)))

collectNoUs : Array Char -> Int -> Int -> List Char
collectNoUs src p endp
  | p >= endp = []
  | at src p == '_' = collectNoUs src (p + 1) endp
  | otherwise = at src p :: collectNoUs src (p + 1) endp

substrNoUs : Array Char -> Int -> Int -> String
substrNoUs src start endp =
  stringFromChars (arrayFromList (collectNoUs src start endp))

parseIntFrom : Array Char -> Int -> Int -> Int -> Int
parseIntFrom src p endp acc
  | p >= endp = acc
  | at src p == '_' = parseIntFrom src (p + 1) endp acc
  | otherwise =
    parseIntFrom src (p + 1) endp (acc * 10 + (charCode (at src p) - 48))

-- ── Int-literal range guard ─────────────────────────────────────────────
-- The tagged-Int rep is 63-bit (`word = (n << 1) | 1`, `runtime/medaka_rt.c`),
-- so `Int` spans [-2^62, 2^62-1]. The lexer sees only the unsigned digits (the
-- `-` is a separate token, negated in the parser), and the negative minimum
-- -2^62 must stay writable, so the largest admissible magnitude is
-- 2^62 = 4611686018427387904 (19 digits). A bare positive 2^62 still wraps
-- (the lexer can't see the sign); 2^62+1 and above are rejected outright.
-- `parseIntFrom` accumulates in the compiler's own 63-bit `Int` and would wrap,
-- so overflow is detected on the digit STRING via `compareDecMag` (magnitude
-- compare with no arithmetic), never by parsing.  `substrNoUs` strips the '_'
-- separators; `compareDecMag` ignores leading zeros, so the largest admissible
-- magnitude is exactly 2^62 (anything greater overflows).
intLitOverflows : Array Char -> Int -> Int -> Bool
intLitOverflows src start endp =
  compareDecMag (substrNoUs src start endp) "4611686018427387904" == Gt

-- ── Keyword table ───────────────────────────────────────────────────────
-- True/False are NOT here: they start uppercase, so the OCaml lexer emits them
-- as UPPER (keyword_or_ident only fires for lowercase/underscore lexemes).
keywordOrIdent : String -> Token
keywordOrIdent "let" = TLet
keywordOrIdent "rec" = TRec
keywordOrIdent "with" = TWith
keywordOrIdent "mut" = TMut
keywordOrIdent "in" = TIn
keywordOrIdent "if" = TIf
keywordOrIdent "then" = TThen
keywordOrIdent "else" = TElse
keywordOrIdent "match" = TMatch
keywordOrIdent "data" = TData
keywordOrIdent "record" = TRecord
keywordOrIdent "interface" = TInterface
keywordOrIdent "default" = TDefault
keywordOrIdent "impl" = TImpl
keywordOrIdent "import" = TImport
keywordOrIdent "export" = TExport
keywordOrIdent "public" = TPublic
keywordOrIdent "where" = TWhere
keywordOrIdent "of" = TOf
keywordOrIdent "do" = TDo
keywordOrIdent "as" = TAs
keywordOrIdent "extern" = TExtern
keywordOrIdent "requires" = TRequires
keywordOrIdent "deriving" = TDeriving
keywordOrIdent "type" = TType
keywordOrIdent "newtype" = TNewtype
keywordOrIdent "prop" = TProp
keywordOrIdent "test" = TTest
keywordOrIdent "bench" = TBench
keywordOrIdent "effect" = TEffect
keywordOrIdent "function" = TFunction
keywordOrIdent s = TIdent s

-- ── Scanner ─────────────────────────────────────────────────────────────
-- scan src len pos parenDepth interpDepth.  `id` (interp depth) is 0 outside
-- string interpolation; inside a `\{ … }` it is the brace nesting (1 = the
-- interpolation's own braces), so a `}` that brings it back to 0 resumes string
-- scanning rather than closing a paren group.  Mirrors lib/lexer.mll's
-- `interp_depth`.
scan : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scan src len pos depth id
  | pos >= len = []
  | otherwise = scanAt src len pos depth id (at src pos)

scanAt : Array Char -> Int -> Int -> Int -> Int -> Char -> List RawTok
scanAt src len pos depth id c
  | isSpace c = scan src len (pos + 1) depth id
  | isNL c || isCR c = handleNewline src len pos depth id
  | c == '-' && pos + 1 < len && at src (pos + 1) == '-' =
    let e = skipLineComment src len pos
    RComment pos (substr src pos e) :: scan src len e depth id
  | c == '{' && pos + 1 < len && at src (pos + 1) == '-' =
    let e = skipBlockComment src len (pos + 2) 1
    if e < 0 then
      lexErrorTok pos "unterminated block comment"
    else
      RComment pos (substr src pos e) :: scan src len e depth id
  | isDigit c = scanNumber src len pos depth id
  | isQuote c && isTripleAt src len pos =
    scanTriple src len (pos + 3) pos depth id False ""
  | isQuote c = scanStr src len (pos + 1) pos depth id ""
  | isApos c = scanChar src len pos depth id
  | isLower c || c == '_' = scanLower src len pos depth id
  | isUpper c = scanUpper src len pos depth id
  | isBacktick c = scanBacktick src len pos depth id
  | otherwise = scanOp src len pos depth id c

skipLineComment : Array Char -> Int -> Int -> Int
skipLineComment src len p
  | p >= len = p
  | isNL (at src p) = p
  | otherwise = skipLineComment src len (p + 1)

-- Emit a terminal lexer-error token instead of panicking.  The error carries the
-- offending char offset `p` (as the RTok's start offset) so `parser.parseResult`
-- can resolve it to a 1-based line / 0-based column via `offsetToLineCol` — the
-- SAME located path a structured parse error flows through (rendered `file:L:C:`
-- by the driver).  Terminates the raw stream: valid code never reaches here, so
-- the token stream for well-formed input is byte-identical.
lexErrorTok : Int -> String -> List RawTok
lexErrorTok p msg = [RTok (TLexError msg) p p]

-- nestable `{- … -}` block comments; `p` is just past the opening `{-`, `d` the
-- open-comment nesting depth. Returns the position just past the matching `-}`.
skipBlockComment : Array Char -> Int -> Int -> Int -> Int
-- Returns the position just past the matching `-}`, or the sentinel `-1` when
-- the comment is never closed (so the caller can emit a located lexer error
-- rather than silently swallowing the rest of the file).
skipBlockComment src len p d
  | d <= 0 = p
  | p >= len = 0 - 1
  | at src p == '{' && p + 1 < len && at src (p + 1) == '-' =
    skipBlockComment src len (p + 2) (d + 1)
  | at src p == '-' && p + 1 < len && at src (p + 1) == '}' =
    skipBlockComment src len (p + 2) (d - 1)
  | otherwise = skipBlockComment src len (p + 1) d

-- identifiers / keywords / underscore
identEnd : Array Char -> Int -> Int -> Int
identEnd src len p
  | p < len && isAlnum (at src p) = identEnd src len (p + 1)
  | otherwise = p

scanLower : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scanLower src len pos depth id =
  let e = identEnd src len (pos + 1)
  RTok (identToken src pos e) pos e :: scan src len e depth id

identToken : Array Char -> Int -> Int -> Token
identToken src pos e
  | at src pos == '_' && e - pos == 1 = TUnderscore
  | otherwise = keywordOrIdent (substr src pos e)

scanUpper : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scanUpper src len pos depth id =
  let e = identEnd src len (pos + 1)
  RTok (TUpper (substr src pos e)) pos e :: scan src len e depth id

scanBacktick : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scanBacktick src len pos depth id =
  let e = btClose src len (pos + 1)
  RTok (TBacktickIdent (substr src (pos + 1) e)) pos (e + 1) :: scan src len (e + 1) depth id

btClose : Array Char -> Int -> Int -> Int
btClose src len p
  | p >= len = p
  | isBacktick (at src p) = p
  | otherwise = btClose src len (p + 1)

-- numbers (int / float; underscores allowed)
digitsEnd : Array Char -> Int -> Int -> Int
digitsEnd src len p
  | p < len && (isDigit (at src p) || at src p == '_') =
    digitsEnd src len (p + 1)
  | otherwise = p

-- `0x…` / `0b…` / `0o…` radix literals (require ≥1 valid digit after the prefix).
isRadixPrefix : Array Char -> Int -> Int -> Bool
isRadixPrefix src len pos = at src pos == '0'
  && pos + 2 < len
  && radixKind (at src (pos + 1))
  && isRadixDigit (at src (pos + 1)) (at src (pos + 2))

radixKind : Char -> Bool
radixKind k = k == 'x' || k == 'b' || k == 'o'

radixBase : Char -> Int
radixBase 'x' = 16
radixBase 'b' = 2
radixBase _ = 8

isRadixDigit : Char -> Char -> Bool
isRadixDigit 'x' c = isHexDigit c
isRadixDigit 'b' c = c == '0' || c == '1'
isRadixDigit _ c = c >= '0' && c <= '7'

digitVal : Char -> Int
digitVal c
  | isDigit c = charCode c - 48
  | c >= 'a' && c <= 'f' = charCode c - 87
  | otherwise = charCode c - 55

radixEnd : Array Char -> Int -> Int -> Char -> Int
radixEnd src len p k
  | p < len && (isRadixDigit k (at src p) || at src p == '_') =
    radixEnd src len (p + 1) k
  | otherwise = p

parseRadix : Array Char -> Int -> Int -> Int -> Int -> Int
parseRadix src p endp base acc
  | p >= endp = acc
  | at src p == '_' = parseRadix src (p + 1) endp base acc
  | otherwise =
    parseRadix src (p + 1) endp base (acc * base + digitVal (at src p))

-- ── Radix-literal range guard (#556) ────────────────────────────────────
-- `parseRadix` accumulates in the compiler's own 63-bit `Int` and wraps
-- SILENTLY, so — exactly as on the decimal path (`intLitOverflows`) — the range
-- is decided on the DIGIT STRING, with no arithmetic, never by parsing.
--
-- The bound is deliberately the SAME one the decimal path uses: magnitude
-- ≤ 2^62.  The lexer sees only unsigned digits (the `-` is a separate token,
-- negated in the parser), so it must admit magnitude 2^62 to keep the negative
-- minimum -2^62 writable — `-0x4000000000000000` stays legal exactly as
-- `-4611686018427387904` does.  A BARE positive 2^62 wraps to `intMinBound`
-- here and is then rejected in positive position by the parser's `isIntMinLit`
-- (#171), which keys on the value and so covers every spelling of 2^62 —
-- decimal and radix alike — from one rule.  Anything above 2^62 never reaches
-- the parser: it is rejected right here, in whatever base it was written.
--
-- 2^62 in each radix is one leading digit followed by zeros, so the bound is
-- described exactly by (significant-digit count, leading digit):
--   hex  2^62 = 4 * 16^15  ->  "4" ++ 15 zeros  ->  (16, 4)
--   oct  2^62 = 4 * 8^20   ->  "4" ++ 20 zeros  ->  (21, 4)
--   bin  2^62 = 1 * 2^62   ->  "1" ++ 62 zeros  ->  (63, 1)
-- Compared digit-VALUE-wise rather than by `stringCompare` (which
-- `compareDecMag` can use because decimal digits sort by ASCII): hex digits do
-- NOT, since 'A'(65) < 'a'(97) both exceed '9'(57), so a mixed-case literal
-- would compare wrong.
radixMaxLen : Char -> Int
radixMaxLen 'x' = 16
radixMaxLen 'b' = 63
radixMaxLen _ = 21

radixMaxLead : Char -> Int
radixMaxLead 'b' = 1
radixMaxLead _ = 4

-- Significant digits of [p, endp): '_' separators and leading zeros dropped.
-- Once a nonzero digit is seen the rest is taken verbatim (minus separators),
-- so interior zeros are preserved and only the LEADING run is stripped.
sigRadixDigits : Array Char -> Int -> Int -> List Char
sigRadixDigits src p endp
  | p >= endp = []
  | at src p == '_' || at src p == '0' = sigRadixDigits src (p + 1) endp
  | otherwise = collectNoUs src p endp

radixMagOverflows : List Char -> Int -> Int -> Bool
radixMagOverflows [] _ _ = False
radixMagOverflows (d::rest) maxLen maxLead =
  let n = 1 + listLen rest
  n > maxLen
    || n == maxLen && (digitVal d > maxLead || digitVal d == maxLead && anyList (!= '0') rest)

radixLitOverflows : Array Char -> Int -> Int -> Char -> Bool
radixLitOverflows src start endp k =
  radixMagOverflows
    (sigRadixDigits src start endp)
    (radixMaxLen k)
    (radixMaxLead k)

scanRadix : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scanRadix src len pos depth id =
  let k = at src (pos + 1)
  let e = radixEnd src len (pos + 2) k
  radixTok src len pos e k depth id

-- Mirrors `numFinish`'s shape, and shares its message verbatim: `parseErrCode`
-- keys L-INT-OVERFLOW on the "integer literal too large" prefix, and one
-- user-facing defect should not need two diagnostic codes.
radixTok : Array Char -> Int -> Int -> Int -> Char -> Int -> Int -> List RawTok
radixTok src len pos e k depth id
  | radixLitOverflows src (pos + 2) e k =
    lexErrorTok pos "integer literal too large for Int (max magnitude 2^62)"
  | otherwise = RTok (TInt (parseRadix src (pos + 2) e (radixBase k) 0) (substr src pos e)) pos e :: scan src len e depth id

scanNumber : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scanNumber src len pos depth id
  | isRadixPrefix src len pos = scanRadix src len pos depth id
  | isMalformedRadixPrefix src len pos = malformedRadixTok src len pos
  | otherwise = numFinish src len pos (digitsEnd src len pos) depth id

-- `0x`/`0b`/`0o` immediately followed by the digit separator `_` (#677):
-- `isRadixPrefix` already requires a VALID digit right after the prefix, so
-- this is exactly its complementary malformed shape — the prefix is right,
-- but `_` (only legal BETWEEN digits, e.g. `0xD_EAD`) sits where the first
-- digit must be. Caught here, at the source, instead of falling through to
-- `numFinish` (which stops at the lone `0`, leaving `x_FF` to be re-lexed as
-- an ordinary identifier and misreported downstream as "Unbound variable:
-- x_FF").
isMalformedRadixPrefix : Array Char -> Int -> Int -> Bool
isMalformedRadixPrefix src len pos = at src pos == '0'
  && pos + 2 < len
  && radixKind (at src (pos + 1))
  && at src (pos + 2) == '_'

malformedRadixTok : Array Char -> Int -> Int -> List RawTok
malformedRadixTok src len pos =
  let k = at src (pos + 1)
  let e = radixEnd src len (pos + 2) k
  let bad = substr src pos e
  let digits = stripLeadingUs src (pos + 2) e
  malformedRadixErr pos bad (substr src pos (pos + 2)) digits

-- Skip a leading run of `_` (there may be more than one, `0x__FF`) to find
-- where the real digits start; `""` when the literal has no digits at all
-- (`0x_`, `0x___`) — that shape gets a fix-less diagnostic, since there is no
-- safe spelling to suggest.
stripLeadingUs : Array Char -> Int -> Int -> String
stripLeadingUs src p e
  | p < e && at src p == '_' = stripLeadingUs src (p + 1) e
  | otherwise = substr src p e

malformedRadixErr : Int -> String -> String -> String -> List RawTok
malformedRadixErr pos bad prefix digits
  | stringLength digits == 0 = lexErrorTok pos "malformed radix literal `\{bad}`: '_' cannot immediately follow the radix prefix '\{prefix}', and no digit follows it either"
  | otherwise = lexErrorTok pos "malformed radix literal `\{bad}`: '_' cannot immediately follow the radix prefix — write `\{prefix}\{digits}`"

isFloatAt : Array Char -> Int -> Int -> Bool
isFloatAt src len e1 = e1 < len
  && at src e1 == '.'
  && e1 + 1 < len
  && isDigit (at src (e1 + 1))

isExpMarker : Char -> Bool
isExpMarker c = c == 'e' || c == 'E'

-- Optional decimal exponent `[eE][+-]?[0-9]+` (underscores allowed in the digits,
-- stripped later by `substrNoUs`). Returns the position AFTER the exponent, or `p`
-- unchanged when there is no valid exponent — a bare `e`/`E` NOT followed by an
-- (optionally signed) digit is left for identifier lexing, so `1e`, `x1e`, and the
-- identifier `e12` are untouched; only `<digits>[.<digits>]e[+-]?<digits>` floats.
expEnd : Array Char -> Int -> Int -> Int
expEnd src len p
  | p < len && isExpMarker (at src p) =
    let q = if p + 1 < len && (at src (p + 1) == '+' || at src (p + 1) == '-') then
      p + 2
    else
      p + 1
    if q < len && isDigit (at src q) then digitsEnd src len q else p
  | otherwise = p

numFinish : Array Char -> Int -> Int -> Int -> Int -> Int -> List RawTok
numFinish src len pos e1 depth id
  | isFloatAt src len e1 = floatTok src len pos e1 depth id
  | expEnd src len e1 > e1 =
    floatTokEnd src len pos (expEnd src len e1) depth id
  | isMalformedExpDot src len e1 = malformedExpDotTok src len pos e1
  | isMalformedTrailingDot src len e1 = malformedTrailingDotTok src pos e1
  | intLitOverflows src pos e1 =
    lexErrorTok pos "integer literal too large for Int (max magnitude 2^62)"
  | otherwise = RTok (TInt (parseIntFrom src pos e1 0) (substr src pos e1)) pos e1 :: scan src len e1 depth id

-- `<digits>.e<exp>`-shaped (#677, e.g. `5.e3`): a bare `.` right after a
-- just-scanned digit run, immediately followed by something that reads as a
-- decimal exponent (`isFloatAt` already ruled out a fractional digit here).
-- An `Int`/`Float` literal can never have a REAL field named `e3`, so —
-- unlike a generic trailing dot — there is no legitimate reading to protect;
-- this is always the fractional digit missing before the exponent.
isMalformedExpDot : Array Char -> Int -> Int -> Bool
isMalformedExpDot src len e1 = e1 < len
  && at src e1 == '.'
  && expEnd src len (e1 + 1) > e1 + 1

malformedExpDotTok : Array Char -> Int -> Int -> Int -> List RawTok
malformedExpDotTok src len pos e1 =
  let expE = expEnd src len (e1 + 1)
  let bad = substr src pos expE
  let good = "\{substr src pos (e1 + 1)}0\{substr src (e1 + 1) expE}"
  lexErrorTok
    pos
    "malformed float literal `\{bad}`: a float needs a digit after the decimal point — write `\{good}`"

-- `<digits>.`-shaped (#677, e.g. `5.`): a bare `.` right after a just-scanned
-- digit run with nothing after it that could continue a (possibly ill-typed
-- but syntactically legal) postfix — a lowercase/underscore field name, `[`
-- for `.[i]` indexing, or another dot-led token (`..`, `..=`, `...`, `.{`,
-- `.*`, all matched upstream in `scanOp` before a bare `.` ever reaches here).
-- Emitted only from a FRESH number scan (never for a dot following an
-- already-completed literal several tokens back), so there is no risk of
-- misreading a legitimate chained `(1.5).toString` — that dot is preceded by
-- `)`, not a digit run this call is currently scanning.
isMalformedTrailingDot : Array Char -> Int -> Int -> Bool
isMalformedTrailingDot src len e1 = e1 < len
  && at src e1 == '.'
  && not (dotContinuesAccess src len e1)

dotContinuesAccess : Array Char -> Int -> Int -> Bool
dotContinuesAccess src len p = p + 1 < len
  && (isLower (at src (p + 1)) || isUpper (at src (p + 1)) || at src (p + 1) == '_' || at src (p + 1) == '[' || at src (p + 1) == '.' || at src (p + 1) == '{' || at src (p + 1) == '*')

malformedTrailingDotTok : Array Char -> Int -> Int -> List RawTok
malformedTrailingDotTok src pos e1 =
  let bad = substr src pos (e1 + 1)
  lexErrorTok
    pos
    "malformed float literal `\{bad}`: a float needs a digit after the decimal point — write `\{bad}0`"

floatTok : Array Char -> Int -> Int -> Int -> Int -> Int -> List RawTok
floatTok src len pos e1 depth id =
  let e2 = digitsEnd src len (e1 + 1)
  floatTokEnd src len pos (expEnd src len e2) depth id

-- A Float is finite iff `f * 0.0 == 0.0`: for ±inf, `inf * 0.0` is NaN and
-- `NaN == 0.0` is False; for NaN, `NaN == 0.0` is likewise False. There is no
-- `isFinite` extern, so this arithmetic identity is the detection.
floatIsFinite : Float -> Bool
floatIsFinite f = f * 0.0 == 0.0

-- Emit a `TFloat` spanning [pos, endp). `substrNoUs` strips underscores across the
-- whole mantissa+exponent, and `stringToFloat` (strtod) reads the exponent form.
-- A literal whose magnitude overflows the IEEE-754 double range parses to `inf`,
-- which the native backend would emit as an invalid `store double inf`; reject it
-- at the source with a located error rather than let it reach codegen.
floatTokEnd : Array Char -> Int -> Int -> Int -> Int -> Int -> List RawTok
floatTokEnd src len pos endp depth id =
  let f = fromOption 0.0 (stringToFloat (substrNoUs src pos endp))
  if floatIsFinite f then
    RTok (TFloat f) pos endp :: scan src len endp depth id
  else
    lexErrorTok pos "float literal out of range (overflows to infinity)"

-- strings (escapes processed into the content; `\{` opens an interpolation).
-- `startQ` is the offset of the OPENING quote (captured at the call site in
-- `scanAt`), threaded through so the emitted `TString` token's start offset is
-- the full literal span, not just the closing quote (Defect B,
-- TYPE-ERROR-SPAN-DESIGN.md Bite 1) — it changes only the token's start
-- offset field, never the token stream itself.
scanStr : Array Char -> Int -> Int -> Int -> Int -> Int -> String -> List RawTok
scanStr src len p startQ depth id acc
  | p >= len = lexErrorTok p "unterminated string literal"
  | isQuote (at src p) =
    RTok (TString acc) startQ (p + 1) :: scan src len (p + 1) depth id
  | isBackslash (at src p) && p + 1 < len =
    scanStrEsc src len p startQ depth id acc (at src (p + 1))
  | isBackslash (at src p) = lexErrorTok p "unterminated string literal"
  | otherwise =
    scanStr src len (p + 1) startQ depth id (acc ++ charToStr (at src p))

-- The escape letters shared by string AND character literals: the decoded
-- content of `\<e>`, or `None` if `<e>` is not one of them. This ONE table is
-- what keeps the string lexer and the char lexer (`charEscDecode`, below) in
-- agreement — the char path used to accept any backslash-letter as the bare
-- letter (`'\v'` → `v`) precisely because it did NOT consult a shared table
-- (#668). `\{` (interpolation open) and `\u{…}` are handled by their callers
-- before this point, and `\'` is char-only, so none of those appear here.
commonEscDecode : Char -> Option String
commonEscDecode e
  | e == 'n' = Some "\n"
  | e == 't' = Some "\t"
  | e == 'r' = Some "\r"
  | e == '0' = Some (charToStr (fromOption ' ' (charFromCode 0)))
  | isBackslash e = Some "\\"
  | isQuote e = Some "\""
  | otherwise = None

scanStrEsc : Array Char -> Int -> Int -> Int -> Int -> Int -> String -> Char -> List RawTok
scanStrEsc src len p startQ depth id acc e
  | e == '{' = RTok (TInterpOpen acc) p (p + 2) :: scan src len (p + 2) depth 1
  | isUnicodeEsc src len p e = match uniEscChar src len p
    None => lexErrorTok p (uniEscErr src len p)
    Some c => scanStr src len (uniEscEnd src len p) startQ depth id (acc ++ charToStr c)
  | otherwise = match commonEscDecode e
    Some s => scanStr src len (p + 2) startQ depth id (acc ++ s)
    None => lexErrorTok p "invalid escape sequence '\\\{charToStr e}'"

-- string part after an interpolation's `}` closes (`\{`→INTERP_MID, `"`→INTERP_END)
scanInterpCont : Array Char -> Int -> Int -> Int -> String -> List RawTok
scanInterpCont src len p depth acc
  | p >= len = RTok (TInterpEnd acc) p p :: scan src len p depth 0
  | isQuote (at src p) =
    RTok (TInterpEnd acc) p (p + 1) :: scan src len (p + 1) depth 0
  | isBackslash (at src p) && p + 1 < len && at src (p + 1) == '{' =
    RTok (TInterpMid acc) p (p + 2) :: scan src len (p + 2) depth 1
  | isBackslash (at src p) && p + 1 < len =
    scanInterpEsc src len p depth acc (at src (p + 1))
  | otherwise =
    scanInterpCont src len (p + 1) depth (acc ++ charToStr (at src p))

scanInterpEsc : Array Char -> Int -> Int -> Int -> String -> Char -> List RawTok
scanInterpEsc src len p depth acc e
  | e == 'n' = scanInterpCont src len (p + 2) depth (acc ++ "\n")
  | e == 't' = scanInterpCont src len (p + 2) depth (acc ++ "\t")
  | isQuote e = scanInterpCont src len (p + 2) depth (acc ++ "\"")
  | isBackslash e = scanInterpCont src len (p + 2) depth (acc ++ "\\")
  | e == 'r' = scanInterpCont src len (p + 2) depth (acc ++ "\r")
  | e == '0' = scanInterpCont src len (p + 2) depth (acc ++ charToStr (fromOption ' ' (charFromCode 0)))
  | isUnicodeEsc src len p e = match uniEscChar src len p
    None => lexErrorTok p (uniEscErr src len p)
    Some c =>
      scanInterpCont src len (uniEscEnd src len p) depth (acc ++ charToStr c)
  | otherwise = scanInterpCont src len (p + 2) depth (acc ++ charToStr e)

-- ── Triple-quoted strings (`""" … """`) ─────────────────────────────────
-- Mirrors lib/lexer.mll `read_triple_string`: only `"""` closes (single/double
-- quotes are literal), raw newlines are kept, and `\{` opens an interpolation.
-- `leadingNl` tracks whether the content opened with a *raw* source newline; if
-- so the closing applies `stripIndent` (the dedent), matching `strip_indent`.
-- An interpolation opened from a triple string is marked by a NEGATIVE interp
-- depth (`id = -1`), so the closing `}` resumes the triple continuation.
-- are positions pos, pos+1, pos+2 all `"` (a `"""` delimiter at pos)?
isTripleAt : Array Char -> Int -> Int -> Bool
isTripleAt src len pos = pos + 2 < len
  && isQuote (at src pos)
  && isQuote (at src (pos + 1))
  && isQuote (at src (pos + 2))

firstNl : Bool -> String -> Bool
firstNl leadingNl acc = acc == "" || leadingNl

maybeStrip : Bool -> String -> String
maybeStrip True acc = stripIndent acc
maybeStrip False acc = acc

-- `startQ` is the offset of the opening `"""` (captured in `scanAt`),
-- threaded through so the final `TString` start offset covers the whole
-- literal, not just the closing delimiter (Defect B; same rationale as
-- `scanStr` above).
scanTriple : Array Char -> Int -> Int -> Int -> Int -> Int -> Bool -> String -> List RawTok
scanTriple src len p startQ depth id leadingNl acc
  | p >= len = RTok (TString (maybeStrip leadingNl acc)) startQ p :: scan src len p depth id
  | isTripleAt src len p = RTok (TString (maybeStrip leadingNl acc)) startQ (p + 3) :: scan src len (p + 3) depth id
  | isBackslash (at src p) && p + 1 < len && at src (p + 1) == '{' =
    -- `tripleInterpMark`-prefixed (see its doc comment, below `joinNlStr`): a
    -- PLAIN string's decoded content can also start with '\n' (a `\n` escape,
    -- e.g. stdlib's `"\n\{...} passed"`), so the post-pass can't tell TRIPLE
    -- vs PLAIN from the string content alone once escapes are decoded.
    RTok (TInterpOpen (tripleInterpMark ++ acc)) p (p + 2) :: scan src len (p + 2) depth (0 - 1)
  | isBackslash (at src p) && p + 1 < len =
    scanTripleEsc src len p startQ depth id leadingNl acc (at src (p + 1))
  | isNL (at src p) = scanTriple src len (p + 1) startQ depth id (firstNl leadingNl acc) (acc ++ "\n")
  | isQuote (at src p) && p + 1 < len && isQuote (at src (p + 1)) =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ "\"\"")
  | isQuote (at src p) =
    scanTriple src len (p + 1) startQ depth id leadingNl (acc ++ "\"")
  | otherwise = scanTriple src len (p + 1) startQ depth id leadingNl (acc ++ charToStr (at src p))

scanTripleEsc : Array Char -> Int -> Int -> Int -> Int -> Int -> Bool -> String -> Char -> List RawTok
scanTripleEsc src len p startQ depth id leadingNl acc e
  | e == 'n' =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ "\n")
  | e == 't' =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ "\t")
  | isQuote e =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ "\"")
  | isBackslash e =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ "\\")
  | e == 'r' =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ "\r")
  | e == '0' = scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ charToStr (fromOption ' ' (charFromCode 0)))
  | isUnicodeEsc src len p e = match uniEscChar src len p
    None => lexErrorTok p (uniEscErr src len p)
    Some c => scanTriple src len (uniEscEnd src len p) startQ depth id leadingNl (acc ++ charToStr c)
  | otherwise =
    scanTriple src len (p + 2) startQ depth id leadingNl (acc ++ charToStr e)

-- string part after an interpolation opened from a triple string closes
-- (`"""`→INTERP_END, `\{`→INTERP_MID re-marking id = -1). Emitted RAW (no
-- `stripIndent` here, unlike the plain `TString` case): a continuation
-- segment resumes mid-line right after a `}`, so `stripIndent` — which only
-- ever fires on a segment that ITSELF opens with '\n' — would be a no-op on
-- most of these anyway and, on the rare one that DOES happen to open with a
-- raw '\n' (e.g. `\{x}\nmore`), would wrongly dedent it by its own lone-line
-- indent instead of the WHOLE interpolated string's shared indent. The
-- `dedentTripleInterp` post-pass (below `joinNlStr`) does that dedent
-- jointly, correctly, from this and every sibling segment's true raw text.
scanInterpTripleCont : Array Char -> Int -> Int -> Int -> String -> List RawTok
scanInterpTripleCont src len p depth acc
  | p >= len = RTok (TInterpEnd acc) p p :: scan src len p depth 0
  | isTripleAt src len p =
    RTok (TInterpEnd acc) p (p + 3) :: scan src len (p + 3) depth 0
  | isBackslash (at src p) && p + 1 < len && at src (p + 1) == '{' =
    RTok (TInterpMid acc) p (p + 2) :: scan src len (p + 2) depth (0 - 1)
  | isBackslash (at src p) && p + 1 < len =
    scanInterpTripleEsc src len p depth acc (at src (p + 1))
  | isNL (at src p) = scanInterpTripleCont src len (p + 1) depth (acc ++ "\n")
  | isQuote (at src p) && p + 1 < len && isQuote (at src (p + 1)) =
    scanInterpTripleCont src len (p + 2) depth (acc ++ "\"\"")
  | isQuote (at src p) =
    scanInterpTripleCont src len (p + 1) depth (acc ++ "\"")
  | otherwise =
    scanInterpTripleCont src len (p + 1) depth (acc ++ charToStr (at src p))

scanInterpTripleEsc : Array Char -> Int -> Int -> Int -> String -> Char -> List RawTok
scanInterpTripleEsc src len p depth acc e
  | e == 'n' = scanInterpTripleCont src len (p + 2) depth (acc ++ "\n")
  | e == 't' = scanInterpTripleCont src len (p + 2) depth (acc ++ "\t")
  | isQuote e = scanInterpTripleCont src len (p + 2) depth (acc ++ "\"")
  | isBackslash e = scanInterpTripleCont src len (p + 2) depth (acc ++ "\\")
  | e == 'r' = scanInterpTripleCont src len (p + 2) depth (acc ++ "\r")
  | e == '0' = scanInterpTripleCont src len (p + 2) depth (acc ++ charToStr (fromOption ' ' (charFromCode 0)))
  | isUnicodeEsc src len p e = match uniEscChar src len p
    None => lexErrorTok p (uniEscErr src len p)
    Some c => scanInterpTripleCont src len (uniEscEnd src len p) depth (acc ++ charToStr c)
  | otherwise = scanInterpTripleCont src len (p + 2) depth (acc ++ charToStr e)

-- Strip the common leading indentation from a multiline string that opens with
-- '\n' (mirrors lib/lexer.mll `strip_indent`); blank lines are ignored when
-- computing the minimum indent.  No-op unless the content starts with '\n'.
stripIndent : String -> String
stripIndent s =
  let cs = stringToChars s
  stripIndentCs s cs (arrayLength cs)

stripIndentCs : String -> Array Char -> Int -> String
stripIndentCs s cs n
  | n == 0 = s
  | at cs 0 != '\n' = s
  | otherwise =
    let lines = splitLines cs 1 n ""
    let minInd = normalizeMin (minIndentGo lines indentSentinel)
    joinNlStr (stripLines minInd lines)

-- split chars [start, n) on '\n' into line strings (acc = current line)
splitLines : Array Char -> Int -> Int -> String -> List String
splitLines cs p n acc
  | p >= n = [acc]
  | at cs p == '\n' = acc :: splitLines cs (p + 1) n ""
  | otherwise = splitLines cs (p + 1) n (acc ++ charToStr (at cs p))

-- a blank/all-spaces line yields this sentinel (analogue of OCaml's max_int)
indentSentinel : Int
indentSentinel = 1000000000

indentOf : String -> Int
indentOf line =
  let cs = stringToChars line
  indentOfGo cs (arrayLength cs) 0

indentOfGo : Array Char -> Int -> Int -> Int
indentOfGo cs n i
  | i >= n = indentSentinel
  | at cs i == ' ' = indentOfGo cs n (i + 1)
  | otherwise = i

minInt : Int -> Int -> Int
-- Intentional: this IS the compiler's hot monomorphic Int min (AGENTS.md
-- anti-pattern: don't delegate hot inner-loop helpers to the dict-passed
-- prelude Ord method).
-- lint-disable-next-line rule-if-max-min
minInt a b = if a < b then a else b

minIndentGo : List String -> Int -> Int
minIndentGo [] acc = acc
minIndentGo (l::rest) acc = minIndentGo rest (minInt acc (indentOf l))

normalizeMin : Int -> Int
normalizeMin m = if m == indentSentinel then 0 else m

stripLines : Int -> List String -> List String
stripLines _ [] = []
stripLines k (l::rest) = stripLine k l :: stripLines k rest

stripLine : Int -> String -> String
stripLine k line =
  let cs = stringToChars line
  let n = arrayLength cs
  dropCharsToStr cs (minInt k n) n

dropCharsToStr : Array Char -> Int -> Int -> String
dropCharsToStr cs k n
  | k >= n = ""
  | otherwise = charToStr (at cs k) ++ dropCharsToStr cs (k + 1) n

joinNlStr : List String -> String
joinNlStr xs = joinWith "\n" xs

-- ── Triple-quoted interpolated-string dedent (#290) ─────────────────────────
-- `scanTriple`/`scanInterpTripleCont` dedent each raw segment INDEPENDENTLY,
-- and `stripIndent` is a no-op unless the segment ITSELF opens with a raw
-- '\n' (matching plain `TString`'s single-segment case). Of an interpolated
-- triple string's pieces, only `TInterpOpen` can ever start that way — a
-- `TInterpMid`/`TInterpEnd` always resumes mid-line right after a `}` — and
-- `scanTriple`'s `TInterpOpen` branch doesn't even call `maybeStrip` (unlike
-- its `TString` sibling two lines above it). So the interpolated case never
-- gets dedented past the first `\{`: the leading raw '\n' survives into the
-- value (reads as an extra blank line wherever it's printed) and the final
-- segment's trailing whitespace-only line is never collapsed away (dropping
-- the trailing blank line the dedent should have produced instead).
--
-- Fixed as a post-pass over the fully-scanned raw stream: re-dedent each
-- triple-quoted interpolation group (`TInterpOpen` .. `TInterpMid*` ..
-- `TInterpEnd`) as ONE unit. The embedded `\{expr}` tokens between segments
-- are ordinary code, not string content, so concatenating the segments'
-- literal text directly (no separator) reproduces exactly the string with
-- every `\{expr}` deleted — which is exactly what a shared minimum-indent
-- computation needs. (Nested string interpolation inside an embedded expr
-- isn't valid Medaka — see the file header — so no group nesting to guard.)
--
-- Detecting a TRIPLE-quoted group can't be done by inspecting the decoded
-- string content ("starts with '\n'"): a PLAIN string's content can ALSO
-- start with '\n' via a `\n` escape (stdlib's own `test.mdk` has exactly
-- this: `"\n\{intToString passed} passed, …"`), and by the time it's in a
-- token both look identical. So `scanTriple`'s `TInterpOpen` emission
-- prefixes `tripleInterpMark` — a control byte that can never appear in real
-- Medaka source — onto only the TRIPLE-flavored open; this pass keys off
-- that marker and strips it back off before the token goes anywhere else.
tripleInterpMark : String
tripleInterpMark = charToStr (fromOption ' ' (charFromCode 1))

hasTripleInterpMark : String -> Bool
hasTripleInterpMark s =
  let cs = stringToChars s
  arrayLength cs > 0 && at cs 0 == fromOption ' ' (charFromCode 1)

dropTripleInterpMark : String -> String
dropTripleInterpMark s =
  let cs = stringToChars s
  dropCharsToStr cs 1 (arrayLength cs)

-- The dedent itself is still gated on `leadingNl` (mirrors `maybeStrip`): a
-- single-line triple-quoted interpolation (`"""foo \{x}"""`, no raw '\n' at
-- all) is left completely untouched, same as a single-line plain triple
-- string.
startsWithNl : String -> Bool
startsWithNl s =
  let cs = stringToChars s
  arrayLength cs > 0 && at cs 0 == '\n'

endsWithNl : String -> Bool
endsWithNl s =
  let cs = stringToChars s
  let n = arrayLength cs
  n > 0 && at cs (n - 1) == '\n'

computeMinIndent : String -> Int
computeMinIndent joined =
  let cs = stringToChars joined
  let n = arrayLength cs
  -- position 1: the leading '\n' (guaranteed present) is dropped, same as
  -- `stripIndentCs` does for the single-segment case.
  normalizeMin (minIndentGo (splitLines cs 1 n "") indentSentinel)

-- Dedent a triple-interpolation group's raw segments (`openStr` already
-- confirmed to start with '\n') by the shared `minInd`. A segment's FIRST
-- line is only stripped when it actually starts a fresh source line — either
-- `openStr` itself (its leading '\n' is dropped outright, same as a plain
-- triple string's line 0) or a later segment whose PREVIOUS segment ended
-- right at a raw '\n'; otherwise that first line is a continuation of the
-- previous segment's unterminated trailing line and must be left untouched.
dedentGroupSegs : Int -> List String -> List String
dedentGroupSegs minInd (openStr::rest) =
  let cs = stringToChars openStr
  let openLines = splitLines cs 1 (arrayLength cs) ""
  let openOut = joinNlStr (stripLines minInd openLines)
  openOut :: dedentRestSegs minInd (endsWithNl openStr) rest
dedentGroupSegs _ [] = []

dedentRestSegs : Int -> Bool -> List String -> List String
dedentRestSegs _ _ [] = []
dedentRestSegs minInd atLineStart (seg::rest) =
  let cs = stringToChars seg
  let lines = splitLines cs 0 (arrayLength cs) ""
  let out = joinNlStr (stripFirstAware minInd atLineStart lines)
  out :: dedentRestSegs minInd (endsWithNl seg) rest

stripFirstAware : Int -> Bool -> List String -> List String
stripFirstAware _ _ [] = []
stripFirstAware minInd True (l::rest) =
  stripLine minInd l :: stripLines minInd rest
stripFirstAware minInd False (l::rest) = l :: stripLines minInd rest

-- Walk the tokens right after a triple-interpolation group's `TInterpOpen`,
-- collecting its own `TInterpMid`/`TInterpEnd` raw payloads in order and
-- splitting off everything through (and including) the closing `TInterpEnd`
-- from whatever comes after.
-- (Token fields are re-wrapped as `RTok ... mo me` rather than reusing an
-- `@`-bound whole-token variable via `::` — a latent typechecker bug
-- misinfers an `@`-pattern binding's type when it's later `::`-consed;
-- typechecker-internal, out of scope here, so this just avoids the shape.)
splitInterpGroup : List RawTok -> (List String, List RawTok, List RawTok)
splitInterpGroup [] = ([], [], [])
splitInterpGroup ((RTok (TInterpMid s) mo me)::rest) =
  let (segs, mid, after) = splitInterpGroup rest
  (s::segs, RTok (TInterpMid s) mo me :: mid, after)
splitInterpGroup ((RTok (TInterpEnd s) eo ee)::rest) =
  ([s], [RTok (TInterpEnd s) eo ee], rest)
splitInterpGroup (t::rest) =
  let (segs, mid, after) = splitInterpGroup rest
  (segs, t::mid, after)

-- Replace a group's own `TInterpMid`/`TInterpEnd` payloads (in order) with
-- their dedented values; every other token passes through unchanged.
substituteOwn : List String -> List RawTok -> List RawTok
substituteOwn _ [] = []
substituteOwn (v::vs) ((RTok (TInterpMid _) mo me)::rest) =
  RTok (TInterpMid v) mo me :: substituteOwn vs rest
substituteOwn (v::vs) ((RTok (TInterpEnd _) eo ee)::rest) =
  RTok (TInterpEnd v) eo ee :: substituteOwn vs rest
substituteOwn vals (t::rest) = t :: substituteOwn vals rest
substituteOwn [] (t::rest) = t :: substituteOwn [] rest

-- Top-level pass: rewrite every triple-quoted interpolation group's segments
-- to their jointly-dedented values; every other token passes through as-is.
dedentTripleInterp : List RawTok -> List RawTok
dedentTripleInterp [] = []
dedentTripleInterp ((RTok (TInterpOpen s) so eo)::rest)
  | hasTripleInterpMark s =
    let sReal = dropTripleInterpMark s
    let (rawSegs, midToks, afterEnd) = splitInterpGroup rest
    dedentTripleGroup sReal so eo rawSegs midToks afterEnd
dedentTripleInterp (t::rest) = t :: dedentTripleInterp rest

dedentTripleGroup : String -> Int -> Int -> List String -> List RawTok -> List RawTok -> List RawTok
dedentTripleGroup sReal so eo rawSegs midToks afterEnd
  | startsWithNl sReal =
    let allRaw = sReal::rawSegs
    let minInd = computeMinIndent (concatAll allRaw)
    match dedentGroupSegs minInd allRaw
      openStr'::restVals => RTok (TInterpOpen openStr') so eo :: substituteOwn restVals midToks ++ dedentTripleInterp afterEnd
      [] => RTok (TInterpOpen sReal) so eo :: midToks ++ dedentTripleInterp afterEnd
  | otherwise =
    RTok (TInterpOpen sReal) so eo :: midToks ++ dedentTripleInterp afterEnd

concatAll : List String -> String
concatAll [] = ""
concatAll (x::xs) = x ++ concatAll xs

-- char literals — escapes processed into the value, mirroring lib/lexer.mll's
-- `read_char` (Phase 133): `\n \t \r \0 \\ \'` and `\u{…}`, else raw chars up to
-- the closing quote.  `pos` is at the opening `'`; content starts at `pos + 1`.
-- The decoded content of a `\<e>` character escape, or `None` if `<e>` is not a
-- valid escape. A char adds `\'` to the shared `commonEscDecode` table (a bare
-- `'` there would close the literal); everything else — including any
-- backslash-letter that is not a real escape (`\v`) — mirrors the string path
-- and is a lex error (#668). `\u{…}` is handled separately by `readCharUnicode`.
charEscDecode : Char -> Option String
charEscDecode e
  | isApos e = Some "'"
  | otherwise = commonEscDecode e

scanChar : Array Char -> Int -> Int -> Int -> Int -> List RawTok
scanChar src len pos depth id = readChar src len (pos + 1) depth id

-- A char literal is EXACTLY ONE codepoint between `'`s (`docs/spec/SYNTAX.md`):
-- one raw codepoint (possibly multi-BYTE, e.g. `'é'`/`'😀'`), one of the
-- escapes in `charEscDecode`, or a `\u{…}` codepoint. `p` is just past the
-- opening `'`; `p - 1` is that quote (used as the error caret). Before #668 the
-- char path validated NONE of this: `'ab'` lexed as a two-codepoint `TChar`
-- (an S0 run≠build divergence), `''` as an empty one, and `'\v'` as bare `v`.
readChar : Array Char -> Int -> Int -> Int -> Int -> List RawTok
readChar src len p depth id
  | p >= len = lexErrorTok (p - 1) charUntermMsg
  | isBackslash (at src p) && p + 1 >= len = lexErrorTok (p - 1) charUntermMsg
  | isBackslash (at src p) && at src (p + 1) == 'u' && p + 2 < len && at src (p + 2) == '{' = readCharUnicode src len p depth id
  | isBackslash (at src p) = escChar src len p depth id (at src (p + 1))
  | isApos (at src p) = lexErrorTok (p - 1) "character literal is empty. A character is exactly one codepoint — write `'\\0'` for the NUL character, or use a `\"\"` string for an empty value"
  | otherwise = rawChar src len p depth id

charUntermMsg : String
charUntermMsg = "character literal is not terminated. A character is one codepoint between single quotes, as in `'a'` or `'\\n'`"

-- `\<e>'` escape forms: three source chars (`\`, e, `'`), so advance by 3.
-- The closing quote at `p + 2` is REQUIRED — a valid escape followed by more
-- source (`'\na'`) is still more than one codepoint and is rejected.
escChar : Array Char -> Int -> Int -> Int -> Int -> Char -> List RawTok
escChar src len p depth id e = match charEscDecode e
  None => lexErrorTok p "invalid escape sequence '\\\{charToStr e}'"
  Some s =>
    if p + 2 < len && isApos (at src (p + 2)) then
      RTok (TChar s) p (p + 3) :: scan src len (p + 3) depth id
    else
      lexErrorTok (p - 1) charUntermMsg

-- A single RAW codepoint, which must be immediately closed by `'`. `at src p` is
-- one codepoint (the source is a codepoint array), so a multi-BYTE codepoint is
-- ONE element and is accepted; `'ab'` is two elements and is rejected.
rawChar : Array Char -> Int -> Int -> Int -> Int -> List RawTok
rawChar src len p depth id
  | p + 1 < len && isApos (at src (p + 1)) = RTok (TChar (charToStr (at src p))) p (p + 2) :: scan src len (p + 2) depth id
  | otherwise =
    let e = charClose src len p
    if e >= len then
      lexErrorTok (p - 1) charUntermMsg
    else
      lexErrorTok (p - 1) "character literal must be a single codepoint, but `'\{substr src p e}'` has more than one. Use a `\"...\"` string for text, or `'\\u{...}'` for one codepoint by its hex value"

charClose : Array Char -> Int -> Int -> Int
charClose src len p
  | p >= len = p
  | isApos (at src p) = p
  | otherwise = charClose src len (p + 1)

-- ── `\u{HEX}` codepoint guard (#567) ─────────────────────────────────────────
-- `charFromCode` (`runtime/medaka_rt.c`) ALREADY bounds [0, 0x10FFFF], already
-- excludes the UTF-16 surrogate block, and already returns `None`. The #567 defect
-- was never a missing check — it was DISCARDING that `None` with `fromOption ' '`,
-- which turned a correct rejection into a SPACE (exit 0, no diagnostic).
--
-- Honouring the `None` is necessary but NOT sufficient. `parseRadix` accumulates in
-- the compiler's own WRAPPING 63-bit `Int`, so a long escape can wrap back INSIDE
-- the valid range and reach `charFromCode` looking legitimate:
-- `\u{8000000000000041}` = 2^63+65 wraps to 65 and printed `A`. So the digit COUNT
-- is checked FIRST: >6 significant hex digits is >= 0x1000000 > 0x10FFFF and is
-- rejected without parsing at all, and <=6 significant digits is <= 0xFFFFFF < 2^62,
-- so the `parseRadix` that survives is exact and CANNOT wrap. Range and wrap are two
-- bounds, not one; either alone leaves the other live.
--
-- `sigRadixDigits`/`radixMagOverflows` (#556) are deliberately NOT reused: they strip
-- `_` separators, which `uHexEnd` does not accept inside `\u{…}` anyway, and
-- `radixMagOverflows` models "one leading digit followed by zeros", a shape that
-- cannot express the 0x10FFFF bound.

-- ── Well-formedness of the digit run itself (#592). The bounds above are about the
-- VALUE an escape names; these are about whether it is an escape at all.
--
-- `uHexEnd` stops at the first non-hex-digit and does not care WHAT stopped it, and
-- `uniEscEnd` then steps blindly past that char assuming it is `}`. Nothing checked
-- either assumption, so a malformed escape silently became a DIFFERENT string at
-- exit 0: `"a\u{4_1}b"` took `4` as the whole codepoint (a fabricated U+0004) and let
-- `1}` fall through into the string as literal data, and `"a\u{}b"` parsed an empty
-- run as `charFromCode 0` — a silent NUL. Both are valid scalar values, so no range
-- check above can see them: this is a SYNTAX defect, not a range defect.
--
-- The rule enforced here is the whole grammar of the run: NON-EMPTY, hex digits only,
-- `}`-terminated. `uniEscEnd`'s `+ 1` is sound only because `uniEscChar` rejects
-- everything else before any caller reaches it.

-- Is the escape's digit run non-empty AND closed by the `}` that `uniEscEnd` assumes?
uniEscWellFormed : Array Char -> Int -> Int -> Bool
uniEscWellFormed src len p =
  let s = p + 3
  let he = uHexEnd src len s
  he > s && he < len && at src he == '}'

-- Significant hex digits of [p, endp) — the LEADING ZERO RUN dropped. `\u{0000041}`
-- is seven digits but only two significant, and is a perfectly good `A`: counting raw
-- digits here would reject it.
uniHexSigLen : Array Char -> Int -> Int -> Int
uniHexSigLen src p endp
  | p >= endp = 0
  | at src p == '0' = uniHexSigLen src (p + 1) endp
  | otherwise = endp - p

-- The escape's codepoint, or `None` when it has too many digits to be one. `Some cp`
-- guarantees `cp` was parsed EXACTLY (no wrap); it does NOT mean `cp` is a valid
-- scalar value — that call belongs to `charFromCode`.
uniEscCode : Array Char -> Int -> Int -> Option Int
uniEscCode src len p =
  let s = p + 3
  let he = uHexEnd src len s
  if uniHexSigLen src s he > 6 then None else Some (parseRadix src s he 16 0)

-- The escape exactly as written (`\u{110000}`), so the diagnostic can quote the
-- user's own text instead of a re-rendered number.
uniEscText : Array Char -> Int -> Int -> String
uniEscText src len p = substr src p (uHexEnd src len (p + 3) + 1)

-- The decoded Char, or `None` for any `\u{…}` escape the lexer must reject. Shape is
-- checked BEFORE value: an ill-formed run has no codepoint to range-check, and its
-- `uHexEnd` is not a trustworthy end position for `uniEscText` to quote.
uniEscChar : Array Char -> Int -> Int -> Option Char
uniEscChar src len p
  | not (uniEscWellFormed src len p) = None
  | otherwise = match uniEscCode src len p
    None => None
    Some cp => charFromCode cp

-- The UTF-16 surrogate block: 0xD800-0xDFFF, the halves of a surrogate PAIR, which
-- encode nothing on their own and are the one hole in `charFromCode`'s range. Written
-- in decimal only because `fmt` normalizes an integer literal's radix to decimal —
-- 55296 = 0xD800 and 57343 = 0xDFFF, the bounds the diagnostic below names in hex.
uniIsSurrogate : Int -> Bool
uniIsSurrogate cp = cp >= 55296 && cp <= 57343

-- WHY `uniEscChar` said `None`. `parseErrCode` keys L-BAD-UNICODE-ESCAPE on the
-- "unicode escape" prefix, so both arms share it verbatim: one user-facing defect
-- should not need two diagnostic codes (same reasoning as `radixTok`'s message).
-- The `_` arm covers BOTH an in-range-Int-but-not-a-codepoint value and the `None`
-- (too many digits to parse exactly) case: to the user both are "too big".
--
-- The ill-formed arms come FIRST and must not use `uniEscText`: it quotes through
-- `uHexEnd + 1`, which is the very position these arms exist to disbelieve.
--
-- ⭐ THE `_` FORK (#592), DECIDED: `_` is a digit separator in Medaka INTEGER literals
-- (`1_000`, `0xD_EAD`, via `radixEnd`) but is NOT one inside `\u{…}`. It gets a named
-- arm rather than falling into the generic "expected `}`" message, because a user who
-- wrote `\u{4_1}` was reading it as `\u{41}` and deserves to be told so.
-- WHY reject rather than accept: rejecting is the REVERSIBLE direction. `\u{4_1}` is a
-- lex error today, so it could be widened to MEAN `\u{41}` later without breaking any
-- program that compiles now; accepting it here could never be walked back. A codepoint
-- is also at most 6 digits — separators exist to group long runs, and Unicode's own
-- notation (U+10FFFF) is unbroken. See docs/spec/SYNTAX.md, which states this grammar.
-- WHY the run is ill-formed. `s` is the first digit position, `he` the char that
-- stopped the run — the one `uniEscEnd` used to step blindly past.
uniEscTermErr : Array Char -> Int -> Int -> Int -> String
uniEscTermErr src len s he
  | he >= len = "unicode escape is not terminated. Expected one to six hex digits (0-9, a-f, A-F) then `}`, but the file ended"
  | at src he == '_' = "unicode escape uses a `_` separator, which is not allowed here. `_` groups digits in integer literals (`1_000`, `0xD_EAD`), but a `\\u{...}` codepoint must be an unbroken run of hex digits — write the digits unbroken, as in `\\u{41}` rather than `\\u{4_1}`"
  | he == s && at src he == '}' = "unicode escape `\\u{}` has no digits. A codepoint needs at least one hex digit — `\\u{41}` is 'A' and `\\u{0}` is NUL"
  | he == s = "unicode escape is not terminated. Expected one to six hex digits (0-9, a-f, A-F) then `}`, but found `\{charToStr (at src he)}`"
  | otherwise = "unicode escape is not terminated. Expected `}` after the hex digits, but found `\{charToStr (at src he)}`"

uniEscErr : Array Char -> Int -> Int -> String
uniEscErr src len p
  | not (uniEscWellFormed src len p) =
    uniEscTermErr src len (p + 3) (uHexEnd src len (p + 3))
  | otherwise = match uniEscCode src len p
    Some cp if uniIsSurrogate cp => "unicode escape '\{uniEscText src len p}' is a UTF-16 surrogate, not a character. Codepoints D800-DFFF only ever encode one half of a surrogate pair and are never valid on their own"
    _ => "unicode escape '\{uniEscText src len p}' is out of range. A codepoint must be at most 10FFFF"

-- `\u{HEX}'` : the hex codepoint, then `}` (`he`), then the closing `'` (`he + 1`).
-- The closing quote is REQUIRED, exactly as in `escChar`/`rawChar`: a `\u{…}` escape
-- is still ONE codepoint, so `'\u{41}z` (unterminated) and `'\u{41}ab'` (a second
-- codepoint after the escape) are rejected rather than resumed mid-literal (#668).
readCharUnicode : Array Char -> Int -> Int -> Int -> Int -> List RawTok
readCharUnicode src len p depth id = match uniEscChar src len p
  None => lexErrorTok p (uniEscErr src len p)
  Some c =>
    let he = uHexEnd src len (p + 3)
    if he + 1 < len && isApos (at src (he + 1)) then
      RTok (TChar (charToStr c)) p (he + 2) :: scan src len (he + 2) depth id
    else
      lexErrorTok (p - 1) charUntermMsg

uHexEnd : Array Char -> Int -> Int -> Int
uHexEnd src len p
  | p < len && isHexDigit (at src p) = uHexEnd src len (p + 1)
  | otherwise = p

-- ── `\u{HEX}` unicode escapes inside *strings* (mirrors lib/lexer.mll's
-- `'\\' 'u' '{' hex '}'` rule in read_string / read_triple_string /
-- read_interp_continue / read_interp_triple_continue).  `p` is at the backslash;
-- the codepoint is the hex run after `\u{`, terminated by `}`.  Unlike the char
-- form there is no trailing closing quote, so the resume position is just past
-- the `}` (he + 1).  `isUnicodeEsc` is the guard the escape handlers test before
-- decoding: the char after the backslash is `u` and is followed by `{`.
isUnicodeEsc : Array Char -> Int -> Int -> Char -> Bool
isUnicodeEsc src len p e = e == 'u' && p + 2 < len && at src (p + 2) == '{'

-- Resume position: past the `}`. The `+ 1` is a CLAIM that a `}` sits at `uHexEnd` —
-- unchecked until #592, which is exactly how a malformed escape's tail leaked into the
-- string as data. It is sound only on the `Some` path: every one of the five scan
-- sites reaches this via `uniEscChar`, which rejects any run `uniEscWellFormed` fails.
uniEscEnd : Array Char -> Int -> Int -> Int
uniEscEnd src len p = uHexEnd src len (p + 3) + 1

-- operators + punctuation
emit : Array Char -> Int -> Int -> Int -> Int -> Token -> Int -> Int -> List RawTok
emit src len pos depth id tok length ddelta =
  RTok tok pos (pos + length) :: scan src len (pos + length) (depth + ddelta) id

scanOp : Array Char -> Int -> Int -> Int -> Int -> Char -> List RawTok
scanOp src len pos depth id c
  | is3 src len pos '.' '.' '.' = emit src len pos depth id TEllipsis 3 0
  | is3 src len pos '.' '.' '=' = emit src len pos depth id TDotDotEq 3 0
  | is2 src len pos '[' '|' = emit src len pos depth id TLArray 2 1
  | is2 src len pos '|' ']' = emit src len pos depth id TRArray 2 (0 - 1)
  | is2 src len pos '=' '>' = emit src len pos depth id TFatArrow 2 0
  | is2 src len pos '-' '>' = emit src len pos depth id TArrow 2 0
  | is2 src len pos '<' '-' = emit src len pos depth id TLArrow 2 0
  | is2 src len pos ':' ':' = emit src len pos depth id TCons 2 0
  | is2 src len pos ':' '=' = emit src len pos depth id TColonEq 2 0
  | is2 src len pos '+' '+' = emit src len pos depth id TPlusPlus 2 0
  | is2 src len pos '=' '=' = emit src len pos depth id TEqEq 2 0
  | is2 src len pos '!' '=' = emit src len pos depth id TNeq 2 0
  | is2 src len pos '/' '=' = emit src len pos depth id TSlashEq 2 0
  | is2 src len pos '<' '=' = emit src len pos depth id TLeq 2 0
  | is2 src len pos '>' '=' = emit src len pos depth id TGeq 2 0
  | is2 src len pos '&' '&' = emit src len pos depth id TAnd 2 0
  | is2 src len pos '|' '|' = emit src len pos depth id TOr 2 0
  | is2 src len pos '|' '>' = emit src len pos depth id TPipeRight 2 0
  | is2 src len pos '>' '>' = emit src len pos depth id TRCompose 2 0
  | is2 src len pos '<' '<' = emit src len pos depth id TLCompose 2 0
  | is2 src len pos '.' '{' = emit src len pos depth id TDotLBrace 2 1
  | is2 src len pos '.' '*' = emit src len pos depth id TDotStar 2 0
  | is2 src len pos '.' '.' = emit src len pos depth id TDotDot 2 0
  | otherwise = singleOp src len pos depth id c

singleOp : Array Char -> Int -> Int -> Int -> Int -> Char -> List RawTok
singleOp src len pos depth id '+' = emit src len pos depth id TPlus 1 0
singleOp src len pos depth id '-' =
  emit src len pos depth id (minusTok src len pos) 1 0
singleOp src len pos depth id '*' = emit src len pos depth id TStar 1 0
singleOp src len pos depth id '/' = emit src len pos depth id TSlash 1 0
singleOp src len pos depth id '<' = emit src len pos depth id TLt 1 0
singleOp src len pos depth id '>' = emit src len pos depth id TGt 1 0
singleOp src len pos depth id '=' = emit src len pos depth id TEqual 1 0
singleOp src len pos depth id ':' = emit src len pos depth id TColon 1 0
singleOp src len pos depth id ',' = emit src len pos depth id TComma 1 0
singleOp src len pos depth id '.'
  | isMalformedLeadingDot src len pos = malformedLeadingDotTok src len pos
  | otherwise = emit src len pos depth id TDot 1 0
singleOp src len pos depth id '|' = emit src len pos depth id TPipe 1 0
singleOp src len pos depth id '(' = emit src len pos depth id TLParen 1 1
singleOp src len pos depth id ')' = emit src len pos depth id TRParen 1 (0 - 1)
singleOp src len pos depth id '[' =
  emit src len pos depth id (bracketTok src pos) 1 1
singleOp src len pos depth id ']' =
  emit src len pos depth id TRBracket 1 (0 - 1)
singleOp src len pos depth id '{' = openBrace src len pos depth id
singleOp src len pos depth id '}' = closeBrace src len pos depth id
singleOp src len pos depth id '!' = emit src len pos depth id TBang 1 0
singleOp src len pos depth id '%' = emit src len pos depth id TMod 1 0
singleOp src len pos depth id '@' =
  emit src len pos depth id (atToken src pos) 1 0
-- `\` is never a valid Medaka token (no backslash-prefixed syntax outside
-- string/char literal escapes, which are consumed by the string/char lexer
-- before `singleOp` ever sees a bare `\`) — a stray top-level `\` is always a
-- Haskell lambda (`\x -> e`) written by reflex. Zero false-positive risk.
singleOp src len pos depth id '\\' =
  lexErrorTok
    pos
    "unexpected '\\'. Medaka lambdas are written 'x => e' (not '\\x -> e')"
-- `$` is likewise never a valid Medaka character — Haskell's low-precedence
-- application operator has no Medaka equivalent; direct application, parens,
-- or `|>` all cover it. Zero false-positive risk.
singleOp src len pos depth id '$' =
  lexErrorTok
    pos
    "Medaka has no '$'. Apply directly 'f x', parenthesize '(f x)', or pipe with '|>'"
singleOp src len pos depth id c =
  lexErrorTok pos "unexpected character '\{charToStr c}'"

-- A `[` lexes as TLBracketTight (postfix indexing, `a[i]`) when it
-- immediately follows an expr-ender (alnum/`_`/`)`/`]`/`"`) with no
-- intervening space — else it's an ordinary TLBracket (list literal /
-- spaced application arg). Mirrors the `atToken`/`minusTok` adjacency tests.
bracketTok : Array Char -> Int -> Token
bracketTok src pos
  | pos > 0 && isExprEnd (at src (pos - 1)) = TLBracketTight
  | otherwise = TLBracket

isExprEnd : Char -> Bool
isExprEnd c = isAlnum c || c == ')' || c == ']' || c == '"'

-- `.5`-shaped (#677): a bare `.` immediately followed by a digit is never
-- valid Medaka — a member-access field name is an identifier (starts with a
-- lowercase letter/`_`), never a digit — so this can only be a float missing
-- its leading digit.  Skipped when the dot is itself glued to the END of an
-- expression (`isExprEnd`: alnum/`)`/`]`/`"`) — `x.5`, `arr[0].5`,
-- `f().5` — since there `.5` is ambiguous enough (could be read as a
-- botched field access on an arbitrary receiver, not obviously a float) that
-- the existing downstream diagnostic is left in place rather than risk a
-- wrong root cause.
isMalformedLeadingDot : Array Char -> Int -> Int -> Bool
isMalformedLeadingDot src len pos = pos + 1 < len
  && isDigit (at src (pos + 1))
  && (pos == 0 || not (isExprEnd (at src (pos - 1))))

malformedLeadingDotTok : Array Char -> Int -> Int -> List RawTok
malformedLeadingDotTok src len pos =
  let d = digitsEnd src len (pos + 1)
  let e = expEnd src len d
  let bad = substr src pos e
  lexErrorTok
    pos
    "malformed float literal `\{bad}`: a float needs a digit before the decimal point — write `0\{bad}`"

-- `@` is the as-pattern operator (AS_AT) when it immediately follows an
-- identifier (no intervening space), else the impl-hint prefix (AT).  Mirrors
-- lib/lexer.mll's `last_ident_end` adjacency test: only a lowercase/underscore
-- identifier counts (an UPPER ctor or a number does not).
atToken : Array Char -> Int -> Token
atToken src pos
  | pos <= 0 = TAt
  | isAlnum (at src (pos - 1)) && identStartLower src (identRunStart src (pos - 1)) = TAsAt
  | otherwise = TAt

-- A bare `-` lexes as TMinusTight (a distinct token the parser can grab as a
-- negative-literal argument) exactly when it has a space/tab to its LEFT and a
-- digit to its RIGHT — the `f -1` / `5 -1` asymmetric-spacing shape.  Every
-- TMinus matcher in the parser also accepts TMinusTight, so this only changes
-- parsing in application argument position (where the head is non-numeric).
minusTok : Array Char -> Int -> Int -> Token
minusTok src len pos
  | pos > 0 && pos + 1 < len && isSpace (at src (pos - 1)) && isDigit (at src (pos + 1)) = TMinusTight
  | otherwise = TMinus

identRunStart : Array Char -> Int -> Int
identRunStart src p
  | p <= 0 = 0
  | isAlnum (at src (p - 1)) = identRunStart src (p - 1)
  | otherwise = p

identStartLower : Array Char -> Int -> Bool
identStartLower src p = isLower (at src p) || at src p == '_'

-- `{` and `}` route through interp depth when inside a `\{ … }` interpolation.
-- `id` encodes that depth: positive = inside a single-quoted-string interp,
-- negative = inside a triple-quoted-string interp (magnitude = brace nesting),
-- 0 = ordinary braces (tracked by `depth`).
openBrace : Array Char -> Int -> Int -> Int -> Int -> List RawTok
openBrace src len pos depth id
  | id > 0 = RTok TLBrace pos (pos + 1) :: scan src len (pos + 1) depth (id + 1)
  | id < 0 = RTok TLBrace pos (pos + 1) :: scan src len (pos + 1) depth (id - 1)
  | otherwise =
    RTok TLBrace pos (pos + 1) :: scan src len (pos + 1) (depth + 1) id

closeBrace : Array Char -> Int -> Int -> Int -> Int -> List RawTok
closeBrace src len pos depth id
  | id > 1 = RTok TRBrace pos (pos + 1) :: scan src len (pos + 1) depth (id - 1)
  | id == 1 = scanInterpCont src len (pos + 1) depth ""
  | id == 0 - 1 = scanInterpTripleCont src len (pos + 1) depth ""
  | id < 0 = RTok TRBrace pos (pos + 1) :: scan src len (pos + 1) depth (id + 1)
  | otherwise =
    RTok TRBrace pos (pos + 1) :: scan src len (pos + 1) (depth - 1) id

-- newline + indentation handling
handleNewline : Array Char -> Int -> Int -> Int -> Int -> List RawTok
handleNewline src len pos depth id =
  let (indent, np) = consumeNl src len pos 0
  afterNl src len np depth id indent pos

-- consume one or more (newline white*) runs; returns (indentOfLastLine, newPos)
consumeNl : Array Char -> Int -> Int -> Int -> (Int, Int)
consumeNl src len p indent
  | p >= len = (indent, p)
  | isCR (at src p) && p + 1 < len && isNL (at src (p + 1)) =
    consumeNl src len (p + 2) 0
  | isNL (at src p) = consumeNl src len (p + 1) 0
  | isCR (at src p) = consumeNl src len (p + 1) 0
  | isSp (at src p) = consumeNl src len (p + 1) (indent + 1)
  | isTab (at src p) = consumeNl src len (p + 1) ((indent / 8 + 1) * 8)
  | otherwise = (indent, p)

-- A newline run is turned into an `RNewline` marker for the layout pass to
-- interpret.  Comment-only lines and leading-operator continuation lines are
-- handled here at scan time (so they never reach layout).  NOTE: the historical
-- `depth > 0 = scan …` early-out (drop every bracket-interior newline) is GONE
-- (LAYOUT-BRACKETS §6.1): RNewlines now flow into the layout pass *even inside
-- brackets*, where the bracket-frame logic drops them in free-form regions but
-- keeps them live inside a herald-armed nested block.  Outside brackets nothing
-- changes — `nextIsComment`/`isContinuation` already ran for every newline.
afterNl : Array Char -> Int -> Int -> Int -> Int -> Int -> Int -> List RawTok
afterNl src len np depth id indent nlPos
  | nextIsComment src len np = scan src len np depth id
  | isContinuation src len np =
    emit src len np depth id (continuationTok src len np) 2 0
  | otherwise = RNewline indent nlPos :: scan src len np depth id

-- Comment-only line transparency: a line beginning with a comment (`--` or `{-`)
-- must NOT emit a layout marker (INDENT/DEDENT/NEWLINE) based on its own column.
-- When a newline run lands on a comment start we suppress the RNewline and keep
-- scanning; the newline ending the comment line re-enters afterNl and layout is
-- decided by the next *code* line.  Mirrors lib/lexer.mll `next_is_comment`.
nextIsComment : Array Char -> Int -> Int -> Bool
nextIsComment src len p = p + 1 < len
  && (at src p == '-' && at src (p + 1) == '-' || at src p == '{' && at src (p + 1) == '-')

-- leading-operator line continuation (|> >> << && || ++ ::)
isContinuation : Array Char -> Int -> Int -> Bool
isContinuation src len np = is2 src len np '|' '>'
  || is2 src len np '>' '>'
  || is2 src len np '<' '<'
  || is2 src len np '&' '&'
  || is2 src len np '|' '|'
  || is2 src len np '+' '+'
  || is2 src len np ':' ':'

continuationTok : Array Char -> Int -> Int -> Token
continuationTok src len np
  | is2 src len np '|' '>' = TPipeRight
  | is2 src len np '>' '>' = TRCompose
  | is2 src len np '<' '<' = TLCompose
  | is2 src len np '&' '&' = TAnd
  | is2 src len np '|' '|' = TOr
  | is2 src len np '+' '+' = TPlusPlus
  | otherwise = TCons

-- ── Layout pass: RawTok stream -> Token stream ──────────────────────────
-- Mirrors lib/lexer.mll `handle_indent` + the Phase 137 continuation-line
-- resolution + the EOF unwind.  Threads `prev` (the previous significant token)
-- and `opener` (whether a `match`/`record` header appeared on the line being
-- ended), so a would-be INDENT can be suppressed into an application
-- continuation when the deeper line just continues the current expression.
-- The layout pass threads each token's source char offset alongside it as a
-- `(Token, Int)` pair.  Real tokens carry their `RTok` offset; synthetic
-- NEWLINE/INDENT/DEDENT tokens carry the offset of the `RNewline` (or the EOF
-- position) that produced them, so the position side-channel can assign every
-- token a 1-based source line.  `tokenize` projects out `fst`, so the Token
-- stream the parser matches on is byte-identical regardless of this threading.
--
-- `frames` is the BRACKET-FRAME STACK (LAYOUT-BRACKETS §6.1).  It is empty at
-- top level (no enclosing bracket).  Each open bracket `( [ [| { .{` pushes a
-- frame holding the count of nested layout contexts that bracket has opened
-- (head = innermost bracket).  Inside a bracket the DEFAULT is free-form
-- (newlines invisible); when a herald (`match`/`do`/`function`/`record`) opens a
-- block the head frame increments and the herald's `INDENT`/`NEWLINE`/`DEDENT`
-- become live, exactly like top-level layout — until they dedent back below the
-- herald column (frame → 0, free-form again) or the matching bracket closer
-- force-flushes the pending `DEDENT`s.
layout : List RawTok -> List Int -> List Int -> Option Token -> Bool -> List (Token, Int)
layout [] stack frames prev opener = closeAll stack 0
layout ((RTok t off _)::rest) stack frames prev opener
  | bracketOpener t =
    (t, off) :: layout rest stack (0::frames) (Some t) (opener || isOpener t)
  | bracketCloser t = flushClose t off rest stack frames opener
  | otherwise =
    (t, off) :: layout rest stack frames (Some t) (opener || isOpener t)
layout ((RComment _ _)::rest) stack frames prev opener =
  layout rest stack frames prev opener
layout ((RNewline col off)::rest) stack frames prev opener =
  applyNl col off rest stack frames prev opener

-- A bracket closer force-flushes every nested layout context opened in the
-- innermost bracket frame (emitting `NEWLINE DEDENT` per context, popping the
-- indent stack) BEFORE the closer token, so the bracket pair stays balanced and
-- the grammar sees `… NEWLINE DEDENT )` (the same shape a top-level block dedent
-- produces).  Then it pops the frame and emits the closer.  `opener` is threaded
-- (and OR-ed with `isOpener t`) so a same-line herald flag survives the closer
-- — e.g. `match args () \n arms`: the `(`/`)` of the `()` scrutinee must NOT
-- clear the `match` opener flag, or the arms' INDENT would be suppressed.
flushClose : Token -> Int -> List RawTok -> List Int -> List Int -> Bool -> List (Token, Int)
flushClose t off rest stack [] opener =
  (t, off) :: layout rest stack [] (Some t) (opener || isOpener t)
flushClose t off rest stack (f::fs) opener =
  flushCloseGo t off rest stack f fs opener

flushCloseGo : Token -> Int -> List RawTok -> List Int -> Int -> List Int -> Bool -> List (Token, Int)
flushCloseGo t off rest [] f fs opener =
  (t, off) :: layout rest [] fs (Some t) (opener || isOpener t)
flushCloseGo t off rest (top::tl) f fs opener
  | f <= 0 =
    (t, off) :: layout rest (top::tl) fs (Some t) (opener || isOpener t)
  | otherwise = (TNewline, off) :: (TDedent, off) :: flushCloseGo t off rest tl (f - 1) fs opener

bracketOpener : Token -> Bool
bracketOpener TLParen = True
bracketOpener TLBracket = True
bracketOpener TLBracketTight = True
bracketOpener TLArray = True
bracketOpener TLBrace = True
bracketOpener TDotLBrace = True
bracketOpener _ = False

bracketCloser : Token -> Bool
bracketCloser TRParen = True
bracketCloser TRBracket = True
bracketCloser TRArray = True
bracketCloser TRBrace = True
bracketCloser _ = False

isOpener : Token -> Bool
isOpener TMatch = True
isOpener _ = False

-- a token that can syntactically END an expression (atom-ender whitelist)
canEndExpr : Token -> Bool
canEndExpr (TIdent _) = True
canEndExpr (TUpper _) = True
canEndExpr (TInt _ _) = True
canEndExpr (TFloat _) = True
canEndExpr (TString _) = True
canEndExpr (TChar _) = True
canEndExpr (TBool _) = True
canEndExpr (TInterpEnd _) = True
canEndExpr TRParen = True
canEndExpr TRBracket = True
canEndExpr TRBrace = True
canEndExpr TRArray = True
canEndExpr TUnderscore = True
canEndExpr _ = False

prevCanEnd : Option Token -> Bool
prevCanEnd (Some t) = canEndExpr t
prevCanEnd None = False

-- an expression binary operator that, ending a logical line, continues the
-- expression onto the next (deeper-indented) line: the line terminator is
-- suppressed so `a ++\n  b` lexes identically to `a ++ b`.  Mirrors
-- `lib/lexer.mll` `is_trailing_continuation_op`.  Arrows (-> => <-) are
-- excluded deliberately; trailing `-` is always binary here.
isTrailingContinuationOp : Token -> Bool
isTrailingContinuationOp TPlus = True
isTrailingContinuationOp TMinus = True
isTrailingContinuationOp TStar = True
isTrailingContinuationOp TSlash = True
isTrailingContinuationOp TMod = True
isTrailingContinuationOp TPlusPlus = True
isTrailingContinuationOp TCons = True
isTrailingContinuationOp TEqEq = True
isTrailingContinuationOp TNeq = True
isTrailingContinuationOp TLt = True
isTrailingContinuationOp TGt = True
isTrailingContinuationOp TLeq = True
isTrailingContinuationOp TGeq = True
isTrailingContinuationOp TAnd = True
isTrailingContinuationOp TOr = True
isTrailingContinuationOp TPipeRight = True
isTrailingContinuationOp TRCompose = True
isTrailingContinuationOp TLCompose = True
isTrailingContinuationOp (TBacktickIdent _) = True
isTrailingContinuationOp _ = False

prevIsTrailingOp : Option Token -> Bool
prevIsTrailingOp (Some t) = isTrailingContinuationOp t
prevIsTrailingOp None = False

-- Inside a bracket (free-form), the ONLY lines that arm a nested layout context
-- are the locked herald set (LAYOUT-BRACKETS §6.1): `match`/`record` (carried by
-- the `opener` flag) and the `do` keyword (whose own next line opens the
-- block).  Crucially this is NOT the generic top-level `not prevCanEnd` rule
-- — after a `,` (or `=` etc.) `prevCanEnd` is also false, but a `,`-led
-- continuation like `[1,\n 2]` must STAY free-form, not open a block.  The
-- bare-`INDENT` block herald is DEFERRED inside brackets (no keyword to arm it
-- without regressing free-form).
armsHerald : Bool -> Option Token -> Bool
armsHerald opener (Some TDo) = True
armsHerald opener _ = opener

-- a token that can START an application-argument atom
canStartAtom : Token -> Bool
canStartAtom (TInt _ _) = True
canStartAtom (TFloat _) = True
canStartAtom (TString _) = True
canStartAtom (TChar _) = True
canStartAtom (TBool _) = True
canStartAtom (TIdent _) = True
canStartAtom (TUpper _) = True
canStartAtom TUnderscore = True
canStartAtom TLParen = True
canStartAtom TLBracket = True
canStartAtom TLArray = True
canStartAtom TLBrace = True
canStartAtom TAt = True
canStartAtom (TInterpOpen _) = True
canStartAtom _ = False

-- applyNl dispatches on the bracket-frame stack.  Top-level (`frames == []`)
-- and inside a bracket whose head frame already has live contexts (`f > 0`)
-- behave like ordinary layout.  Inside a bracket in free-form (`f == 0`) a
-- newline is DROPPED unless a herald arms a block on a deeper line.
applyNl : Int -> Int -> List RawTok -> List Int -> List Int -> Option Token -> Bool -> List (Token, Int)
applyNl col off rest [] frames prev opener =
  (TNewline, off) :: layout rest [] frames None False
applyNl col off rest (top::tl) frames prev opener =
  applyNlFrame col off top (top::tl) rest frames prev opener

-- frames == [] (top level) is handled by the first applyNl clause; here frames
-- is non-empty OR the indent stack is non-empty.  Decide by frame state.
applyNlFrame : Int -> Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int)
applyNlFrame col off top stack rest [] prev opener =
  applyNlTop col off top stack rest [] prev opener
applyNlFrame col off top stack rest (f::fs) prev opener
  | f > 0 = applyNlTop col off top stack rest (f::fs) prev opener
  | col > top && not (prevIsTrailingOp prev) && armsHerald opener prev =
    (TIndent, off) :: layout rest (col::stack) (1::fs) None False
  | otherwise = layout rest stack (f::fs) prev opener

applyNlTop : Int -> Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int)
applyNlTop col off top stack rest frames prev opener
  | col > top = wouldIndent col off stack rest frames prev opener
  | col == top = (TNewline, off) :: layout rest stack frames None False
  | otherwise = (TNewline, off) :: popDedents col off stack rest frames

-- col > top: a block opener pushes INDENT; otherwise it's a candidate
-- continuation, decided by the deeper line's first token (Phase 137)
wouldIndent : Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int)
wouldIndent col off stack rest frames prev opener
  | prevIsTrailingOp prev = layout rest stack frames prev opener
  | opener || not (prevCanEnd prev) =
    (TIndent, off) :: layout rest (col::stack) (bumpFrame frames) None False
  | otherwise = resolveCont col off stack rest frames prev opener

-- Increment the innermost bracket frame's open-context count (no-op at top level).
bumpFrame : List Int -> List Int
bumpFrame [] = []
bumpFrame (f::fs) = f + 1 :: fs

-- Decrement the innermost bracket frame's open-context count (no-op at top level).
dropFrame : List Int -> List Int
dropFrame [] = []
dropFrame (f::fs) = f - 1 :: fs

-- conforms to LAYOUT-SEMANTICS.md §5.4 (Stage B deeper-line then/else path);
-- edits must keep both mechanisms in step (LAYOUT-CONFORMANCE-ROADMAP WS-2).
resolveCont : Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int)
resolveCont col off stack ((RTok t toff tend)::more) frames prev opener
  | canStartAtom t = layout (RTok t toff tend :: more) stack frames prev opener
  | t == TThen = layout (RTok t toff tend :: more) stack frames prev opener
  | t == TElse = layout (RTok t toff tend :: more) stack frames prev opener
  | otherwise = (TIndent, off) :: layout (RTok t toff tend :: more) (col::stack) (bumpFrame frames) None False
resolveCont col off stack rest frames prev opener =
  layout rest stack frames None False

-- Pop indent contexts down to `col`, decrementing the innermost bracket frame
-- for each context popped (so a herald block that dedents back below its column
-- returns the bracket frame to free-form).
popDedents : Int -> Int -> List Int -> List RawTok -> List Int -> List (Token, Int)
popDedents col off [] rest frames = layout rest [] frames None False
popDedents col off (top::tl) rest frames
  | top > col = (TDedent, off) :: (TNewline, off) :: popDedents col off tl rest (dropFrame frames)
  | otherwise = layout rest (top::tl) frames None False

-- end of input: NEWLINE, then DEDENT/NEWLINE pairs back to base, then EOF.
-- `off` is the EOF char offset (source length) so the synthetic tail tokens
-- get a source line past the last content line.
closeAll : List Int -> Int -> List (Token, Int)
closeAll stack off = (TNewline, off) :: closeDedents stack off

closeDedents : List Int -> Int -> List (Token, Int)
closeDedents [] off = [(TEof, off)]
closeDedents [_] off = [(TEof, off)]
closeDedents (_::tl) off =
  (TDedent, off) :: (TNewline, off) :: closeDedents tl off

-- conforms to LAYOUT-SEMANTICS.md §5.4; edits must keep both mechanisms in step
-- (LAYOUT-CONFORMANCE-ROADMAP WS-2). See also resolveCont above.
-- Phase 122 else-continuation filter: drop a NEWLINE immediately before ELSE
-- or THEN (a `then`/`else` leading the next line continues the enclosing `if`).
elseFilter : List (Token, Int) -> List (Token, Int)
elseFilter ((TNewline, _)::(TElse, eoff)::rest) =
  (TElse, eoff) :: elseFilter rest
elseFilter ((TNewline, _)::(TThen, eoff)::rest) =
  (TThen, eoff) :: elseFilter rest
elseFilter (t::rest) = t :: elseFilter rest
elseFilter [] = []

-- Drop the out-of-band `RComment` markers before the layout pass, so the Token
-- stream the parser consumes is byte-identical regardless of comment capture.
stripComments : List RawTok -> List RawTok
stripComments [] = []
stripComments ((RComment _ _)::rest) = stripComments rest
stripComments (r::rest) = r :: stripComments rest

-- The layout pass over the raw stream, carrying offsets.  Shared by `tokenize`
-- (which drops offsets) and `tokenizeWithOffsets` (the position side-channel).
layoutWithOffsets : Array Char -> Int -> List (Token, Int)
layoutWithOffsets src len = elseFilter (layout
  (stripComments (dedentTripleInterp (scan src len 0 0 0)))
  [0]
  []
  None
  False)

-- Layout variant that threads both START and END offsets per token, used by
-- `tokenizeWithOffsetPairs`.  Real tokens carry their RTok start+end; synthetic
-- layout tokens (NEWLINE/INDENT/DEDENT/EOF) carry their position for both
-- (empty span, matching OCaml's zero-width synthetic positions).
layoutPairs : List RawTok -> List Int -> List Int -> Option Token -> Bool -> List (Token, Int, Int)
layoutPairs [] stack frames prev opener = closeAllPairs stack 0
layoutPairs ((RTok t s e)::rest) stack frames prev opener
  | bracketOpener t = (t, s, e) :: layoutPairs rest stack (0::frames) (Some t) (opener || isOpener t)
  | bracketCloser t = flushClosePairs t s e rest stack frames opener
  | otherwise =
    (t, s, e) :: layoutPairs rest stack frames (Some t) (opener || isOpener t)
layoutPairs ((RComment _ _)::rest) stack frames prev opener =
  layoutPairs rest stack frames prev opener
layoutPairs ((RNewline col off)::rest) stack frames prev opener =
  applyNlPairs col off rest stack frames prev opener

flushClosePairs : Token -> Int -> Int -> List RawTok -> List Int -> List Int -> Bool -> List (Token, Int, Int)
flushClosePairs t s e rest stack [] opener =
  (t, s, e) :: layoutPairs rest stack [] (Some t) (opener || isOpener t)
flushClosePairs t s e rest stack (f::fs) opener =
  flushClosePairsGo t s e rest stack f fs opener

flushClosePairsGo : Token -> Int -> Int -> List RawTok -> List Int -> Int -> List Int -> Bool -> List (Token, Int, Int)
flushClosePairsGo t s e rest [] f fs opener =
  (t, s, e) :: layoutPairs rest [] fs (Some t) (opener || isOpener t)
flushClosePairsGo t s e rest (top::tl) f fs opener
  | f <= 0 =
    (t, s, e) :: layoutPairs rest (top::tl) fs (Some t) (opener || isOpener t)
  | otherwise = (TNewline, s, s) :: (TDedent, s, s) :: flushClosePairsGo t s e rest tl (f - 1) fs opener

applyNlPairs : Int -> Int -> List RawTok -> List Int -> List Int -> Option Token -> Bool -> List (Token, Int, Int)
applyNlPairs col off rest [] frames prev opener =
  (TNewline, off, off) :: layoutPairs rest [] frames None False
applyNlPairs col off rest (top::tl) frames prev opener =
  applyNlFramePairs col off top (top::tl) rest frames prev opener

applyNlFramePairs : Int -> Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int, Int)
applyNlFramePairs col off top stack rest [] prev opener =
  applyNlTopPairs col off top stack rest [] prev opener
applyNlFramePairs col off top stack rest (f::fs) prev opener
  | f > 0 = applyNlTopPairs col off top stack rest (f::fs) prev opener
  | col > top && not (prevIsTrailingOp prev) && armsHerald opener prev =
    (TIndent, off, off) :: layoutPairs rest (col::stack) (1::fs) None False
  | otherwise = layoutPairs rest stack (f::fs) prev opener

applyNlTopPairs : Int -> Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int, Int)
applyNlTopPairs col off top stack rest frames prev opener
  | col > top = wouldIndentPairs col off stack rest frames prev opener
  | col == top =
    (TNewline, off, off) :: layoutPairs rest stack frames None False
  | otherwise =
    (TNewline, off, off) :: popDedentsPairs col off stack rest frames

wouldIndentPairs : Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int, Int)
wouldIndentPairs col off stack rest frames prev opener
  | prevIsTrailingOp prev = layoutPairs rest stack frames prev opener
  | opener || not (prevCanEnd prev) = (TIndent, off, off) :: layoutPairs rest (col::stack) (bumpFrame frames) None False
  | otherwise = resolveContPairs col off stack rest frames prev opener

resolveContPairs : Int -> Int -> List Int -> List RawTok -> List Int -> Option Token -> Bool -> List (Token, Int, Int)
resolveContPairs col off stack ((RTok t toff tend)::more) frames prev opener
  | canStartAtom t =
    layoutPairs (RTok t toff tend :: more) stack frames prev opener
  | t == TThen = layoutPairs (RTok t toff tend :: more) stack frames prev opener
  | t == TElse = layoutPairs (RTok t toff tend :: more) stack frames prev opener
  | otherwise = (TIndent, off, off) :: layoutPairs (RTok t toff tend :: more) (col::stack) (bumpFrame frames) None False
resolveContPairs col off stack rest frames prev opener =
  layoutPairs rest stack frames None False

popDedentsPairs : Int -> Int -> List Int -> List RawTok -> List Int -> List (Token, Int, Int)
popDedentsPairs col off [] rest frames = layoutPairs rest [] frames None False
popDedentsPairs col off (top::tl) rest frames
  | top > col = (TDedent, off, off) :: (TNewline, off, off) :: popDedentsPairs col off tl rest (dropFrame frames)
  | otherwise = layoutPairs rest (top::tl) frames None False

closeAllPairs : List Int -> Int -> List (Token, Int, Int)
closeAllPairs stack off = (TNewline, off, off) :: closeDedentsPairs stack off

closeDedentsPairs : List Int -> Int -> List (Token, Int, Int)
closeDedentsPairs [] off = [(TEof, off, off)]
closeDedentsPairs [_] off = [(TEof, off, off)]
closeDedentsPairs (_::tl) off =
  (TDedent, off, off) :: (TNewline, off, off) :: closeDedentsPairs tl off

elseFilterPairs : List (Token, Int, Int) -> List (Token, Int, Int)
elseFilterPairs ((TNewline, _, _)::(TElse, es, ee)::rest) =
  (TElse, es, ee) :: elseFilterPairs rest
elseFilterPairs ((TNewline, _, _)::(TThen, es, ee)::rest) =
  (TThen, es, ee) :: elseFilterPairs rest
elseFilterPairs (t::rest) = t :: elseFilterPairs rest
elseFilterPairs [] = []

layoutWithOffsetPairs : Array Char -> Int -> List (Token, Int, Int)
layoutWithOffsetPairs src len = elseFilterPairs (layoutPairs
  (stripComments (dedentTripleInterp (scan src len 0 0 0)))
  [0]
  []
  None
  False)

export tokenize : String -> List Token
tokenize s =
  let src = stringToChars s
  let len = arrayLength src
  map fst (layoutWithOffsets src len)

-- Tokenize and return each token paired with the 1-based source line of its
-- char offset.  The position side-channel (`compiler/parser.mdk`) consults the
-- line array to record per-decl / per-variant source lines.  The Token stream
-- (`map fst`) is byte-identical to `tokenize`.
export tokenizeWithLines : String -> (List Token, List Int)
tokenizeWithLines s =
  let src = stringToChars s
  let len = arrayLength src
  let pairs = layoutWithOffsets src len
  let toks = map fst pairs
  let lines = offsetsToLines src (map snd pairs)
  (toks, lines)

-- Tokenize and return each token paired with the 0-based char OFFSET of its
-- first character.  Parallel to `tokenizeWithLines` but exposes the raw offset
-- (not the derived line) so a consumer can recover both line AND column for a
-- token index — the structured parse-error path (`parser.mdk`'s `parseResult`)
-- needs the column to mirror the OCaml oracle's `L:C` format.  The Token stream
-- (`map fst`) is byte-identical to `tokenize`.
export tokenizeWithOffsets : String -> (List Token, List Int)
tokenizeWithOffsets s =
  let src = stringToChars s
  let len = arrayLength src
  let pairs = layoutWithOffsets src len
  let toks = map fst pairs
  let offs = map snd pairs
  (toks, offs)

-- Tokenize and return each token paired with a (start, end) OFFSET pair where
-- `start` is the 0-based char offset of the token's first character and `end`
-- is one past its last character (= the next scan position).  Used by the LSP
-- path (`parseLocated`) to give `locOfSpan` a true end offset so ELoc ranges
-- match OCaml's `$endpos`-derived end_line/end_col exactly.  The Token stream
-- (`map fst`) is byte-identical to `tokenize`.
export tokenizeWithOffsetPairs : String -> (List Token, List (Int, Int))
tokenizeWithOffsetPairs s =
  let src = stringToChars s
  let len = arrayLength src
  let triples = layoutWithOffsetPairs src len
  let toks = map ((t, _s, _e) => t) triples
  let pairs = map ((t, s, e) => (s, e)) triples
  (toks, pairs)

-- Convert a 0-based char offset into `s` to a (1-based line, 0-based column)
-- pair, mirroring the OCaml `pos_lnum` / `pos_cnum - pos_bol` reported by the
-- parse-error oracle.  Reuses `posLineColFrom` (the comment side-channel's
-- offset→line/col walk).  Used by `parseResult` to locate a structured error.
export offsetToLineCol : String -> Int -> (Int, Int)
offsetToLineCol s off = posLineColFrom (stringToChars s) off 0 1 0

-- Precompute the sorted array of line-start char offsets for a source string:
-- offset 0, plus the offset just after every '\n'.  One O(N) scan.  Fed to
-- `offsetToLineColFast` so the located-parse pass can resolve each offset in
-- O(log N) instead of re-walking from 0 (which made `locOfSpan` O(N²)).
export lineStartsOf : String -> Array Int
lineStartsOf s =
  let src = stringToChars s
  let len = arrayLength src
  arrayFromList (0 :: lineStartsGo src len 0)

lineStartsGo : Array Char -> Int -> Int -> List Int
lineStartsGo src len i
  | i >= len = []
  | arrayGetUnsafe i src == '\n' = i + 1 :: lineStartsGo src len (i + 1)
  | otherwise = lineStartsGo src len (i + 1)

-- Resolve a 0-based char offset to a (1-based line, 0-based column) pair using a
-- precomputed line-starts array (`lineStartsOf`), by binary search.  This is
-- byte-identical to `offsetToLineCol` for every offset: line = 1 + (# newlines
-- strictly before `off`); col = off - (start of that line).  The '\n' AT `off`
-- is NOT counted (mirrors `posLineColFrom`'s `p >= target` guard checked first).
export offsetToLineColFast : Array Int -> Int -> (Int, Int)
offsetToLineColFast lineStarts off =
  let idx = lineStartSearch lineStarts off 0 (arrayLength lineStarts - 1)
  (idx + 1, off - arrayGetUnsafe idx lineStarts)

-- Rightmost index `idx` in [lo, hi] with `lineStarts[idx] <= off`.
-- `lineStarts[0]` is 0 and `off >= 0`, so such an index always exists in range.
lineStartSearch : Array Int -> Int -> Int -> Int -> Int
lineStartSearch arr off lo hi
  | lo >= hi = lo
  | otherwise =
    let mid = (lo + hi + 1) / 2
    if arrayGetUnsafe mid arr <= off then
      lineStartSearch arr off mid hi
    else
      lineStartSearch arr off lo (mid - 1)

-- Convert a list of char offsets (in non-decreasing-ish source order — the
-- synthetic tail tokens all share the EOF offset, which is monotone) to 1-based
-- source lines in a single left-to-right walk over the source, mirroring
-- `posToLineCol`'s amortized-linear strategy for comments.
offsetsToLines : Array Char -> List Int -> List Int
offsetsToLines src offs = offsetsToLinesGo src offs 0 1

offsetsToLinesGo : Array Char -> List Int -> Int -> Int -> List Int
offsetsToLinesGo src [] p line = []
offsetsToLinesGo src (off::rest) p line = match advanceLine src off p line
  (line2, p2) => line2 :: offsetsToLinesGo src rest p2 line2

-- Walk forward from char `p` (1-based `line`) to `target`, counting newlines.
-- Offsets arrive in non-decreasing order so each call resumes from the last.
advanceLine : Array Char -> Int -> Int -> Int -> (Int, Int)
advanceLine src target p line
  | p >= target = (line, p)
  | p >= arrayLength src = (line, p)
  | arrayGetUnsafe p src == '\n' = advanceLine src target (p + 1) (line + 1)
  | otherwise = advanceLine src target (p + 1) line

-- ── Comment side channel ─────────────────────────────────────────────────
-- Mirrors lib/lexer.mll's `comment` record + `take_comments`: each captured
-- comment carries its 1-based start line, 0-based start column, and full
-- lexeme text (the `--…` / `{- … -}`, delimiters included).  Surfaced in
-- SOURCE ORDER, exactly as the OCaml `take_comments ()` (which reverses the
-- accumulator).  `format_program`/the comment-preserving printer consume this
-- list keyed by position; the parser is unaffected (comments are stripped
-- before layout — see `stripComments`).
export data Comment = Comment Int Int String

export commentLine : Comment -> Int
commentLine (Comment l _ _) = l

export commentCol : Comment -> Int
commentCol (Comment _ c _) = c

export commentText : Comment -> String
commentText (Comment _ _ t) = t

-- Convert a source char offset to (1-based line, 0-based column) by scanning
-- the preceding characters.  `lineStart` is the offset of the current line's
-- first char; `line` its 1-based number.  O(pos) per call, but only invoked
-- once per comment in a single left-to-right walk (see `posToLineCol`).
posLineColFrom : Array Char -> Int -> Int -> Int -> Int -> (Int, Int)
posLineColFrom src target p line lineStart
  | p >= target = (line, target - lineStart)
  | at src p == '\n' = posLineColFrom src target (p + 1) (line + 1) (p + 1)
  | otherwise = posLineColFrom src target (p + 1) line lineStart

-- Turn each `RComment startPos text` into a `Comment line col text`.
-- `RComment` tokens arrive in strictly-ascending `startPos` order (scan is a
-- single left-to-right pass), so a running `(p, line, lineStart)` cursor lets
-- `posLineColFrom` resume from the previous comment instead of rescanning from
-- offset 0 every time — turning what was O(comments × filesize) (a fresh scan
-- per comment; the dominant cost of `medaka fmt` on a comment-dense file) into
-- one O(filesize) walk.  `lineStart` for the next hop is `startPos - col`, since
-- `posLineColFrom` returns `col = startPos - lineStart`.
rawToComments : Array Char -> List RawTok -> List Comment
rawToComments src toks = rawToCommentsGo src toks 0 1 0

rawToCommentsGo : Array Char -> List RawTok -> Int -> Int -> Int -> List Comment
rawToCommentsGo _ [] _ _ _ = []
rawToCommentsGo src ((RComment startPos text)::rest) p line lineStart = match posLineColFrom src startPos p line lineStart
  (line2, col) => Comment line2 col text :: rawToCommentsGo src rest startPos line2 (startPos - col)
rawToCommentsGo src (_::rest) p line lineStart =
  rawToCommentsGo src rest p line lineStart

-- Tokenize-and-collect the comment side channel, in source order.
export collectComments : String -> List Comment
collectComments s =
  let src = stringToChars s
  let len = arrayLength src
  rawToComments src (scan src len 0 0 0)
# DESUGAR
(DUse false (UseGroup ("support" "char") ((mem "isSp" false) (mem "isTab" false) (mem "isNL" false) (mem "isCR" false) (mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isBacktick" false) (mem "isSpace" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isAlnum" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "compareDecMag" false) (mem "listLen" false) (mem "anyList" false))))
(DData Public "Token" () ((variant "TInt" (ConPos (TyCon "Int") (TyCon "String"))) (variant "TFloat" (ConPos (TyCon "Float"))) (variant "TString" (ConPos (TyCon "String"))) (variant "TChar" (ConPos (TyCon "String"))) (variant "TBool" (ConPos (TyCon "Bool"))) (variant "TInterpOpen" (ConPos (TyCon "String"))) (variant "TInterpMid" (ConPos (TyCon "String"))) (variant "TInterpEnd" (ConPos (TyCon "String"))) (variant "TIdent" (ConPos (TyCon "String"))) (variant "TUpper" (ConPos (TyCon "String"))) (variant "TBacktickIdent" (ConPos (TyCon "String"))) (variant "TLet" (ConPos)) (variant "TRec" (ConPos)) (variant "TWith" (ConPos)) (variant "TMut" (ConPos)) (variant "TIn" (ConPos)) (variant "TIf" (ConPos)) (variant "TThen" (ConPos)) (variant "TElse" (ConPos)) (variant "TMatch" (ConPos)) (variant "TData" (ConPos)) (variant "TRecord" (ConPos)) (variant "TInterface" (ConPos)) (variant "TDefault" (ConPos)) (variant "TImpl" (ConPos)) (variant "TImport" (ConPos)) (variant "TExport" (ConPos)) (variant "TPublic" (ConPos)) (variant "TWhere" (ConPos)) (variant "TOf" (ConPos)) (variant "TRequires" (ConPos)) (variant "TDo" (ConPos)) (variant "TAs" (ConPos)) (variant "TExtern" (ConPos)) (variant "TDeriving" (ConPos)) (variant "TType" (ConPos)) (variant "TNewtype" (ConPos)) (variant "TProp" (ConPos)) (variant "TTest" (ConPos)) (variant "TBench" (ConPos)) (variant "TEffect" (ConPos)) (variant "TFunction" (ConPos)) (variant "TPlus" (ConPos)) (variant "TMinus" (ConPos)) (variant "TMinusTight" (ConPos)) (variant "TStar" (ConPos)) (variant "TSlash" (ConPos)) (variant "TSlashEq" (ConPos)) (variant "TMod" (ConPos)) (variant "TEqEq" (ConPos)) (variant "TNeq" (ConPos)) (variant "TLt" (ConPos)) (variant "TGt" (ConPos)) (variant "TLeq" (ConPos)) (variant "TGeq" (ConPos)) (variant "TAnd" (ConPos)) (variant "TOr" (ConPos)) (variant "TCons" (ConPos)) (variant "TPlusPlus" (ConPos)) (variant "TPipeRight" (ConPos)) (variant "TRCompose" (ConPos)) (variant "TLCompose" (ConPos)) (variant "TFatArrow" (ConPos)) (variant "TArrow" (ConPos)) (variant "TLArrow" (ConPos)) (variant "TAt" (ConPos)) (variant "TBang" (ConPos)) (variant "TAsAt" (ConPos)) (variant "TEqual" (ConPos)) (variant "TColon" (ConPos)) (variant "TColonEq" (ConPos)) (variant "TComma" (ConPos)) (variant "TDot" (ConPos)) (variant "TPipe" (ConPos)) (variant "TUnderscore" (ConPos)) (variant "TLParen" (ConPos)) (variant "TRParen" (ConPos)) (variant "TLBracket" (ConPos)) (variant "TLBracketTight" (ConPos)) (variant "TRBracket" (ConPos)) (variant "TLBrace" (ConPos)) (variant "TRBrace" (ConPos)) (variant "TLArray" (ConPos)) (variant "TRArray" (ConPos)) (variant "TDotLBrace" (ConPos)) (variant "TDotStar" (ConPos)) (variant "TEllipsis" (ConPos)) (variant "TDotDot" (ConPos)) (variant "TDotDotEq" (ConPos)) (variant "TNewline" (ConPos)) (variant "TIndent" (ConPos)) (variant "TDedent" (ConPos)) (variant "TEof" (ConPos)) (variant "TLexError" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Token")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TInt" (PVar "__a0") (PVar "__a1")) (PCon "TInt" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "TFloat" (PVar "__a0")) (PCon "TFloat" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TString" (PVar "__a0")) (PCon "TString" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TChar" (PVar "__a0")) (PCon "TChar" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBool" (PVar "__a0")) (PCon "TBool" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpOpen" (PVar "__a0")) (PCon "TInterpOpen" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpMid" (PVar "__a0")) (PCon "TInterpMid" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpEnd" (PVar "__a0")) (PCon "TInterpEnd" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TIdent" (PVar "__a0")) (PCon "TIdent" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TUpper" (PVar "__a0")) (PCon "TUpper" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBacktickIdent" (PVar "__a0")) (PCon "TBacktickIdent" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TLet") (PCon "TLet")) () (EVar "True")) (arm (PTuple (PCon "TRec") (PCon "TRec")) () (EVar "True")) (arm (PTuple (PCon "TWith") (PCon "TWith")) () (EVar "True")) (arm (PTuple (PCon "TMut") (PCon "TMut")) () (EVar "True")) (arm (PTuple (PCon "TIn") (PCon "TIn")) () (EVar "True")) (arm (PTuple (PCon "TIf") (PCon "TIf")) () (EVar "True")) (arm (PTuple (PCon "TThen") (PCon "TThen")) () (EVar "True")) (arm (PTuple (PCon "TElse") (PCon "TElse")) () (EVar "True")) (arm (PTuple (PCon "TMatch") (PCon "TMatch")) () (EVar "True")) (arm (PTuple (PCon "TData") (PCon "TData")) () (EVar "True")) (arm (PTuple (PCon "TRecord") (PCon "TRecord")) () (EVar "True")) (arm (PTuple (PCon "TInterface") (PCon "TInterface")) () (EVar "True")) (arm (PTuple (PCon "TDefault") (PCon "TDefault")) () (EVar "True")) (arm (PTuple (PCon "TImpl") (PCon "TImpl")) () (EVar "True")) (arm (PTuple (PCon "TImport") (PCon "TImport")) () (EVar "True")) (arm (PTuple (PCon "TExport") (PCon "TExport")) () (EVar "True")) (arm (PTuple (PCon "TPublic") (PCon "TPublic")) () (EVar "True")) (arm (PTuple (PCon "TWhere") (PCon "TWhere")) () (EVar "True")) (arm (PTuple (PCon "TOf") (PCon "TOf")) () (EVar "True")) (arm (PTuple (PCon "TRequires") (PCon "TRequires")) () (EVar "True")) (arm (PTuple (PCon "TDo") (PCon "TDo")) () (EVar "True")) (arm (PTuple (PCon "TAs") (PCon "TAs")) () (EVar "True")) (arm (PTuple (PCon "TExtern") (PCon "TExtern")) () (EVar "True")) (arm (PTuple (PCon "TDeriving") (PCon "TDeriving")) () (EVar "True")) (arm (PTuple (PCon "TType") (PCon "TType")) () (EVar "True")) (arm (PTuple (PCon "TNewtype") (PCon "TNewtype")) () (EVar "True")) (arm (PTuple (PCon "TProp") (PCon "TProp")) () (EVar "True")) (arm (PTuple (PCon "TTest") (PCon "TTest")) () (EVar "True")) (arm (PTuple (PCon "TBench") (PCon "TBench")) () (EVar "True")) (arm (PTuple (PCon "TEffect") (PCon "TEffect")) () (EVar "True")) (arm (PTuple (PCon "TFunction") (PCon "TFunction")) () (EVar "True")) (arm (PTuple (PCon "TPlus") (PCon "TPlus")) () (EVar "True")) (arm (PTuple (PCon "TMinus") (PCon "TMinus")) () (EVar "True")) (arm (PTuple (PCon "TMinusTight") (PCon "TMinusTight")) () (EVar "True")) (arm (PTuple (PCon "TStar") (PCon "TStar")) () (EVar "True")) (arm (PTuple (PCon "TSlash") (PCon "TSlash")) () (EVar "True")) (arm (PTuple (PCon "TSlashEq") (PCon "TSlashEq")) () (EVar "True")) (arm (PTuple (PCon "TMod") (PCon "TMod")) () (EVar "True")) (arm (PTuple (PCon "TEqEq") (PCon "TEqEq")) () (EVar "True")) (arm (PTuple (PCon "TNeq") (PCon "TNeq")) () (EVar "True")) (arm (PTuple (PCon "TLt") (PCon "TLt")) () (EVar "True")) (arm (PTuple (PCon "TGt") (PCon "TGt")) () (EVar "True")) (arm (PTuple (PCon "TLeq") (PCon "TLeq")) () (EVar "True")) (arm (PTuple (PCon "TGeq") (PCon "TGeq")) () (EVar "True")) (arm (PTuple (PCon "TAnd") (PCon "TAnd")) () (EVar "True")) (arm (PTuple (PCon "TOr") (PCon "TOr")) () (EVar "True")) (arm (PTuple (PCon "TCons") (PCon "TCons")) () (EVar "True")) (arm (PTuple (PCon "TPlusPlus") (PCon "TPlusPlus")) () (EVar "True")) (arm (PTuple (PCon "TPipeRight") (PCon "TPipeRight")) () (EVar "True")) (arm (PTuple (PCon "TRCompose") (PCon "TRCompose")) () (EVar "True")) (arm (PTuple (PCon "TLCompose") (PCon "TLCompose")) () (EVar "True")) (arm (PTuple (PCon "TFatArrow") (PCon "TFatArrow")) () (EVar "True")) (arm (PTuple (PCon "TArrow") (PCon "TArrow")) () (EVar "True")) (arm (PTuple (PCon "TLArrow") (PCon "TLArrow")) () (EVar "True")) (arm (PTuple (PCon "TAt") (PCon "TAt")) () (EVar "True")) (arm (PTuple (PCon "TBang") (PCon "TBang")) () (EVar "True")) (arm (PTuple (PCon "TAsAt") (PCon "TAsAt")) () (EVar "True")) (arm (PTuple (PCon "TEqual") (PCon "TEqual")) () (EVar "True")) (arm (PTuple (PCon "TColon") (PCon "TColon")) () (EVar "True")) (arm (PTuple (PCon "TColonEq") (PCon "TColonEq")) () (EVar "True")) (arm (PTuple (PCon "TComma") (PCon "TComma")) () (EVar "True")) (arm (PTuple (PCon "TDot") (PCon "TDot")) () (EVar "True")) (arm (PTuple (PCon "TPipe") (PCon "TPipe")) () (EVar "True")) (arm (PTuple (PCon "TUnderscore") (PCon "TUnderscore")) () (EVar "True")) (arm (PTuple (PCon "TLParen") (PCon "TLParen")) () (EVar "True")) (arm (PTuple (PCon "TRParen") (PCon "TRParen")) () (EVar "True")) (arm (PTuple (PCon "TLBracket") (PCon "TLBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBracketTight") (PCon "TLBracketTight")) () (EVar "True")) (arm (PTuple (PCon "TRBracket") (PCon "TRBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBrace") (PCon "TLBrace")) () (EVar "True")) (arm (PTuple (PCon "TRBrace") (PCon "TRBrace")) () (EVar "True")) (arm (PTuple (PCon "TLArray") (PCon "TLArray")) () (EVar "True")) (arm (PTuple (PCon "TRArray") (PCon "TRArray")) () (EVar "True")) (arm (PTuple (PCon "TDotLBrace") (PCon "TDotLBrace")) () (EVar "True")) (arm (PTuple (PCon "TDotStar") (PCon "TDotStar")) () (EVar "True")) (arm (PTuple (PCon "TEllipsis") (PCon "TEllipsis")) () (EVar "True")) (arm (PTuple (PCon "TDotDot") (PCon "TDotDot")) () (EVar "True")) (arm (PTuple (PCon "TDotDotEq") (PCon "TDotDotEq")) () (EVar "True")) (arm (PTuple (PCon "TNewline") (PCon "TNewline")) () (EVar "True")) (arm (PTuple (PCon "TIndent") (PCon "TIndent")) () (EVar "True")) (arm (PTuple (PCon "TDedent") (PCon "TDedent")) () (EVar "True")) (arm (PTuple (PCon "TEof") (PCon "TEof")) () (EVar "True")) (arm (PTuple (PCon "TLexError" (PVar "__a0")) (PCon "TLexError" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig true "tokenToString" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "tokenToString" ((PCon "TInt" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "INT ")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "tokenToString" ((PCon "TFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "FLOAT ")) (EApp (EVar "floatToString") (EVar "f"))))
(DFunDef false "tokenToString" ((PCon "TString" (PVar "s"))) (EBinOp "++" (ELit (LString "STRING ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TChar" (PVar "s"))) (EBinOp "++" (ELit (LString "CHAR ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "True"))) (ELit (LString "BOOL true")))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "False"))) (ELit (LString "BOOL false")))
(DFunDef false "tokenToString" ((PCon "TInterpOpen" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_OPEN ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpMid" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_MID ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpEnd" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_END ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (ELit (LString "UPPER ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "BACKTICK_IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TLet")) (ELit (LString "LET")))
(DFunDef false "tokenToString" ((PCon "TRec")) (ELit (LString "REC")))
(DFunDef false "tokenToString" ((PCon "TWith")) (ELit (LString "WITH")))
(DFunDef false "tokenToString" ((PCon "TMut")) (ELit (LString "MUT")))
(DFunDef false "tokenToString" ((PCon "TIn")) (ELit (LString "IN")))
(DFunDef false "tokenToString" ((PCon "TIf")) (ELit (LString "IF")))
(DFunDef false "tokenToString" ((PCon "TThen")) (ELit (LString "THEN")))
(DFunDef false "tokenToString" ((PCon "TElse")) (ELit (LString "ELSE")))
(DFunDef false "tokenToString" ((PCon "TMatch")) (ELit (LString "MATCH")))
(DFunDef false "tokenToString" ((PCon "TData")) (ELit (LString "DATA")))
(DFunDef false "tokenToString" ((PCon "TRecord")) (ELit (LString "RECORD")))
(DFunDef false "tokenToString" ((PCon "TInterface")) (ELit (LString "INTERFACE")))
(DFunDef false "tokenToString" ((PCon "TDefault")) (ELit (LString "DEFAULT")))
(DFunDef false "tokenToString" ((PCon "TImpl")) (ELit (LString "IMPL")))
(DFunDef false "tokenToString" ((PCon "TImport")) (ELit (LString "IMPORT")))
(DFunDef false "tokenToString" ((PCon "TExport")) (ELit (LString "EXPORT")))
(DFunDef false "tokenToString" ((PCon "TPublic")) (ELit (LString "PUBLIC")))
(DFunDef false "tokenToString" ((PCon "TWhere")) (ELit (LString "WHERE")))
(DFunDef false "tokenToString" ((PCon "TOf")) (ELit (LString "OF")))
(DFunDef false "tokenToString" ((PCon "TRequires")) (ELit (LString "REQUIRES")))
(DFunDef false "tokenToString" ((PCon "TDo")) (ELit (LString "DO")))
(DFunDef false "tokenToString" ((PCon "TAs")) (ELit (LString "AS")))
(DFunDef false "tokenToString" ((PCon "TExtern")) (ELit (LString "EXTERN")))
(DFunDef false "tokenToString" ((PCon "TDeriving")) (ELit (LString "DERIVING")))
(DFunDef false "tokenToString" ((PCon "TType")) (ELit (LString "TYPE")))
(DFunDef false "tokenToString" ((PCon "TNewtype")) (ELit (LString "NEWTYPE")))
(DFunDef false "tokenToString" ((PCon "TProp")) (ELit (LString "PROP")))
(DFunDef false "tokenToString" ((PCon "TTest")) (ELit (LString "TEST")))
(DFunDef false "tokenToString" ((PCon "TBench")) (ELit (LString "BENCH")))
(DFunDef false "tokenToString" ((PCon "TEffect")) (ELit (LString "EFFECT")))
(DFunDef false "tokenToString" ((PCon "TFunction")) (ELit (LString "FUNCTION")))
(DFunDef false "tokenToString" ((PCon "TPlus")) (ELit (LString "PLUS")))
(DFunDef false "tokenToString" ((PCon "TMinus")) (ELit (LString "MINUS")))
(DFunDef false "tokenToString" ((PCon "TMinusTight")) (ELit (LString "MINUS_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TStar")) (ELit (LString "STAR")))
(DFunDef false "tokenToString" ((PCon "TSlash")) (ELit (LString "SLASH")))
(DFunDef false "tokenToString" ((PCon "TSlashEq")) (ELit (LString "SLASHEQ")))
(DFunDef false "tokenToString" ((PCon "TMod")) (ELit (LString "MOD")))
(DFunDef false "tokenToString" ((PCon "TEqEq")) (ELit (LString "EQ_EQ")))
(DFunDef false "tokenToString" ((PCon "TNeq")) (ELit (LString "NEQ")))
(DFunDef false "tokenToString" ((PCon "TLt")) (ELit (LString "LT")))
(DFunDef false "tokenToString" ((PCon "TGt")) (ELit (LString "GT")))
(DFunDef false "tokenToString" ((PCon "TLeq")) (ELit (LString "LEQ")))
(DFunDef false "tokenToString" ((PCon "TGeq")) (ELit (LString "GEQ")))
(DFunDef false "tokenToString" ((PCon "TAnd")) (ELit (LString "AND")))
(DFunDef false "tokenToString" ((PCon "TOr")) (ELit (LString "OR")))
(DFunDef false "tokenToString" ((PCon "TCons")) (ELit (LString "CONS")))
(DFunDef false "tokenToString" ((PCon "TPlusPlus")) (ELit (LString "PLUSPLUS")))
(DFunDef false "tokenToString" ((PCon "TPipeRight")) (ELit (LString "PIPE_RIGHT")))
(DFunDef false "tokenToString" ((PCon "TRCompose")) (ELit (LString "RCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TLCompose")) (ELit (LString "LCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TFatArrow")) (ELit (LString "FAT_ARROW")))
(DFunDef false "tokenToString" ((PCon "TArrow")) (ELit (LString "ARROW")))
(DFunDef false "tokenToString" ((PCon "TLArrow")) (ELit (LString "LARROW")))
(DFunDef false "tokenToString" ((PCon "TAt")) (ELit (LString "AT")))
(DFunDef false "tokenToString" ((PCon "TBang")) (ELit (LString "BANG")))
(DFunDef false "tokenToString" ((PCon "TAsAt")) (ELit (LString "AS_AT")))
(DFunDef false "tokenToString" ((PCon "TEqual")) (ELit (LString "EQUAL")))
(DFunDef false "tokenToString" ((PCon "TColon")) (ELit (LString "COLON")))
(DFunDef false "tokenToString" ((PCon "TColonEq")) (ELit (LString "COLONEQ")))
(DFunDef false "tokenToString" ((PCon "TComma")) (ELit (LString "COMMA")))
(DFunDef false "tokenToString" ((PCon "TDot")) (ELit (LString "DOT")))
(DFunDef false "tokenToString" ((PCon "TPipe")) (ELit (LString "PIPE")))
(DFunDef false "tokenToString" ((PCon "TUnderscore")) (ELit (LString "UNDERSCORE")))
(DFunDef false "tokenToString" ((PCon "TLParen")) (ELit (LString "LPAREN")))
(DFunDef false "tokenToString" ((PCon "TRParen")) (ELit (LString "RPAREN")))
(DFunDef false "tokenToString" ((PCon "TLBracket")) (ELit (LString "LBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBracketTight")) (ELit (LString "LBRACKET_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TRBracket")) (ELit (LString "RBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBrace")) (ELit (LString "LBRACE")))
(DFunDef false "tokenToString" ((PCon "TRBrace")) (ELit (LString "RBRACE")))
(DFunDef false "tokenToString" ((PCon "TLArray")) (ELit (LString "LARRAY")))
(DFunDef false "tokenToString" ((PCon "TRArray")) (ELit (LString "RARRAY")))
(DFunDef false "tokenToString" ((PCon "TDotLBrace")) (ELit (LString "DOT_LBRACE")))
(DFunDef false "tokenToString" ((PCon "TDotStar")) (ELit (LString "DOT_STAR")))
(DFunDef false "tokenToString" ((PCon "TEllipsis")) (ELit (LString "ELLIPSIS")))
(DFunDef false "tokenToString" ((PCon "TDotDot")) (ELit (LString "DOTDOT")))
(DFunDef false "tokenToString" ((PCon "TDotDotEq")) (ELit (LString "DOTDOT_EQ")))
(DFunDef false "tokenToString" ((PCon "TNewline")) (ELit (LString "NEWLINE")))
(DFunDef false "tokenToString" ((PCon "TIndent")) (ELit (LString "INDENT")))
(DFunDef false "tokenToString" ((PCon "TDedent")) (ELit (LString "DEDENT")))
(DFunDef false "tokenToString" ((PCon "TEof")) (ELit (LString "EOF")))
(DFunDef false "tokenToString" ((PCon "TLexError" (PVar "s"))) (EBinOp "++" (ELit (LString "LEX_ERROR ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DTypeSig true "describeToken" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "describeToken" ((PCon "TInt" PWild PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TFloat" PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TString" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TChar" PWild)) (ELit (LString "a character literal")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "True"))) (ELit (LString "`true`")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "False"))) (ELit (LString "`false`")))
(DFunDef false "describeToken" ((PCon "TInterpOpen" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpMid" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpEnd" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TLet")) (ELit (LString "`let`")))
(DFunDef false "describeToken" ((PCon "TRec")) (ELit (LString "`rec`")))
(DFunDef false "describeToken" ((PCon "TWith")) (ELit (LString "`with`")))
(DFunDef false "describeToken" ((PCon "TMut")) (ELit (LString "`mut`")))
(DFunDef false "describeToken" ((PCon "TIn")) (ELit (LString "`in`")))
(DFunDef false "describeToken" ((PCon "TIf")) (ELit (LString "`if`")))
(DFunDef false "describeToken" ((PCon "TThen")) (ELit (LString "`then`")))
(DFunDef false "describeToken" ((PCon "TElse")) (ELit (LString "`else`")))
(DFunDef false "describeToken" ((PCon "TMatch")) (ELit (LString "`match`")))
(DFunDef false "describeToken" ((PCon "TData")) (ELit (LString "`data`")))
(DFunDef false "describeToken" ((PCon "TRecord")) (ELit (LString "`record`")))
(DFunDef false "describeToken" ((PCon "TInterface")) (ELit (LString "`interface`")))
(DFunDef false "describeToken" ((PCon "TDefault")) (ELit (LString "`default`")))
(DFunDef false "describeToken" ((PCon "TImpl")) (ELit (LString "`impl`")))
(DFunDef false "describeToken" ((PCon "TImport")) (ELit (LString "`import`")))
(DFunDef false "describeToken" ((PCon "TExport")) (ELit (LString "`export`")))
(DFunDef false "describeToken" ((PCon "TPublic")) (ELit (LString "`public`")))
(DFunDef false "describeToken" ((PCon "TWhere")) (ELit (LString "`where`")))
(DFunDef false "describeToken" ((PCon "TOf")) (ELit (LString "`of`")))
(DFunDef false "describeToken" ((PCon "TRequires")) (ELit (LString "`requires`")))
(DFunDef false "describeToken" ((PCon "TDo")) (ELit (LString "`do`")))
(DFunDef false "describeToken" ((PCon "TAs")) (ELit (LString "`as`")))
(DFunDef false "describeToken" ((PCon "TExtern")) (ELit (LString "`extern`")))
(DFunDef false "describeToken" ((PCon "TDeriving")) (ELit (LString "`deriving`")))
(DFunDef false "describeToken" ((PCon "TType")) (ELit (LString "`type`")))
(DFunDef false "describeToken" ((PCon "TNewtype")) (ELit (LString "`newtype`")))
(DFunDef false "describeToken" ((PCon "TProp")) (ELit (LString "`prop`")))
(DFunDef false "describeToken" ((PCon "TTest")) (ELit (LString "`test`")))
(DFunDef false "describeToken" ((PCon "TBench")) (ELit (LString "`bench`")))
(DFunDef false "describeToken" ((PCon "TEffect")) (ELit (LString "`effect`")))
(DFunDef false "describeToken" ((PCon "TFunction")) (ELit (LString "`function`")))
(DFunDef false "describeToken" ((PCon "TPlus")) (ELit (LString "`+`")))
(DFunDef false "describeToken" ((PCon "TMinus")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TMinusTight")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TStar")) (ELit (LString "`*`")))
(DFunDef false "describeToken" ((PCon "TSlash")) (ELit (LString "`/`")))
(DFunDef false "describeToken" ((PCon "TSlashEq")) (ELit (LString "`/=`")))
(DFunDef false "describeToken" ((PCon "TMod")) (ELit (LString "`%`")))
(DFunDef false "describeToken" ((PCon "TEqEq")) (ELit (LString "`==`")))
(DFunDef false "describeToken" ((PCon "TNeq")) (ELit (LString "`!=`")))
(DFunDef false "describeToken" ((PCon "TLt")) (ELit (LString "`<`")))
(DFunDef false "describeToken" ((PCon "TGt")) (ELit (LString "`>`")))
(DFunDef false "describeToken" ((PCon "TLeq")) (ELit (LString "`<=`")))
(DFunDef false "describeToken" ((PCon "TGeq")) (ELit (LString "`>=`")))
(DFunDef false "describeToken" ((PCon "TAnd")) (ELit (LString "`&&`")))
(DFunDef false "describeToken" ((PCon "TOr")) (ELit (LString "`||`")))
(DFunDef false "describeToken" ((PCon "TCons")) (ELit (LString "`::`")))
(DFunDef false "describeToken" ((PCon "TPlusPlus")) (ELit (LString "`++`")))
(DFunDef false "describeToken" ((PCon "TPipeRight")) (ELit (LString "`|>`")))
(DFunDef false "describeToken" ((PCon "TRCompose")) (ELit (LString "`>>`")))
(DFunDef false "describeToken" ((PCon "TLCompose")) (ELit (LString "`<<`")))
(DFunDef false "describeToken" ((PCon "TFatArrow")) (ELit (LString "`=>`")))
(DFunDef false "describeToken" ((PCon "TArrow")) (ELit (LString "`->`")))
(DFunDef false "describeToken" ((PCon "TLArrow")) (ELit (LString "`<-`")))
(DFunDef false "describeToken" ((PCon "TAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TBang")) (ELit (LString "`!`")))
(DFunDef false "describeToken" ((PCon "TAsAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TEqual")) (ELit (LString "`=`")))
(DFunDef false "describeToken" ((PCon "TColon")) (ELit (LString "`:`")))
(DFunDef false "describeToken" ((PCon "TColonEq")) (ELit (LString "`:=`")))
(DFunDef false "describeToken" ((PCon "TComma")) (ELit (LString "`,`")))
(DFunDef false "describeToken" ((PCon "TDot")) (ELit (LString "`.`")))
(DFunDef false "describeToken" ((PCon "TPipe")) (ELit (LString "`|`")))
(DFunDef false "describeToken" ((PCon "TUnderscore")) (ELit (LString "`_`")))
(DFunDef false "describeToken" ((PCon "TLParen")) (ELit (LString "`(`")))
(DFunDef false "describeToken" ((PCon "TRParen")) (ELit (LString "`)`")))
(DFunDef false "describeToken" ((PCon "TLBracket")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TLBracketTight")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TRBracket")) (ELit (LString "`]`")))
(DFunDef false "describeToken" ((PCon "TLBrace")) (ELit (LString "`{`")))
(DFunDef false "describeToken" ((PCon "TRBrace")) (ELit (LString "`}`")))
(DFunDef false "describeToken" ((PCon "TLArray")) (ELit (LString "`[|`")))
(DFunDef false "describeToken" ((PCon "TRArray")) (ELit (LString "`|]`")))
(DFunDef false "describeToken" ((PCon "TDotLBrace")) (ELit (LString "`.{`")))
(DFunDef false "describeToken" ((PCon "TDotStar")) (ELit (LString "`.*`")))
(DFunDef false "describeToken" ((PCon "TEllipsis")) (ELit (LString "`...`")))
(DFunDef false "describeToken" ((PCon "TDotDot")) (ELit (LString "`..`")))
(DFunDef false "describeToken" ((PCon "TDotDotEq")) (ELit (LString "`..=`")))
(DFunDef false "describeToken" ((PCon "TNewline")) (ELit (LString "a line break")))
(DFunDef false "describeToken" ((PCon "TIndent")) (ELit (LString "an indent")))
(DFunDef false "describeToken" ((PCon "TDedent")) (ELit (LString "a dedent")))
(DFunDef false "describeToken" ((PCon "TEof")) (ELit (LString "end of input")))
(DFunDef false "describeToken" ((PCon "TLexError" (PVar "s"))) (EVar "s"))
(DData Private "RawTok" () ((variant "RTok" (ConPos (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (variant "RNewline" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RComment" (ConPos (TyCon "Int") (TyCon "String")))) ())
(DTypeSig false "at" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "at" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "is2" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool")))))))
(DFunDef false "is2" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))))
(DTypeSig false "is3" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))))))
(DFunDef false "is3" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "c"))))
(DTypeSig false "substr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substr" ((PVar "src") (PVar "start") (PVar "endp")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "endp") (EVar "start"))) (ELam ((PVar "i")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "start") (EVar "i")))))))
(DTypeSig false "collectNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "collectNoUs" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "substrNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substrNoUs" ((PVar "src") (PVar "start") (PVar "endp")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "start")) (EVar "endp")))))
(DTypeSig false "parseIntFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseIntFrom" ((PVar "src") (PVar "p") (PVar "endp") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (ELit (LInt 48))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "intLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "intLitOverflows" ((PVar "src") (PVar "start") (PVar "endp")) (EBinOp "==" (EApp (EApp (EVar "compareDecMag") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "start")) (EVar "endp"))) (ELit (LString "4611686018427387904"))) (EVar "Gt")))
(DTypeSig false "keywordOrIdent" (TyFun (TyCon "String") (TyCon "Token")))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PLit (LString "with"))) (EVar "TWith"))
(DFunDef false "keywordOrIdent" ((PLit (LString "mut"))) (EVar "TMut"))
(DFunDef false "keywordOrIdent" ((PLit (LString "in"))) (EVar "TIn"))
(DFunDef false "keywordOrIdent" ((PLit (LString "if"))) (EVar "TIf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "then"))) (EVar "TThen"))
(DFunDef false "keywordOrIdent" ((PLit (LString "else"))) (EVar "TElse"))
(DFunDef false "keywordOrIdent" ((PLit (LString "match"))) (EVar "TMatch"))
(DFunDef false "keywordOrIdent" ((PLit (LString "data"))) (EVar "TData"))
(DFunDef false "keywordOrIdent" ((PLit (LString "record"))) (EVar "TRecord"))
(DFunDef false "keywordOrIdent" ((PLit (LString "interface"))) (EVar "TInterface"))
(DFunDef false "keywordOrIdent" ((PLit (LString "default"))) (EVar "TDefault"))
(DFunDef false "keywordOrIdent" ((PLit (LString "impl"))) (EVar "TImpl"))
(DFunDef false "keywordOrIdent" ((PLit (LString "import"))) (EVar "TImport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "export"))) (EVar "TExport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "public"))) (EVar "TPublic"))
(DFunDef false "keywordOrIdent" ((PLit (LString "where"))) (EVar "TWhere"))
(DFunDef false "keywordOrIdent" ((PLit (LString "of"))) (EVar "TOf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "do"))) (EVar "TDo"))
(DFunDef false "keywordOrIdent" ((PLit (LString "as"))) (EVar "TAs"))
(DFunDef false "keywordOrIdent" ((PLit (LString "extern"))) (EVar "TExtern"))
(DFunDef false "keywordOrIdent" ((PLit (LString "requires"))) (EVar "TRequires"))
(DFunDef false "keywordOrIdent" ((PLit (LString "deriving"))) (EVar "TDeriving"))
(DFunDef false "keywordOrIdent" ((PLit (LString "type"))) (EVar "TType"))
(DFunDef false "keywordOrIdent" ((PLit (LString "newtype"))) (EVar "TNewtype"))
(DFunDef false "keywordOrIdent" ((PLit (LString "prop"))) (EVar "TProp"))
(DFunDef false "keywordOrIdent" ((PLit (LString "test"))) (EVar "TTest"))
(DFunDef false "keywordOrIdent" ((PLit (LString "bench"))) (EVar "TBench"))
(DFunDef false "keywordOrIdent" ((PLit (LString "effect"))) (EVar "TEffect"))
(DFunDef false "keywordOrIdent" ((PLit (LString "function"))) (EVar "TFunction"))
(DFunDef false "keywordOrIdent" ((PVar "s")) (EApp (EVar "TIdent") (EVar "s")))
(DTypeSig false "scan" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scan" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">=" (EVar "pos") (EVar "len")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanAt") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanAt" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EIf (EApp (EVar "isSpace") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isNL") (EVar "c")) (EApp (EVar "isCR") (EVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "handleNewline") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EVar "pos"))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "RComment") (EVar "pos")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "e") (ELit (LInt 0))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "unterminated block comment"))) (EBinOp "::" (EApp (EApp (EVar "RComment") (EVar "pos")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id")))))) (EIf (EApp (EVar "isDigit") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanNumber") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "False")) (ELit (LString ""))) (EIf (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LString ""))) (EIf (EApp (EVar "isApos") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanChar") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EApp (EApp (EApp (EApp (EVar "scanLower") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isUpper") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanUpper") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isBacktick") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanBacktick") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOp") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))
(DTypeSig false "skipLineComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipLineComment" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lexErrorTok" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "lexErrorTok" ((PVar "p") (PVar "msg")) (EListLit (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TLexError") (EVar "msg"))) (EVar "p")) (EVar "p"))))
(DTypeSig false "skipBlockComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "skipBlockComment" ((PVar "src") (PVar "len") (PVar "p") (PVar "d")) (EIf (EBinOp "<=" (EVar "d") (ELit (LInt 0))) (EVar "p") (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "}")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "-" (EVar "d") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanLower" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanLower" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EApp (EVar "identToken") (EVar "src")) (EVar "pos")) (EVar "e"))) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))))))
(DTypeSig false "identToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "identToken" ((PVar "src") (PVar "pos") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "_"))) (EBinOp "==" (EBinOp "-" (EVar "e") (EVar "pos")) (ELit (LInt 1)))) (EVar "TUnderscore") (EIf (EVar "otherwise") (EApp (EVar "keywordOrIdent") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanUpper" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanUpper" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TUpper") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))))))
(DTypeSig false "scanBacktick" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanBacktick" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TBacktickIdent") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "e")))) (EVar "pos")) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EVar "depth")) (EVar "id"))))))
(DTypeSig false "btClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "btClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isBacktick") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "digitsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "digitsEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EApp (EVar "isRadixDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "radixKind" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "radixKind" ((PVar "k")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "k") (ELit (LChar "x"))) (EBinOp "==" (EVar "k") (ELit (LChar "b")))) (EBinOp "==" (EVar "k") (ELit (LChar "o")))))
(DTypeSig false "radixBase" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixBase" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixBase" ((PLit (LChar "b"))) (ELit (LInt 2)))
(DFunDef false "radixBase" (PWild) (ELit (LInt 8)))
(DTypeSig false "isRadixDigit" (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))
(DFunDef false "isRadixDigit" ((PLit (LChar "x")) (PVar "c")) (EApp (EVar "isHexDigit") (EVar "c")))
(DFunDef false "isRadixDigit" ((PLit (LChar "b")) (PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "0"))) (EBinOp "==" (EVar "c") (ELit (LChar "1")))))
(DFunDef false "isRadixDigit" (PWild (PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "7")))))
(DTypeSig false "digitVal" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "digitVal" ((PVar "c")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f")))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 87))) (EIf (EVar "otherwise") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 55))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Int"))))))
(DFunDef false "radixEnd" ((PVar "src") (PVar "len") (PVar "p") (PVar "k")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EApp (EVar "isRadixDigit") (EVar "k")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "k")) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseRadix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseRadix" ((PVar "src") (PVar "p") (PVar "endp") (PVar "base") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EBinOp "+" (EBinOp "*" (EVar "acc") (EVar "base")) (EApp (EVar "digitVal") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMaxLen" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLen" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixMaxLen" ((PLit (LChar "b"))) (ELit (LInt 63)))
(DFunDef false "radixMaxLen" (PWild) (ELit (LInt 21)))
(DTypeSig false "radixMaxLead" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLead" ((PLit (LChar "b"))) (ELit (LInt 1)))
(DFunDef false "radixMaxLead" (PWild) (ELit (LInt 4)))
(DTypeSig false "sigRadixDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sigRadixDigits" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0")))) (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "p")) (EVar "endp")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMagOverflows" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "radixMagOverflows" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "radixMagOverflows" ((PCons (PVar "d") (PVar "rest")) (PVar "maxLen") (PVar "maxLead")) (EBlock (DoLet false false (PVar "n") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "rest")))) (DoExpr (EBinOp "||" (EBinOp ">" (EVar "n") (EVar "maxLen")) (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "maxLen")) (EBinOp "||" (EBinOp ">" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LChar "0"))))) (EVar "rest")))))))))
(DTypeSig false "radixLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "radixLitOverflows" ((PVar "src") (PVar "start") (PVar "endp") (PVar "k")) (EApp (EApp (EApp (EVar "radixMagOverflows") (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EVar "start")) (EVar "endp"))) (EApp (EVar "radixMaxLen") (EVar "k"))) (EApp (EVar "radixMaxLead") (EVar "k"))))
(DTypeSig false "scanRadix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanRadix" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "radixTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e")) (EVar "k")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "radixTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))
(DFunDef false "radixTok" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e") (PVar "k") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EVar "radixLitOverflows") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EVar "k")) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "integer literal too large for Int (max magnitude 2^62)"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EApp (EVar "radixBase") (EVar "k"))) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanNumber" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanNumber" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EVar "scanRadix") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "malformedRadixTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "numFinish") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "pos"))) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isMalformedRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LChar "_")))))
(DTypeSig false "malformedRadixTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "malformedRadixTok" ((PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoLet false false (PVar "digits") (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "malformedRadixErr") (EVar "pos")) (EVar "bad")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EVar "digits")))))
(DTypeSig false "stripLeadingUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripLeadingUs" ((PVar "src") (PVar "p") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_")))) (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "p")) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "malformedRadixErr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok")))))))
(DFunDef false "malformedRadixErr" ((PVar "pos") (PVar "bad") (PVar "prefix") (PVar "digits")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "digits")) (ELit (LInt 0))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: '_' cannot immediately follow the radix prefix '"))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString "', and no digit follows it either")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: '_' cannot immediately follow the radix prefix — write `"))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "digits"))) (ELit (LString "`")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isFloatAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isFloatAt" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp "<" (EBinOp "+" (EVar "e1") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))))
(DTypeSig false "isExpMarker" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExpMarker" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "e"))) (EBinOp "==" (EVar "c") (ELit (LChar "E")))))
(DTypeSig false "expEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "expEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isExpMarker") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EBlock (DoLet false false (PVar "q") (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "+"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-"))))) (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "q") (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "q")))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "q")) (EVar "p")))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "numFinish" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "numFinish" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isFloatAt") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EVar "depth")) (EVar "id")) (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1"))) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedExpDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "malformedExpDotTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "isMalformedTrailingDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EVar "malformedTrailingDotTok") (EVar "src")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "intLitOverflows") (EVar "src")) (EVar "pos")) (EVar "e1")) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "integer literal too large for Int (max magnitude 2^62)"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EVar "pos")) (EVar "e1")) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e1")))) (EVar "pos")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e1")) (EVar "depth")) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "isMalformedExpDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedExpDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))))
(DTypeSig false "malformedExpDotTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))
(DFunDef false "malformedExpDotTok" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "expE") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "expE"))) (DoLet false false (PVar "good") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))) (ELit (LString "0"))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EVar "expE")))) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: a float needs a digit after the decimal point — write `"))) (EApp (EVar "display") (EVar "good"))) (ELit (LString "`")))))))
(DTypeSig false "isMalformedTrailingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedTrailingDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "dotContinuesAccess") (EVar "src")) (EVar "len")) (EVar "e1")))))
(DTypeSig false "dotContinuesAccess" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "dotContinuesAccess" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EApp (EVar "isUpper") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "_")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "[")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar ".")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "*"))))))
(DTypeSig false "malformedTrailingDotTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "malformedTrailingDotTok" ((PVar "src") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: a float needs a digit after the decimal point — write `"))) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "0`")))))))
(DTypeSig false "floatTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "floatTok" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e2"))) (EVar "depth")) (EVar "id")))))
(DTypeSig false "floatIsFinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "floatIsFinite" ((PVar "f")) (EBinOp "==" (EBinOp "*" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))
(DTypeSig false "floatTokEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "floatTokEnd" ((PVar "src") (PVar "len") (PVar "pos") (PVar "endp") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "fromOption") (ELit (LFloat 0.0))) (EApp (EVar "stringToFloat") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "pos")) (EVar "endp"))))) (DoExpr (EIf (EApp (EVar "floatIsFinite") (EVar "f")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TFloat") (EVar "f"))) (EVar "pos")) (EVar "endp")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "endp")) (EVar "depth")) (EVar "id"))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "float literal out of range (overflows to infinity)")))))))
(DTypeSig false "scanStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))
(DFunDef false "scanStr" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (ELit (LString "unterminated string literal"))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EVar "acc"))) (EVar "startQ")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EVar "id"))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStrEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (ELit (LString "unterminated string literal"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "commonEscDecode" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "commonEscDecode" ((PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EVar "Some") (ELit (LString "\n"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EVar "Some") (ELit (LString "\t"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EVar "Some") (ELit (LString "\r"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EVar "Some") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0)))))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\\"))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\""))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "scanStrEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))))
(DFunDef false "scanStrEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "{"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (ELit (LInt 1)))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "commonEscDecode") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EBinOp "++" (EVar "acc") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString "invalid escape sequence '\\")) (EApp (EVar "display") (EApp (EVar "charToStr") (EVar "e")))) (ELit (LString "'")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanInterpCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanInterpCont" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (ELit (LInt 0)))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (ELit (LInt 0)))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "scanInterpEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanInterpEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\t")))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\\")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\r")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0))))))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "isTripleAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTripleAt" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "firstNl" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "firstNl" ((PVar "leadingNl") (PVar "acc")) (EBinOp "||" (EBinOp "==" (EVar "acc") (ELit (LString ""))) (EVar "leadingNl")))
(DTypeSig false "maybeStrip" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "maybeStrip" ((PCon "True") (PVar "acc")) (EApp (EVar "stripIndent") (EVar "acc")))
(DFunDef false "maybeStrip" ((PCon "False") (PVar "acc")) (EVar "acc"))
(DTypeSig false "scanTriple" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok")))))))))))
(DFunDef false "scanTriple" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "leadingNl") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EApp (EApp (EVar "maybeStrip") (EVar "leadingNl")) (EVar "acc")))) (EVar "startQ")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id"))) (EIf (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "p")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EApp (EApp (EVar "maybeStrip") (EVar "leadingNl")) (EVar "acc")))) (EVar "startQ")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "depth")) (EVar "id"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EBinOp "++" (EVar "tripleInterpMark") (EVar "acc")))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTripleEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "firstNl") (EVar "leadingNl")) (EVar "acc"))) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\"\"")))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "scanTripleEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))))
(DFunDef false "scanTripleEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "leadingNl") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\t")))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\\")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\r")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0))))))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "scanInterpTripleCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanInterpTripleCont" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (ELit (LInt 0)))) (EIf (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "p")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "depth")) (ELit (LInt 0)))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"\"")))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "scanInterpTripleEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanInterpTripleEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\t")))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\\")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\r")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0))))))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "stripIndent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripIndent" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stripIndentCs") (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "stripIndentCs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripIndentCs" ((PVar "s") (PVar "cs") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EIf (EBinOp "!=" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n"))) (EVar "s") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n")) (ELit (LString "")))) (DoLet false false (PVar "minInd") (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EVar "lines")) (EVar "indentSentinel")))) (DoExpr (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "lines"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitLines" ((PVar "cs") (PVar "p") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EListLit (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "p")) (ELit (LChar "\n"))) (EBinOp "::" (EVar "acc") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n")) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "cs")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "indentSentinel" (TyCon "Int"))
(DFunDef false "indentSentinel" () (ELit (LInt 1000000000)))
(DTypeSig false "indentOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "indentOf" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "indentOfGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "indentOfGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "indentSentinel") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "i")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minInt" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "a") (EVar "b")))
(DTypeSig false "minIndentGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minIndentGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "minIndentGo" ((PCons (PVar "l") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "minIndentGo") (EVar "rest")) (EApp (EApp (EVar "minInt") (EVar "acc")) (EApp (EVar "indentOf") (EVar "l")))))
(DTypeSig false "normalizeMin" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "normalizeMin" ((PVar "m")) (EIf (EBinOp "==" (EVar "m") (EVar "indentSentinel")) (ELit (LInt 0)) (EVar "m")))
(DTypeSig false "stripLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "stripLines" (PWild (PList)) (EListLit))
(DFunDef false "stripLines" ((PVar "k") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "stripLine") (EVar "k")) (EVar "l")) (EApp (EApp (EVar "stripLines") (EVar "k")) (EVar "rest"))))
(DTypeSig false "stripLine" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripLine" ((PVar "k") (PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (EApp (EApp (EVar "minInt") (EVar "k")) (EVar "n"))) (EVar "n")))))
(DTypeSig false "dropCharsToStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "dropCharsToStr" ((PVar "cs") (PVar "k") (PVar "n")) (EIf (EBinOp ">=" (EVar "k") (EVar "n")) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "cs")) (EVar "k"))) (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "joinNlStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinNlStr" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "xs")))
(DTypeSig false "tripleInterpMark" (TyCon "String"))
(DFunDef false "tripleInterpMark" () (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 1))))))
(DTypeSig false "hasTripleInterpMark" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasTripleInterpMark" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 1)))))))))
(DTypeSig false "dropTripleInterpMark" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTripleInterpMark" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "startsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n")))))))
(DTypeSig false "endsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (ELit (LChar "\n")))))))
(DTypeSig false "computeMinIndent" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "computeMinIndent" ((PVar "joined")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "joined"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n")) (ELit (LString "")))) (EVar "indentSentinel"))))))
(DTypeSig false "dedentGroupSegs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dedentGroupSegs" ((PVar "minInd") (PCons (PVar "openStr") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "openStr"))) (DoLet false false (PVar "openLines") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LString "")))) (DoLet false false (PVar "openOut") (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "openLines")))) (DoExpr (EBinOp "::" (EVar "openOut") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "openStr"))) (EVar "rest"))))))
(DFunDef false "dedentGroupSegs" (PWild (PList)) (EListLit))
(DTypeSig false "dedentRestSegs" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dedentRestSegs" (PWild PWild (PList)) (EListLit))
(DFunDef false "dedentRestSegs" ((PVar "minInd") (PVar "atLineStart") (PCons (PVar "seg") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "seg"))) (DoLet false false (PVar "lines") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LString "")))) (DoLet false false (PVar "out") (EApp (EVar "joinNlStr") (EApp (EApp (EApp (EVar "stripFirstAware") (EVar "minInd")) (EVar "atLineStart")) (EVar "lines")))) (DoExpr (EBinOp "::" (EVar "out") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "seg"))) (EVar "rest"))))))
(DTypeSig false "stripFirstAware" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stripFirstAware" (PWild PWild (PList)) (EListLit))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "True") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "stripLine") (EVar "minInd")) (EVar "l")) (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "False") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DTypeSig false "splitInterpGroup" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "splitInterpGroup" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpMid" (PVar "s")) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "s") (EVar "segs")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "s"))) (EVar "mo")) (EVar "me")) (EVar "mid")) (EVar "after")))))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpEnd" (PVar "s")) (PVar "eo") (PVar "ee")) (PVar "rest"))) (ETuple (EListLit (EVar "s")) (EListLit (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "s"))) (EVar "eo")) (EVar "ee"))) (EVar "rest")))
(DFunDef false "splitInterpGroup" ((PCons (PVar "t") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EVar "segs") (EBinOp "::" (EVar "t") (EVar "mid")) (EVar "after")))))
(DTypeSig false "substituteOwn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "substituteOwn" (PWild (PList)) (EListLit))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpMid" PWild) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "v"))) (EVar "mo")) (EVar "me")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpEnd" PWild) (PVar "eo") (PVar "ee")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "v"))) (EVar "eo")) (EVar "ee")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PVar "vals") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EVar "vals")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PList) (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EListLit)) (EVar "rest"))))
(DTypeSig false "dedentTripleInterp" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "dedentTripleInterp" ((PList)) (EListLit))
(DFunDef false "dedentTripleInterp" ((PCons (PCon "RTok" (PCon "TInterpOpen" (PVar "s")) (PVar "so") (PVar "eo")) (PVar "rest"))) (EIf (EApp (EVar "hasTripleInterpMark") (EVar "s")) (EBlock (DoLet false false (PVar "sReal") (EApp (EVar "dropTripleInterpMark") (EVar "s"))) (DoLet false false (PTuple (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dedentTripleGroup") (EVar "sReal")) (EVar "so")) (EVar "eo")) (EVar "rawSegs")) (EVar "midToks")) (EVar "afterEnd")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dedentTripleInterp" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "dedentTripleInterp") (EVar "rest"))))
(DTypeSig false "dedentTripleGroup" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "dedentTripleGroup" ((PVar "sReal") (PVar "so") (PVar "eo") (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EIf (EApp (EVar "startsWithNl") (EVar "sReal")) (EBlock (DoLet false false (PVar "allRaw") (EBinOp "::" (EVar "sReal") (EVar "rawSegs"))) (DoLet false false (PVar "minInd") (EApp (EVar "computeMinIndent") (EApp (EVar "concatAll") (EVar "allRaw")))) (DoExpr (EMatch (EApp (EApp (EVar "dedentGroupSegs") (EVar "minInd")) (EVar "allRaw")) (arm (PCons (PVar "openStr'") (PVar "restVals")) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "openStr'"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EApp (EApp (EVar "substituteOwn") (EVar "restVals")) (EVar "midToks")) (EApp (EVar "dedentTripleInterp") (EVar "afterEnd"))))) (arm (PList) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleInterp") (EVar "afterEnd")))))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleInterp") (EVar "afterEnd")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "concatAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "concatAll" ((PList)) (ELit (LString "")))
(DFunDef false "concatAll" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EVar "x") (EApp (EVar "concatAll") (EVar "xs"))))
(DTypeSig false "charEscDecode" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "charEscDecode" ((PVar "e")) (EIf (EApp (EVar "isApos") (EVar "e")) (EApp (EVar "Some") (ELit (LString "'"))) (EIf (EVar "otherwise") (EApp (EVar "commonEscDecode") (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanChar" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EApp (EApp (EApp (EApp (EApp (EVar "readChar") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")))
(DTypeSig false "readChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "readChar" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg")) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "u")))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LChar "{")))) (EApp (EApp (EApp (EApp (EApp (EVar "readCharUnicode") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "escChar") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (ELit (LString "character literal is empty. A character is exactly one codepoint — write `'\\0'` for the NUL character, or use a `\"\"` string for an empty value"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "rawChar") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "charUntermMsg" (TyCon "String"))
(DFunDef false "charUntermMsg" () (ELit (LString "character literal is not terminated. A character is one codepoint between single quotes, as in `'a'` or `'\\n'`")))
(DTypeSig false "escChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "escChar" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id") (PVar "e")) (EMatch (EApp (EVar "charEscDecode") (EVar "e")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString "invalid escape sequence '\\")) (EApp (EVar "display") (EApp (EVar "charToStr") (EVar "e")))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "s")) () (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EVar "s"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "depth")) (EVar "id"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg"))))))
(DTypeSig false "rawChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "rawChar" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id")) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EVar "id"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EVar "p"))) (DoExpr (EIf (EBinOp ">=" (EVar "e") (EVar "len")) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg")) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EBinOp "++" (EBinOp "++" (ELit (LString "character literal must be a single codepoint, but `'")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "p")) (EVar "e")))) (ELit (LString "'` has more than one. Use a `\"...\"` string for text, or `'\\u{...}'` for one codepoint by its hex value"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "charClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "charClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscWellFormed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "uniEscWellFormed" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "he") (EVar "s")) (EBinOp "<" (EVar "he") (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))))))
(DTypeSig false "uniHexSigLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniHexSigLen" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0"))) (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "-" (EVar "endp") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscCode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "uniEscCode" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 6))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 16))) (ELit (LInt 0))))))))
(DTypeSig false "uniEscText" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "uniEscText" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1)))))
(DTypeSig false "uniEscChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))))
(DFunDef false "uniEscChar" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cp")) () (EApp (EVar "charFromCode") (EVar "cp")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "uniIsSurrogate" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "uniIsSurrogate" ((PVar "cp")) (EBinOp "&&" (EBinOp ">=" (EVar "cp") (ELit (LInt 55296))) (EBinOp "<=" (EVar "cp") (ELit (LInt 57343)))))
(DTypeSig false "uniEscTermErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))))
(DFunDef false "uniEscTermErr" ((PVar "src") (PVar "len") (PVar "s") (PVar "he")) (EIf (EBinOp ">=" (EVar "he") (EVar "len")) (ELit (LString "unicode escape is not terminated. Expected one to six hex digits (0-9, a-f, A-F) then `}`, but the file ended")) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "_"))) (ELit (LString "unicode escape uses a `_` separator, which is not allowed here. `_` groups digits in integer literals (`1_000`, `0xD_EAD`), but a `\\u{...}` codepoint must be an unbroken run of hex digits — write the digits unbroken, as in `\\u{41}` rather than `\\u{4_1}`")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "he") (EVar "s")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))) (ELit (LString "unicode escape `\\u{}` has no digits. A codepoint needs at least one hex digit — `\\u{41}` is 'A' and `\\u{0}` is NUL")) (EIf (EBinOp "==" (EVar "he") (EVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape is not terminated. Expected one to six hex digits (0-9, a-f, A-F) then `}`, but found `")) (EApp (EVar "display") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he"))))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape is not terminated. Expected `}` after the hex digits, but found `")) (EApp (EVar "display") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he"))))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "uniEscErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "uniEscErr" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "uniEscTermErr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3))))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "Some" (PVar "cp")) ((GBool (EApp (EVar "uniIsSurrogate") (EVar "cp")))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape '")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))) (ELit (LString "' is a UTF-16 surrogate, not a character. Codepoints D800-DFFF only ever encode one half of a surrogate pair and are never valid on their own")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape '")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))) (ELit (LString "' is out of range. A codepoint must be at most 10FFFF"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "readCharUnicode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "readCharUnicode" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EBlock (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "he") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "he") (ELit (LInt 1)))))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EApp (EVar "charToStr") (EVar "c")))) (EVar "p")) (EBinOp "+" (EVar "he") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "he") (ELit (LInt 2)))) (EVar "depth")) (EVar "id"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg"))))))))
(DTypeSig false "uHexEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uHexEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isHexDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isUnicodeEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "isUnicodeEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "u"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LChar "{")))))
(DTypeSig false "uniEscEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniEscEnd" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1))))
(DTypeSig false "emit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))))
(DFunDef false "emit" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "tok") (PVar "length") (PVar "ddelta")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "tok")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "length"))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (EVar "length"))) (EBinOp "+" (EVar "depth") (EVar "ddelta"))) (EVar "id"))))
(DTypeSig false "scanOp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEllipsis")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDotEq")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "["))) (ELit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLArray")) (ELit (LInt 2))) (ELit (LInt 1))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRArray")) (ELit (LInt 2))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TFatArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "-"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TCons")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColonEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPlusPlus")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "!"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TNeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "/"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TSlashEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TAnd")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TOr")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipeRight")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotLBrace")) (ELit (LInt 2))) (ELit (LInt 1))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotStar")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDot")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))))))))))))))
(DTypeSig false "singleOp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPlus")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "minusTok") (EVar "src")) (EVar "len")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TStar")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "/"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TSlash")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqual")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColon")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ","))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TComma")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "."))) (EIf (EApp (EApp (EApp (EVar "isMalformedLeadingDot") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "malformedLeadingDotTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDot")) (ELit (LInt 1))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipe")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "("))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLParen")) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ")"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRParen")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "["))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "bracketTok") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRBracket")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EVar "openBrace") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EVar "closeBrace") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "!"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TBang")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "%"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TMod")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "@"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "atToken") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "\\"))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "unexpected '\\'. Medaka lambdas are written 'x => e' (not '\\x -> e')"))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "$"))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "Medaka has no '$'. Apply directly 'f x', parenthesize '(f x)', or pipe with '|>'"))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected character '")) (EApp (EVar "display") (EApp (EVar "charToStr") (EVar "c")))) (ELit (LString "'")))))
(DTypeSig false "bracketTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "bracketTok" ((PVar "src") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EVar "TLBracketTight") (EIf (EVar "otherwise") (EVar "TLBracket") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExprEnd" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExprEnd" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ")")))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "\"")))))
(DTypeSig false "isMalformedLeadingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedLeadingDot" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "||" (EBinOp "==" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))))
(DTypeSig false "malformedLeadingDotTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "malformedLeadingDotTok" ((PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "d"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: a float needs a digit before the decimal point — write `0"))) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`")))))))
(DTypeSig false "atToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "atToken" ((PVar "src") (PVar "pos")) (EIf (EBinOp "<=" (EVar "pos") (ELit (LInt 0))) (EVar "TAt") (EIf (EBinOp "&&" (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1))))) (EApp (EApp (EVar "identStartLower") (EVar "src")) (EApp (EApp (EVar "identRunStart") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EVar "TAsAt") (EIf (EVar "otherwise") (EVar "TAt") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minusTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "minusTok" ((PVar "src") (PVar "len") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isSpace") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EVar "TMinusTight") (EIf (EVar "otherwise") (EVar "TMinus") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "identRunStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identRunStart" ((PVar "src") (PVar "p")) (EIf (EBinOp "<=" (EVar "p") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "p") (ELit (LInt 1))))) (EApp (EApp (EVar "identRunStart") (EVar "src")) (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStartLower" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "identStartLower" ((PVar "src") (PVar "p")) (EBinOp "||" (EApp (EVar "isLower") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_")))))
(DTypeSig false "openBrace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "openBrace" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">" (EVar "id") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "+" (EVar "id") (ELit (LInt 1))))) (EIf (EBinOp "<" (EVar "id") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "-" (EVar "id") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "closeBrace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "closeBrace" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">" (EVar "id") (ELit (LInt 1))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "-" (EVar "id") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "id") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (ELit (LString ""))) (EIf (EBinOp "==" (EVar "id") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (ELit (LString ""))) (EIf (EBinOp "<" (EVar "id") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "+" (EVar "id") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "handleNewline" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "handleNewline" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PTuple (PVar "indent") (PVar "np")) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "afterNl") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EVar "indent")) (EVar "pos")))))
(DTypeSig false "consumeNl" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "consumeNl" ((PVar "src") (PVar "len") (PVar "p") (PVar "indent")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (ETuple (EVar "indent") (EVar "p")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LInt 0))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "indent") (ELit (LInt 1)))) (EIf (EApp (EVar "isTab") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "*" (EBinOp "+" (EBinOp "/" (EVar "indent") (ELit (LInt 8))) (ELit (LInt 1))) (ELit (LInt 8)))) (EIf (EVar "otherwise") (ETuple (EVar "indent") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "afterNl" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))
(DFunDef false "afterNl" ((PVar "src") (PVar "len") (PVar "np") (PVar "depth") (PVar "id") (PVar "indent") (PVar "nlPos")) (EIf (EApp (EApp (EApp (EVar "nextIsComment") (EVar "src")) (EVar "len")) (EVar "np")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isContinuation") (EVar "src")) (EVar "len")) (EVar "np")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "continuationTok") (EVar "src")) (EVar "len")) (EVar "np"))) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "RNewline") (EVar "indent")) (EVar "nlPos")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "nextIsComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextIsComment" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))))))
(DTypeSig false "isContinuation" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isContinuation" ((PVar "src") (PVar "len") (PVar "np")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar ">")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "<")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "&"))) (ELit (LChar "&")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar "|")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "+"))) (ELit (LChar "+")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ":"))) (ELit (LChar ":")))))
(DTypeSig false "continuationTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "continuationTok" ((PVar "src") (PVar "len") (PVar "np")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EVar "TPipeRight") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EVar "TRCompose") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EVar "TLCompose") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EVar "TAnd") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EVar "TOr") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EVar "TPlusPlus") (EIf (EVar "otherwise") (EVar "TCons") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "layout" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "layout" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAll") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layout" ((PCons (PCon "RTok" (PVar "t") (PVar "off") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (ELit (LInt 0)) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClose") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "layout" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "flushClose" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PCons (PVar "f") (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "opener")))
(DTypeSig false "flushCloseGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bracketOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketOpener" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TDotLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" (PWild) (EVar "False"))
(DTypeSig false "bracketCloser" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketCloser" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "bracketCloser" (PWild) (EVar "False"))
(DTypeSig false "isOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpener" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isOpener" (PWild) (EVar "False"))
(DTypeSig false "canEndExpr" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canEndExpr" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInterpEnd" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canEndExpr" (PWild) (EVar "False"))
(DTypeSig false "prevCanEnd" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevCanEnd" ((PCon "Some" (PVar "t"))) (EApp (EVar "canEndExpr") (EVar "t")))
(DFunDef false "prevCanEnd" ((PCon "None")) (EVar "False"))
(DTypeSig false "isTrailingContinuationOp" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMinus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TStar")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TSlash")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMod")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TCons")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TEqEq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TNeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TAnd")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TOr")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPipeRight")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TRCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TBacktickIdent" PWild)) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" (PWild) (EVar "False"))
(DTypeSig false "prevIsTrailingOp" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevIsTrailingOp" ((PCon "Some" (PVar "t"))) (EApp (EVar "isTrailingContinuationOp") (EVar "t")))
(DFunDef false "prevIsTrailingOp" ((PCon "None")) (EVar "False"))
(DTypeSig false "armsHerald" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TDo"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "canStartAtom" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canStartAtom" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TAt")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TInterpOpen" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" (PWild) (EVar "False"))
(DTypeSig false "applyNl" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFrame") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFrame" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PVar "f") (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (ELit (LInt 1)) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTop" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTop" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndent") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndent" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "wouldIndent" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveCont") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "bumpFrame" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bumpFrame" ((PList)) (EListLit))
(DFunDef false "bumpFrame" ((PCons (PVar "f") (PVar "fs"))) (EBinOp "::" (EBinOp "+" (EVar "f") (ELit (LInt 1))) (EVar "fs")))
(DTypeSig false "dropFrame" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "dropFrame" ((PList)) (EListLit))
(DFunDef false "dropFrame" ((PCons (PVar "f") (PVar "fs"))) (EBinOp "::" (EBinOp "-" (EVar "f") (ELit (LInt 1))) (EVar "fs")))
(DTypeSig false "resolveCont" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TThen")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TElse")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedents" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAll" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeAll" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedents" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeDedents" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilter" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TElse") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TThen") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PList)) (EListLit))
(DTypeSig false "stripComments" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "stripComments" ((PList)) (EListLit))
(DFunDef false "stripComments" ((PCons (PCon "RComment" PWild PWild) (PVar "rest"))) (EApp (EVar "stripComments") (EVar "rest")))
(DFunDef false "stripComments" ((PCons (PVar "r") (PVar "rest"))) (EBinOp "::" (EVar "r") (EApp (EVar "stripComments") (EVar "rest"))))
(DTypeSig false "layoutWithOffsets" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsets" ((PVar "src") (PVar "len")) (EApp (EVar "elseFilter") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EApp (EVar "stripComments") (EApp (EVar "dedentTripleInterp") (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))
(DTypeSig false "layoutPairs" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "layoutPairs" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAllPairs") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layoutPairs" ((PCons (PCon "RTok" (PVar "t") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (ELit (LInt 0)) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairs") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "layoutPairs" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "flushClosePairs" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PVar "f") (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "opener")))
(DTypeSig false "flushClosePairsGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "s") (EVar "s")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "s") (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFramePairs") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFramePairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PVar "f") (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (ELit (LInt 1)) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTopPairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "wouldIndentPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TThen")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TElse")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedentsPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeAllPairs" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedentsPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeDedentsPairs" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilterPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TElse") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TThen") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PList)) (EListLit))
(DTypeSig false "layoutWithOffsetPairs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsetPairs" ((PVar "src") (PVar "len")) (EApp (EVar "elseFilterPairs") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EApp (EVar "stripComments") (EApp (EVar "dedentTripleInterp") (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))
(DTypeSig true "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "tokenize" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))))))
(DTypeSig true "tokenizeWithLines" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithLines" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "lines") (EApp (EApp (EVar "offsetsToLines") (EVar "src")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "pairs")))) (DoExpr (ETuple (EVar "toks") (EVar "lines")))))
(DTypeSig true "tokenizeWithOffsets" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithOffsets" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "offs") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "pairs"))) (DoExpr (ETuple (EVar "toks") (EVar "offs")))))
(DTypeSig true "tokenizeWithOffsetPairs" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "tokenizeWithOffsetPairs" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "layoutWithOffsetPairs") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "t") (PVar "_s") (PVar "_e"))) (EVar "t"))) (EVar "triples"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "t") (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e")))) (EVar "triples"))) (DoExpr (ETuple (EVar "toks") (EVar "pairs")))))
(DTypeSig true "offsetToLineCol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineCol" ((PVar "s") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig true "lineStartsOf" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "lineStartsOf" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EVar "arrayFromList") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (ELit (LInt 0))))))))
(DTypeSig false "lineStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "lineStartsGo" ((PVar "src") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\n"))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "offsetToLineColFast" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineColFast" ((PVar "lineStarts") (PVar "off")) (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "lineStarts")) (EVar "off")) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "lineStarts")) (ELit (LInt 1))))) (DoExpr (ETuple (EBinOp "+" (EVar "idx") (ELit (LInt 1))) (EBinOp "-" (EVar "off") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "lineStarts")))))))
(DTypeSig false "lineStartSearch" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lineStartSearch" ((PVar "arr") (PVar "off") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 1))) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "arr")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "mid")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "lo")) (EBinOp "-" (EVar "mid") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "offsetsToLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "offsetsToLines" ((PVar "src") (PVar "offs")) (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "offs")) (ELit (LInt 0))) (ELit (LInt 1))))
(DTypeSig false "offsetsToLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PList) (PVar "p") (PVar "line")) (EListLit))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PCons (PVar "off") (PVar "rest")) (PVar "p") (PVar "line")) (EMatch (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "off")) (EVar "p")) (EVar "line")) (arm (PTuple (PVar "line2") (PVar "p2")) () (EBinOp "::" (EVar "line2") (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "rest")) (EVar "p2")) (EVar "line2"))))))
(DTypeSig false "advanceLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "advanceLine" ((PVar "src") (PVar "target") (PVar "p") (PVar "line")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EVar "p")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "src"))) (ETuple (EVar "line") (EVar "p")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "src")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Abstract "Comment" () ((variant "Comment" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig true "commentLine" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentLine" ((PCon "Comment" (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "commentCol" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentCol" ((PCon "Comment" PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "commentText" (TyFun (TyCon "Comment") (TyCon "String")))
(DFunDef false "commentText" ((PCon "Comment" PWild PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "posLineColFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posLineColFrom" ((PVar "src") (PVar "target") (PVar "p") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EBinOp "-" (EVar "target") (EVar "lineStart"))) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rawToComments" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "rawToComments" ((PVar "src") (PVar "toks")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "toks")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig false "rawToCommentsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "rawToCommentsGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons (PCon "RComment" (PVar "startPos") (PVar "text")) (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "startPos")) (EVar "p")) (EVar "line")) (EVar "lineStart")) (arm (PTuple (PVar "line2") (PVar "col")) () (EBinOp "::" (EApp (EApp (EApp (EVar "Comment") (EVar "line2")) (EVar "col")) (EVar "text")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "startPos")) (EVar "line2")) (EBinOp "-" (EVar "startPos") (EVar "col")))))))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons PWild (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "p")) (EVar "line")) (EVar "lineStart")))
(DTypeSig true "collectComments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "collectComments" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EApp (EVar "rawToComments") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))))
# MARK
(DUse false (UseGroup ("support" "char") ((mem "isSp" false) (mem "isTab" false) (mem "isNL" false) (mem "isCR" false) (mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isBacktick" false) (mem "isSpace" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isAlnum" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "compareDecMag" false) (mem "listLen" false) (mem "anyList" false))))
(DData Public "Token" () ((variant "TInt" (ConPos (TyCon "Int") (TyCon "String"))) (variant "TFloat" (ConPos (TyCon "Float"))) (variant "TString" (ConPos (TyCon "String"))) (variant "TChar" (ConPos (TyCon "String"))) (variant "TBool" (ConPos (TyCon "Bool"))) (variant "TInterpOpen" (ConPos (TyCon "String"))) (variant "TInterpMid" (ConPos (TyCon "String"))) (variant "TInterpEnd" (ConPos (TyCon "String"))) (variant "TIdent" (ConPos (TyCon "String"))) (variant "TUpper" (ConPos (TyCon "String"))) (variant "TBacktickIdent" (ConPos (TyCon "String"))) (variant "TLet" (ConPos)) (variant "TRec" (ConPos)) (variant "TWith" (ConPos)) (variant "TMut" (ConPos)) (variant "TIn" (ConPos)) (variant "TIf" (ConPos)) (variant "TThen" (ConPos)) (variant "TElse" (ConPos)) (variant "TMatch" (ConPos)) (variant "TData" (ConPos)) (variant "TRecord" (ConPos)) (variant "TInterface" (ConPos)) (variant "TDefault" (ConPos)) (variant "TImpl" (ConPos)) (variant "TImport" (ConPos)) (variant "TExport" (ConPos)) (variant "TPublic" (ConPos)) (variant "TWhere" (ConPos)) (variant "TOf" (ConPos)) (variant "TRequires" (ConPos)) (variant "TDo" (ConPos)) (variant "TAs" (ConPos)) (variant "TExtern" (ConPos)) (variant "TDeriving" (ConPos)) (variant "TType" (ConPos)) (variant "TNewtype" (ConPos)) (variant "TProp" (ConPos)) (variant "TTest" (ConPos)) (variant "TBench" (ConPos)) (variant "TEffect" (ConPos)) (variant "TFunction" (ConPos)) (variant "TPlus" (ConPos)) (variant "TMinus" (ConPos)) (variant "TMinusTight" (ConPos)) (variant "TStar" (ConPos)) (variant "TSlash" (ConPos)) (variant "TSlashEq" (ConPos)) (variant "TMod" (ConPos)) (variant "TEqEq" (ConPos)) (variant "TNeq" (ConPos)) (variant "TLt" (ConPos)) (variant "TGt" (ConPos)) (variant "TLeq" (ConPos)) (variant "TGeq" (ConPos)) (variant "TAnd" (ConPos)) (variant "TOr" (ConPos)) (variant "TCons" (ConPos)) (variant "TPlusPlus" (ConPos)) (variant "TPipeRight" (ConPos)) (variant "TRCompose" (ConPos)) (variant "TLCompose" (ConPos)) (variant "TFatArrow" (ConPos)) (variant "TArrow" (ConPos)) (variant "TLArrow" (ConPos)) (variant "TAt" (ConPos)) (variant "TBang" (ConPos)) (variant "TAsAt" (ConPos)) (variant "TEqual" (ConPos)) (variant "TColon" (ConPos)) (variant "TColonEq" (ConPos)) (variant "TComma" (ConPos)) (variant "TDot" (ConPos)) (variant "TPipe" (ConPos)) (variant "TUnderscore" (ConPos)) (variant "TLParen" (ConPos)) (variant "TRParen" (ConPos)) (variant "TLBracket" (ConPos)) (variant "TLBracketTight" (ConPos)) (variant "TRBracket" (ConPos)) (variant "TLBrace" (ConPos)) (variant "TRBrace" (ConPos)) (variant "TLArray" (ConPos)) (variant "TRArray" (ConPos)) (variant "TDotLBrace" (ConPos)) (variant "TDotStar" (ConPos)) (variant "TEllipsis" (ConPos)) (variant "TDotDot" (ConPos)) (variant "TDotDotEq" (ConPos)) (variant "TNewline" (ConPos)) (variant "TIndent" (ConPos)) (variant "TDedent" (ConPos)) (variant "TEof" (ConPos)) (variant "TLexError" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Token")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TInt" (PVar "__a0") (PVar "__a1")) (PCon "TInt" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "TFloat" (PVar "__a0")) (PCon "TFloat" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TString" (PVar "__a0")) (PCon "TString" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TChar" (PVar "__a0")) (PCon "TChar" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBool" (PVar "__a0")) (PCon "TBool" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpOpen" (PVar "__a0")) (PCon "TInterpOpen" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpMid" (PVar "__a0")) (PCon "TInterpMid" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpEnd" (PVar "__a0")) (PCon "TInterpEnd" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TIdent" (PVar "__a0")) (PCon "TIdent" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TUpper" (PVar "__a0")) (PCon "TUpper" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBacktickIdent" (PVar "__a0")) (PCon "TBacktickIdent" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TLet") (PCon "TLet")) () (EVar "True")) (arm (PTuple (PCon "TRec") (PCon "TRec")) () (EVar "True")) (arm (PTuple (PCon "TWith") (PCon "TWith")) () (EVar "True")) (arm (PTuple (PCon "TMut") (PCon "TMut")) () (EVar "True")) (arm (PTuple (PCon "TIn") (PCon "TIn")) () (EVar "True")) (arm (PTuple (PCon "TIf") (PCon "TIf")) () (EVar "True")) (arm (PTuple (PCon "TThen") (PCon "TThen")) () (EVar "True")) (arm (PTuple (PCon "TElse") (PCon "TElse")) () (EVar "True")) (arm (PTuple (PCon "TMatch") (PCon "TMatch")) () (EVar "True")) (arm (PTuple (PCon "TData") (PCon "TData")) () (EVar "True")) (arm (PTuple (PCon "TRecord") (PCon "TRecord")) () (EVar "True")) (arm (PTuple (PCon "TInterface") (PCon "TInterface")) () (EVar "True")) (arm (PTuple (PCon "TDefault") (PCon "TDefault")) () (EVar "True")) (arm (PTuple (PCon "TImpl") (PCon "TImpl")) () (EVar "True")) (arm (PTuple (PCon "TImport") (PCon "TImport")) () (EVar "True")) (arm (PTuple (PCon "TExport") (PCon "TExport")) () (EVar "True")) (arm (PTuple (PCon "TPublic") (PCon "TPublic")) () (EVar "True")) (arm (PTuple (PCon "TWhere") (PCon "TWhere")) () (EVar "True")) (arm (PTuple (PCon "TOf") (PCon "TOf")) () (EVar "True")) (arm (PTuple (PCon "TRequires") (PCon "TRequires")) () (EVar "True")) (arm (PTuple (PCon "TDo") (PCon "TDo")) () (EVar "True")) (arm (PTuple (PCon "TAs") (PCon "TAs")) () (EVar "True")) (arm (PTuple (PCon "TExtern") (PCon "TExtern")) () (EVar "True")) (arm (PTuple (PCon "TDeriving") (PCon "TDeriving")) () (EVar "True")) (arm (PTuple (PCon "TType") (PCon "TType")) () (EVar "True")) (arm (PTuple (PCon "TNewtype") (PCon "TNewtype")) () (EVar "True")) (arm (PTuple (PCon "TProp") (PCon "TProp")) () (EVar "True")) (arm (PTuple (PCon "TTest") (PCon "TTest")) () (EVar "True")) (arm (PTuple (PCon "TBench") (PCon "TBench")) () (EVar "True")) (arm (PTuple (PCon "TEffect") (PCon "TEffect")) () (EVar "True")) (arm (PTuple (PCon "TFunction") (PCon "TFunction")) () (EVar "True")) (arm (PTuple (PCon "TPlus") (PCon "TPlus")) () (EVar "True")) (arm (PTuple (PCon "TMinus") (PCon "TMinus")) () (EVar "True")) (arm (PTuple (PCon "TMinusTight") (PCon "TMinusTight")) () (EVar "True")) (arm (PTuple (PCon "TStar") (PCon "TStar")) () (EVar "True")) (arm (PTuple (PCon "TSlash") (PCon "TSlash")) () (EVar "True")) (arm (PTuple (PCon "TSlashEq") (PCon "TSlashEq")) () (EVar "True")) (arm (PTuple (PCon "TMod") (PCon "TMod")) () (EVar "True")) (arm (PTuple (PCon "TEqEq") (PCon "TEqEq")) () (EVar "True")) (arm (PTuple (PCon "TNeq") (PCon "TNeq")) () (EVar "True")) (arm (PTuple (PCon "TLt") (PCon "TLt")) () (EVar "True")) (arm (PTuple (PCon "TGt") (PCon "TGt")) () (EVar "True")) (arm (PTuple (PCon "TLeq") (PCon "TLeq")) () (EVar "True")) (arm (PTuple (PCon "TGeq") (PCon "TGeq")) () (EVar "True")) (arm (PTuple (PCon "TAnd") (PCon "TAnd")) () (EVar "True")) (arm (PTuple (PCon "TOr") (PCon "TOr")) () (EVar "True")) (arm (PTuple (PCon "TCons") (PCon "TCons")) () (EVar "True")) (arm (PTuple (PCon "TPlusPlus") (PCon "TPlusPlus")) () (EVar "True")) (arm (PTuple (PCon "TPipeRight") (PCon "TPipeRight")) () (EVar "True")) (arm (PTuple (PCon "TRCompose") (PCon "TRCompose")) () (EVar "True")) (arm (PTuple (PCon "TLCompose") (PCon "TLCompose")) () (EVar "True")) (arm (PTuple (PCon "TFatArrow") (PCon "TFatArrow")) () (EVar "True")) (arm (PTuple (PCon "TArrow") (PCon "TArrow")) () (EVar "True")) (arm (PTuple (PCon "TLArrow") (PCon "TLArrow")) () (EVar "True")) (arm (PTuple (PCon "TAt") (PCon "TAt")) () (EVar "True")) (arm (PTuple (PCon "TBang") (PCon "TBang")) () (EVar "True")) (arm (PTuple (PCon "TAsAt") (PCon "TAsAt")) () (EVar "True")) (arm (PTuple (PCon "TEqual") (PCon "TEqual")) () (EVar "True")) (arm (PTuple (PCon "TColon") (PCon "TColon")) () (EVar "True")) (arm (PTuple (PCon "TColonEq") (PCon "TColonEq")) () (EVar "True")) (arm (PTuple (PCon "TComma") (PCon "TComma")) () (EVar "True")) (arm (PTuple (PCon "TDot") (PCon "TDot")) () (EVar "True")) (arm (PTuple (PCon "TPipe") (PCon "TPipe")) () (EVar "True")) (arm (PTuple (PCon "TUnderscore") (PCon "TUnderscore")) () (EVar "True")) (arm (PTuple (PCon "TLParen") (PCon "TLParen")) () (EVar "True")) (arm (PTuple (PCon "TRParen") (PCon "TRParen")) () (EVar "True")) (arm (PTuple (PCon "TLBracket") (PCon "TLBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBracketTight") (PCon "TLBracketTight")) () (EVar "True")) (arm (PTuple (PCon "TRBracket") (PCon "TRBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBrace") (PCon "TLBrace")) () (EVar "True")) (arm (PTuple (PCon "TRBrace") (PCon "TRBrace")) () (EVar "True")) (arm (PTuple (PCon "TLArray") (PCon "TLArray")) () (EVar "True")) (arm (PTuple (PCon "TRArray") (PCon "TRArray")) () (EVar "True")) (arm (PTuple (PCon "TDotLBrace") (PCon "TDotLBrace")) () (EVar "True")) (arm (PTuple (PCon "TDotStar") (PCon "TDotStar")) () (EVar "True")) (arm (PTuple (PCon "TEllipsis") (PCon "TEllipsis")) () (EVar "True")) (arm (PTuple (PCon "TDotDot") (PCon "TDotDot")) () (EVar "True")) (arm (PTuple (PCon "TDotDotEq") (PCon "TDotDotEq")) () (EVar "True")) (arm (PTuple (PCon "TNewline") (PCon "TNewline")) () (EVar "True")) (arm (PTuple (PCon "TIndent") (PCon "TIndent")) () (EVar "True")) (arm (PTuple (PCon "TDedent") (PCon "TDedent")) () (EVar "True")) (arm (PTuple (PCon "TEof") (PCon "TEof")) () (EVar "True")) (arm (PTuple (PCon "TLexError" (PVar "__a0")) (PCon "TLexError" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig true "tokenToString" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "tokenToString" ((PCon "TInt" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "INT ")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "tokenToString" ((PCon "TFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "FLOAT ")) (EApp (EVar "floatToString") (EVar "f"))))
(DFunDef false "tokenToString" ((PCon "TString" (PVar "s"))) (EBinOp "++" (ELit (LString "STRING ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TChar" (PVar "s"))) (EBinOp "++" (ELit (LString "CHAR ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "True"))) (ELit (LString "BOOL true")))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "False"))) (ELit (LString "BOOL false")))
(DFunDef false "tokenToString" ((PCon "TInterpOpen" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_OPEN ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpMid" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_MID ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpEnd" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_END ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (ELit (LString "UPPER ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "BACKTICK_IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TLet")) (ELit (LString "LET")))
(DFunDef false "tokenToString" ((PCon "TRec")) (ELit (LString "REC")))
(DFunDef false "tokenToString" ((PCon "TWith")) (ELit (LString "WITH")))
(DFunDef false "tokenToString" ((PCon "TMut")) (ELit (LString "MUT")))
(DFunDef false "tokenToString" ((PCon "TIn")) (ELit (LString "IN")))
(DFunDef false "tokenToString" ((PCon "TIf")) (ELit (LString "IF")))
(DFunDef false "tokenToString" ((PCon "TThen")) (ELit (LString "THEN")))
(DFunDef false "tokenToString" ((PCon "TElse")) (ELit (LString "ELSE")))
(DFunDef false "tokenToString" ((PCon "TMatch")) (ELit (LString "MATCH")))
(DFunDef false "tokenToString" ((PCon "TData")) (ELit (LString "DATA")))
(DFunDef false "tokenToString" ((PCon "TRecord")) (ELit (LString "RECORD")))
(DFunDef false "tokenToString" ((PCon "TInterface")) (ELit (LString "INTERFACE")))
(DFunDef false "tokenToString" ((PCon "TDefault")) (ELit (LString "DEFAULT")))
(DFunDef false "tokenToString" ((PCon "TImpl")) (ELit (LString "IMPL")))
(DFunDef false "tokenToString" ((PCon "TImport")) (ELit (LString "IMPORT")))
(DFunDef false "tokenToString" ((PCon "TExport")) (ELit (LString "EXPORT")))
(DFunDef false "tokenToString" ((PCon "TPublic")) (ELit (LString "PUBLIC")))
(DFunDef false "tokenToString" ((PCon "TWhere")) (ELit (LString "WHERE")))
(DFunDef false "tokenToString" ((PCon "TOf")) (ELit (LString "OF")))
(DFunDef false "tokenToString" ((PCon "TRequires")) (ELit (LString "REQUIRES")))
(DFunDef false "tokenToString" ((PCon "TDo")) (ELit (LString "DO")))
(DFunDef false "tokenToString" ((PCon "TAs")) (ELit (LString "AS")))
(DFunDef false "tokenToString" ((PCon "TExtern")) (ELit (LString "EXTERN")))
(DFunDef false "tokenToString" ((PCon "TDeriving")) (ELit (LString "DERIVING")))
(DFunDef false "tokenToString" ((PCon "TType")) (ELit (LString "TYPE")))
(DFunDef false "tokenToString" ((PCon "TNewtype")) (ELit (LString "NEWTYPE")))
(DFunDef false "tokenToString" ((PCon "TProp")) (ELit (LString "PROP")))
(DFunDef false "tokenToString" ((PCon "TTest")) (ELit (LString "TEST")))
(DFunDef false "tokenToString" ((PCon "TBench")) (ELit (LString "BENCH")))
(DFunDef false "tokenToString" ((PCon "TEffect")) (ELit (LString "EFFECT")))
(DFunDef false "tokenToString" ((PCon "TFunction")) (ELit (LString "FUNCTION")))
(DFunDef false "tokenToString" ((PCon "TPlus")) (ELit (LString "PLUS")))
(DFunDef false "tokenToString" ((PCon "TMinus")) (ELit (LString "MINUS")))
(DFunDef false "tokenToString" ((PCon "TMinusTight")) (ELit (LString "MINUS_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TStar")) (ELit (LString "STAR")))
(DFunDef false "tokenToString" ((PCon "TSlash")) (ELit (LString "SLASH")))
(DFunDef false "tokenToString" ((PCon "TSlashEq")) (ELit (LString "SLASHEQ")))
(DFunDef false "tokenToString" ((PCon "TMod")) (ELit (LString "MOD")))
(DFunDef false "tokenToString" ((PCon "TEqEq")) (ELit (LString "EQ_EQ")))
(DFunDef false "tokenToString" ((PCon "TNeq")) (ELit (LString "NEQ")))
(DFunDef false "tokenToString" ((PCon "TLt")) (ELit (LString "LT")))
(DFunDef false "tokenToString" ((PCon "TGt")) (ELit (LString "GT")))
(DFunDef false "tokenToString" ((PCon "TLeq")) (ELit (LString "LEQ")))
(DFunDef false "tokenToString" ((PCon "TGeq")) (ELit (LString "GEQ")))
(DFunDef false "tokenToString" ((PCon "TAnd")) (ELit (LString "AND")))
(DFunDef false "tokenToString" ((PCon "TOr")) (ELit (LString "OR")))
(DFunDef false "tokenToString" ((PCon "TCons")) (ELit (LString "CONS")))
(DFunDef false "tokenToString" ((PCon "TPlusPlus")) (ELit (LString "PLUSPLUS")))
(DFunDef false "tokenToString" ((PCon "TPipeRight")) (ELit (LString "PIPE_RIGHT")))
(DFunDef false "tokenToString" ((PCon "TRCompose")) (ELit (LString "RCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TLCompose")) (ELit (LString "LCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TFatArrow")) (ELit (LString "FAT_ARROW")))
(DFunDef false "tokenToString" ((PCon "TArrow")) (ELit (LString "ARROW")))
(DFunDef false "tokenToString" ((PCon "TLArrow")) (ELit (LString "LARROW")))
(DFunDef false "tokenToString" ((PCon "TAt")) (ELit (LString "AT")))
(DFunDef false "tokenToString" ((PCon "TBang")) (ELit (LString "BANG")))
(DFunDef false "tokenToString" ((PCon "TAsAt")) (ELit (LString "AS_AT")))
(DFunDef false "tokenToString" ((PCon "TEqual")) (ELit (LString "EQUAL")))
(DFunDef false "tokenToString" ((PCon "TColon")) (ELit (LString "COLON")))
(DFunDef false "tokenToString" ((PCon "TColonEq")) (ELit (LString "COLONEQ")))
(DFunDef false "tokenToString" ((PCon "TComma")) (ELit (LString "COMMA")))
(DFunDef false "tokenToString" ((PCon "TDot")) (ELit (LString "DOT")))
(DFunDef false "tokenToString" ((PCon "TPipe")) (ELit (LString "PIPE")))
(DFunDef false "tokenToString" ((PCon "TUnderscore")) (ELit (LString "UNDERSCORE")))
(DFunDef false "tokenToString" ((PCon "TLParen")) (ELit (LString "LPAREN")))
(DFunDef false "tokenToString" ((PCon "TRParen")) (ELit (LString "RPAREN")))
(DFunDef false "tokenToString" ((PCon "TLBracket")) (ELit (LString "LBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBracketTight")) (ELit (LString "LBRACKET_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TRBracket")) (ELit (LString "RBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBrace")) (ELit (LString "LBRACE")))
(DFunDef false "tokenToString" ((PCon "TRBrace")) (ELit (LString "RBRACE")))
(DFunDef false "tokenToString" ((PCon "TLArray")) (ELit (LString "LARRAY")))
(DFunDef false "tokenToString" ((PCon "TRArray")) (ELit (LString "RARRAY")))
(DFunDef false "tokenToString" ((PCon "TDotLBrace")) (ELit (LString "DOT_LBRACE")))
(DFunDef false "tokenToString" ((PCon "TDotStar")) (ELit (LString "DOT_STAR")))
(DFunDef false "tokenToString" ((PCon "TEllipsis")) (ELit (LString "ELLIPSIS")))
(DFunDef false "tokenToString" ((PCon "TDotDot")) (ELit (LString "DOTDOT")))
(DFunDef false "tokenToString" ((PCon "TDotDotEq")) (ELit (LString "DOTDOT_EQ")))
(DFunDef false "tokenToString" ((PCon "TNewline")) (ELit (LString "NEWLINE")))
(DFunDef false "tokenToString" ((PCon "TIndent")) (ELit (LString "INDENT")))
(DFunDef false "tokenToString" ((PCon "TDedent")) (ELit (LString "DEDENT")))
(DFunDef false "tokenToString" ((PCon "TEof")) (ELit (LString "EOF")))
(DFunDef false "tokenToString" ((PCon "TLexError" (PVar "s"))) (EBinOp "++" (ELit (LString "LEX_ERROR ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DTypeSig true "describeToken" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "describeToken" ((PCon "TInt" PWild PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TFloat" PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TString" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TChar" PWild)) (ELit (LString "a character literal")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "True"))) (ELit (LString "`true`")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "False"))) (ELit (LString "`false`")))
(DFunDef false "describeToken" ((PCon "TInterpOpen" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpMid" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpEnd" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TLet")) (ELit (LString "`let`")))
(DFunDef false "describeToken" ((PCon "TRec")) (ELit (LString "`rec`")))
(DFunDef false "describeToken" ((PCon "TWith")) (ELit (LString "`with`")))
(DFunDef false "describeToken" ((PCon "TMut")) (ELit (LString "`mut`")))
(DFunDef false "describeToken" ((PCon "TIn")) (ELit (LString "`in`")))
(DFunDef false "describeToken" ((PCon "TIf")) (ELit (LString "`if`")))
(DFunDef false "describeToken" ((PCon "TThen")) (ELit (LString "`then`")))
(DFunDef false "describeToken" ((PCon "TElse")) (ELit (LString "`else`")))
(DFunDef false "describeToken" ((PCon "TMatch")) (ELit (LString "`match`")))
(DFunDef false "describeToken" ((PCon "TData")) (ELit (LString "`data`")))
(DFunDef false "describeToken" ((PCon "TRecord")) (ELit (LString "`record`")))
(DFunDef false "describeToken" ((PCon "TInterface")) (ELit (LString "`interface`")))
(DFunDef false "describeToken" ((PCon "TDefault")) (ELit (LString "`default`")))
(DFunDef false "describeToken" ((PCon "TImpl")) (ELit (LString "`impl`")))
(DFunDef false "describeToken" ((PCon "TImport")) (ELit (LString "`import`")))
(DFunDef false "describeToken" ((PCon "TExport")) (ELit (LString "`export`")))
(DFunDef false "describeToken" ((PCon "TPublic")) (ELit (LString "`public`")))
(DFunDef false "describeToken" ((PCon "TWhere")) (ELit (LString "`where`")))
(DFunDef false "describeToken" ((PCon "TOf")) (ELit (LString "`of`")))
(DFunDef false "describeToken" ((PCon "TRequires")) (ELit (LString "`requires`")))
(DFunDef false "describeToken" ((PCon "TDo")) (ELit (LString "`do`")))
(DFunDef false "describeToken" ((PCon "TAs")) (ELit (LString "`as`")))
(DFunDef false "describeToken" ((PCon "TExtern")) (ELit (LString "`extern`")))
(DFunDef false "describeToken" ((PCon "TDeriving")) (ELit (LString "`deriving`")))
(DFunDef false "describeToken" ((PCon "TType")) (ELit (LString "`type`")))
(DFunDef false "describeToken" ((PCon "TNewtype")) (ELit (LString "`newtype`")))
(DFunDef false "describeToken" ((PCon "TProp")) (ELit (LString "`prop`")))
(DFunDef false "describeToken" ((PCon "TTest")) (ELit (LString "`test`")))
(DFunDef false "describeToken" ((PCon "TBench")) (ELit (LString "`bench`")))
(DFunDef false "describeToken" ((PCon "TEffect")) (ELit (LString "`effect`")))
(DFunDef false "describeToken" ((PCon "TFunction")) (ELit (LString "`function`")))
(DFunDef false "describeToken" ((PCon "TPlus")) (ELit (LString "`+`")))
(DFunDef false "describeToken" ((PCon "TMinus")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TMinusTight")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TStar")) (ELit (LString "`*`")))
(DFunDef false "describeToken" ((PCon "TSlash")) (ELit (LString "`/`")))
(DFunDef false "describeToken" ((PCon "TSlashEq")) (ELit (LString "`/=`")))
(DFunDef false "describeToken" ((PCon "TMod")) (ELit (LString "`%`")))
(DFunDef false "describeToken" ((PCon "TEqEq")) (ELit (LString "`==`")))
(DFunDef false "describeToken" ((PCon "TNeq")) (ELit (LString "`!=`")))
(DFunDef false "describeToken" ((PCon "TLt")) (ELit (LString "`<`")))
(DFunDef false "describeToken" ((PCon "TGt")) (ELit (LString "`>`")))
(DFunDef false "describeToken" ((PCon "TLeq")) (ELit (LString "`<=`")))
(DFunDef false "describeToken" ((PCon "TGeq")) (ELit (LString "`>=`")))
(DFunDef false "describeToken" ((PCon "TAnd")) (ELit (LString "`&&`")))
(DFunDef false "describeToken" ((PCon "TOr")) (ELit (LString "`||`")))
(DFunDef false "describeToken" ((PCon "TCons")) (ELit (LString "`::`")))
(DFunDef false "describeToken" ((PCon "TPlusPlus")) (ELit (LString "`++`")))
(DFunDef false "describeToken" ((PCon "TPipeRight")) (ELit (LString "`|>`")))
(DFunDef false "describeToken" ((PCon "TRCompose")) (ELit (LString "`>>`")))
(DFunDef false "describeToken" ((PCon "TLCompose")) (ELit (LString "`<<`")))
(DFunDef false "describeToken" ((PCon "TFatArrow")) (ELit (LString "`=>`")))
(DFunDef false "describeToken" ((PCon "TArrow")) (ELit (LString "`->`")))
(DFunDef false "describeToken" ((PCon "TLArrow")) (ELit (LString "`<-`")))
(DFunDef false "describeToken" ((PCon "TAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TBang")) (ELit (LString "`!`")))
(DFunDef false "describeToken" ((PCon "TAsAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TEqual")) (ELit (LString "`=`")))
(DFunDef false "describeToken" ((PCon "TColon")) (ELit (LString "`:`")))
(DFunDef false "describeToken" ((PCon "TColonEq")) (ELit (LString "`:=`")))
(DFunDef false "describeToken" ((PCon "TComma")) (ELit (LString "`,`")))
(DFunDef false "describeToken" ((PCon "TDot")) (ELit (LString "`.`")))
(DFunDef false "describeToken" ((PCon "TPipe")) (ELit (LString "`|`")))
(DFunDef false "describeToken" ((PCon "TUnderscore")) (ELit (LString "`_`")))
(DFunDef false "describeToken" ((PCon "TLParen")) (ELit (LString "`(`")))
(DFunDef false "describeToken" ((PCon "TRParen")) (ELit (LString "`)`")))
(DFunDef false "describeToken" ((PCon "TLBracket")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TLBracketTight")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TRBracket")) (ELit (LString "`]`")))
(DFunDef false "describeToken" ((PCon "TLBrace")) (ELit (LString "`{`")))
(DFunDef false "describeToken" ((PCon "TRBrace")) (ELit (LString "`}`")))
(DFunDef false "describeToken" ((PCon "TLArray")) (ELit (LString "`[|`")))
(DFunDef false "describeToken" ((PCon "TRArray")) (ELit (LString "`|]`")))
(DFunDef false "describeToken" ((PCon "TDotLBrace")) (ELit (LString "`.{`")))
(DFunDef false "describeToken" ((PCon "TDotStar")) (ELit (LString "`.*`")))
(DFunDef false "describeToken" ((PCon "TEllipsis")) (ELit (LString "`...`")))
(DFunDef false "describeToken" ((PCon "TDotDot")) (ELit (LString "`..`")))
(DFunDef false "describeToken" ((PCon "TDotDotEq")) (ELit (LString "`..=`")))
(DFunDef false "describeToken" ((PCon "TNewline")) (ELit (LString "a line break")))
(DFunDef false "describeToken" ((PCon "TIndent")) (ELit (LString "an indent")))
(DFunDef false "describeToken" ((PCon "TDedent")) (ELit (LString "a dedent")))
(DFunDef false "describeToken" ((PCon "TEof")) (ELit (LString "end of input")))
(DFunDef false "describeToken" ((PCon "TLexError" (PVar "s"))) (EVar "s"))
(DData Private "RawTok" () ((variant "RTok" (ConPos (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (variant "RNewline" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RComment" (ConPos (TyCon "Int") (TyCon "String")))) ())
(DTypeSig false "at" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "at" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "is2" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool")))))))
(DFunDef false "is2" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))))
(DTypeSig false "is3" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))))))
(DFunDef false "is3" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "c"))))
(DTypeSig false "substr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substr" ((PVar "src") (PVar "start") (PVar "endp")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "endp") (EVar "start"))) (ELam ((PVar "i")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "start") (EVar "i")))))))
(DTypeSig false "collectNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "collectNoUs" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "substrNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substrNoUs" ((PVar "src") (PVar "start") (PVar "endp")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "start")) (EVar "endp")))))
(DTypeSig false "parseIntFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseIntFrom" ((PVar "src") (PVar "p") (PVar "endp") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (ELit (LInt 48))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "intLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "intLitOverflows" ((PVar "src") (PVar "start") (PVar "endp")) (EBinOp "==" (EApp (EApp (EVar "compareDecMag") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "start")) (EVar "endp"))) (ELit (LString "4611686018427387904"))) (EVar "Gt")))
(DTypeSig false "keywordOrIdent" (TyFun (TyCon "String") (TyCon "Token")))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PLit (LString "with"))) (EVar "TWith"))
(DFunDef false "keywordOrIdent" ((PLit (LString "mut"))) (EVar "TMut"))
(DFunDef false "keywordOrIdent" ((PLit (LString "in"))) (EVar "TIn"))
(DFunDef false "keywordOrIdent" ((PLit (LString "if"))) (EVar "TIf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "then"))) (EVar "TThen"))
(DFunDef false "keywordOrIdent" ((PLit (LString "else"))) (EVar "TElse"))
(DFunDef false "keywordOrIdent" ((PLit (LString "match"))) (EVar "TMatch"))
(DFunDef false "keywordOrIdent" ((PLit (LString "data"))) (EVar "TData"))
(DFunDef false "keywordOrIdent" ((PLit (LString "record"))) (EVar "TRecord"))
(DFunDef false "keywordOrIdent" ((PLit (LString "interface"))) (EVar "TInterface"))
(DFunDef false "keywordOrIdent" ((PLit (LString "default"))) (EVar "TDefault"))
(DFunDef false "keywordOrIdent" ((PLit (LString "impl"))) (EVar "TImpl"))
(DFunDef false "keywordOrIdent" ((PLit (LString "import"))) (EVar "TImport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "export"))) (EVar "TExport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "public"))) (EVar "TPublic"))
(DFunDef false "keywordOrIdent" ((PLit (LString "where"))) (EVar "TWhere"))
(DFunDef false "keywordOrIdent" ((PLit (LString "of"))) (EVar "TOf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "do"))) (EVar "TDo"))
(DFunDef false "keywordOrIdent" ((PLit (LString "as"))) (EVar "TAs"))
(DFunDef false "keywordOrIdent" ((PLit (LString "extern"))) (EVar "TExtern"))
(DFunDef false "keywordOrIdent" ((PLit (LString "requires"))) (EVar "TRequires"))
(DFunDef false "keywordOrIdent" ((PLit (LString "deriving"))) (EVar "TDeriving"))
(DFunDef false "keywordOrIdent" ((PLit (LString "type"))) (EVar "TType"))
(DFunDef false "keywordOrIdent" ((PLit (LString "newtype"))) (EVar "TNewtype"))
(DFunDef false "keywordOrIdent" ((PLit (LString "prop"))) (EVar "TProp"))
(DFunDef false "keywordOrIdent" ((PLit (LString "test"))) (EVar "TTest"))
(DFunDef false "keywordOrIdent" ((PLit (LString "bench"))) (EVar "TBench"))
(DFunDef false "keywordOrIdent" ((PLit (LString "effect"))) (EVar "TEffect"))
(DFunDef false "keywordOrIdent" ((PLit (LString "function"))) (EVar "TFunction"))
(DFunDef false "keywordOrIdent" ((PVar "s")) (EApp (EVar "TIdent") (EVar "s")))
(DTypeSig false "scan" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scan" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">=" (EVar "pos") (EVar "len")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanAt") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanAt" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EIf (EApp (EVar "isSpace") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isNL") (EVar "c")) (EApp (EVar "isCR") (EVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "handleNewline") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EVar "pos"))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "RComment") (EVar "pos")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "e") (ELit (LInt 0))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "unterminated block comment"))) (EBinOp "::" (EApp (EApp (EVar "RComment") (EVar "pos")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id")))))) (EIf (EApp (EVar "isDigit") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanNumber") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "False")) (ELit (LString ""))) (EIf (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LString ""))) (EIf (EApp (EVar "isApos") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanChar") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EApp (EApp (EApp (EApp (EVar "scanLower") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isUpper") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanUpper") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isBacktick") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanBacktick") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOp") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))
(DTypeSig false "skipLineComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipLineComment" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lexErrorTok" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "lexErrorTok" ((PVar "p") (PVar "msg")) (EListLit (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TLexError") (EVar "msg"))) (EVar "p")) (EVar "p"))))
(DTypeSig false "skipBlockComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "skipBlockComment" ((PVar "src") (PVar "len") (PVar "p") (PVar "d")) (EIf (EBinOp "<=" (EVar "d") (ELit (LInt 0))) (EVar "p") (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "}")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "-" (EVar "d") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanLower" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanLower" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EApp (EVar "identToken") (EVar "src")) (EVar "pos")) (EVar "e"))) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))))))
(DTypeSig false "identToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "identToken" ((PVar "src") (PVar "pos") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "_"))) (EBinOp "==" (EBinOp "-" (EVar "e") (EVar "pos")) (ELit (LInt 1)))) (EVar "TUnderscore") (EIf (EVar "otherwise") (EApp (EVar "keywordOrIdent") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanUpper" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanUpper" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TUpper") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))))))
(DTypeSig false "scanBacktick" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanBacktick" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TBacktickIdent") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "e")))) (EVar "pos")) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EVar "depth")) (EVar "id"))))))
(DTypeSig false "btClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "btClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isBacktick") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "digitsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "digitsEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EApp (EVar "isRadixDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "radixKind" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "radixKind" ((PVar "k")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "k") (ELit (LChar "x"))) (EBinOp "==" (EVar "k") (ELit (LChar "b")))) (EBinOp "==" (EVar "k") (ELit (LChar "o")))))
(DTypeSig false "radixBase" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixBase" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixBase" ((PLit (LChar "b"))) (ELit (LInt 2)))
(DFunDef false "radixBase" (PWild) (ELit (LInt 8)))
(DTypeSig false "isRadixDigit" (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))
(DFunDef false "isRadixDigit" ((PLit (LChar "x")) (PVar "c")) (EApp (EVar "isHexDigit") (EVar "c")))
(DFunDef false "isRadixDigit" ((PLit (LChar "b")) (PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "0"))) (EBinOp "==" (EVar "c") (ELit (LChar "1")))))
(DFunDef false "isRadixDigit" (PWild (PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "7")))))
(DTypeSig false "digitVal" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "digitVal" ((PVar "c")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f")))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 87))) (EIf (EVar "otherwise") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 55))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Int"))))))
(DFunDef false "radixEnd" ((PVar "src") (PVar "len") (PVar "p") (PVar "k")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EApp (EVar "isRadixDigit") (EVar "k")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "k")) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseRadix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseRadix" ((PVar "src") (PVar "p") (PVar "endp") (PVar "base") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EBinOp "+" (EBinOp "*" (EVar "acc") (EVar "base")) (EApp (EVar "digitVal") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMaxLen" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLen" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixMaxLen" ((PLit (LChar "b"))) (ELit (LInt 63)))
(DFunDef false "radixMaxLen" (PWild) (ELit (LInt 21)))
(DTypeSig false "radixMaxLead" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLead" ((PLit (LChar "b"))) (ELit (LInt 1)))
(DFunDef false "radixMaxLead" (PWild) (ELit (LInt 4)))
(DTypeSig false "sigRadixDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sigRadixDigits" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0")))) (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "p")) (EVar "endp")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMagOverflows" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "radixMagOverflows" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "radixMagOverflows" ((PCons (PVar "d") (PVar "rest")) (PVar "maxLen") (PVar "maxLead")) (EBlock (DoLet false false (PVar "n") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "rest")))) (DoExpr (EBinOp "||" (EBinOp ">" (EVar "n") (EVar "maxLen")) (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "maxLen")) (EBinOp "||" (EBinOp ">" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LChar "0"))))) (EVar "rest")))))))))
(DTypeSig false "radixLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "radixLitOverflows" ((PVar "src") (PVar "start") (PVar "endp") (PVar "k")) (EApp (EApp (EApp (EVar "radixMagOverflows") (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EVar "start")) (EVar "endp"))) (EApp (EVar "radixMaxLen") (EVar "k"))) (EApp (EVar "radixMaxLead") (EVar "k"))))
(DTypeSig false "scanRadix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanRadix" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "radixTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e")) (EVar "k")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "radixTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))
(DFunDef false "radixTok" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e") (PVar "k") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EVar "radixLitOverflows") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EVar "k")) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "integer literal too large for Int (max magnitude 2^62)"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EApp (EVar "radixBase") (EVar "k"))) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e")) (EVar "depth")) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanNumber" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanNumber" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EVar "scanRadix") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "malformedRadixTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "numFinish") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "pos"))) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isMalformedRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LChar "_")))))
(DTypeSig false "malformedRadixTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "malformedRadixTok" ((PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoLet false false (PVar "digits") (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "malformedRadixErr") (EVar "pos")) (EVar "bad")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EVar "digits")))))
(DTypeSig false "stripLeadingUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripLeadingUs" ((PVar "src") (PVar "p") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_")))) (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "p")) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "malformedRadixErr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok")))))))
(DFunDef false "malformedRadixErr" ((PVar "pos") (PVar "bad") (PVar "prefix") (PVar "digits")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "digits")) (ELit (LInt 0))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: '_' cannot immediately follow the radix prefix '"))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString "', and no digit follows it either")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: '_' cannot immediately follow the radix prefix — write `"))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "digits"))) (ELit (LString "`")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isFloatAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isFloatAt" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp "<" (EBinOp "+" (EVar "e1") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))))
(DTypeSig false "isExpMarker" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExpMarker" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "e"))) (EBinOp "==" (EVar "c") (ELit (LChar "E")))))
(DTypeSig false "expEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "expEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isExpMarker") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EBlock (DoLet false false (PVar "q") (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "+"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-"))))) (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "q") (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "q")))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "q")) (EVar "p")))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "numFinish" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "numFinish" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isFloatAt") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EVar "depth")) (EVar "id")) (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1"))) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedExpDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "malformedExpDotTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "isMalformedTrailingDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EVar "malformedTrailingDotTok") (EVar "src")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "intLitOverflows") (EVar "src")) (EVar "pos")) (EVar "e1")) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "integer literal too large for Int (max magnitude 2^62)"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EVar "pos")) (EVar "e1")) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e1")))) (EVar "pos")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "e1")) (EVar "depth")) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "isMalformedExpDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedExpDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))))
(DTypeSig false "malformedExpDotTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))
(DFunDef false "malformedExpDotTok" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "expE") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "expE"))) (DoLet false false (PVar "good") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))) (ELit (LString "0"))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EVar "expE")))) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: a float needs a digit after the decimal point — write `"))) (EApp (EMethodRef "display") (EVar "good"))) (ELit (LString "`")))))))
(DTypeSig false "isMalformedTrailingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedTrailingDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "dotContinuesAccess") (EVar "src")) (EVar "len")) (EVar "e1")))))
(DTypeSig false "dotContinuesAccess" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "dotContinuesAccess" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EApp (EVar "isUpper") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "_")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "[")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar ".")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "*"))))))
(DTypeSig false "malformedTrailingDotTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "malformedTrailingDotTok" ((PVar "src") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: a float needs a digit after the decimal point — write `"))) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "0`")))))))
(DTypeSig false "floatTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "floatTok" ((PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e2"))) (EVar "depth")) (EVar "id")))))
(DTypeSig false "floatIsFinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "floatIsFinite" ((PVar "f")) (EBinOp "==" (EBinOp "*" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))
(DTypeSig false "floatTokEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "floatTokEnd" ((PVar "src") (PVar "len") (PVar "pos") (PVar "endp") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "fromOption") (ELit (LFloat 0.0))) (EApp (EVar "stringToFloat") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "pos")) (EVar "endp"))))) (DoExpr (EIf (EApp (EVar "floatIsFinite") (EVar "f")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TFloat") (EVar "f"))) (EVar "pos")) (EVar "endp")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "endp")) (EVar "depth")) (EVar "id"))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "float literal out of range (overflows to infinity)")))))))
(DTypeSig false "scanStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))
(DFunDef false "scanStr" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (ELit (LString "unterminated string literal"))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EVar "acc"))) (EVar "startQ")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EVar "id"))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStrEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (ELit (LString "unterminated string literal"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "commonEscDecode" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "commonEscDecode" ((PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EVar "Some") (ELit (LString "\n"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EVar "Some") (ELit (LString "\t"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EVar "Some") (ELit (LString "\r"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EVar "Some") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0)))))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\\"))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\""))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "scanStrEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))))
(DFunDef false "scanStrEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "{"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (ELit (LInt 1)))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "commonEscDecode") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanStr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EBinOp "++" (EVar "acc") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString "invalid escape sequence '\\")) (EApp (EMethodRef "display") (EApp (EVar "charToStr") (EVar "e")))) (ELit (LString "'")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanInterpCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanInterpCont" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (ELit (LInt 0)))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (ELit (LInt 0)))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "scanInterpEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanInterpEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\t")))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\\")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\r")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0))))))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "isTripleAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTripleAt" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "firstNl" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "firstNl" ((PVar "leadingNl") (PVar "acc")) (EBinOp "||" (EBinOp "==" (EVar "acc") (ELit (LString ""))) (EVar "leadingNl")))
(DTypeSig false "maybeStrip" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "maybeStrip" ((PCon "True") (PVar "acc")) (EApp (EVar "stripIndent") (EVar "acc")))
(DFunDef false "maybeStrip" ((PCon "False") (PVar "acc")) (EVar "acc"))
(DTypeSig false "scanTriple" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok")))))))))))
(DFunDef false "scanTriple" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "leadingNl") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EApp (EApp (EVar "maybeStrip") (EVar "leadingNl")) (EVar "acc")))) (EVar "startQ")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id"))) (EIf (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "p")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EApp (EApp (EVar "maybeStrip") (EVar "leadingNl")) (EVar "acc")))) (EVar "startQ")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "depth")) (EVar "id"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EBinOp "++" (EVar "tripleInterpMark") (EVar "acc")))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTripleEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "firstNl") (EVar "leadingNl")) (EVar "acc"))) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\"\"")))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "scanTripleEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))))
(DFunDef false "scanTripleEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "startQ") (PVar "depth") (PVar "id") (PVar "leadingNl") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\t")))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\\")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (ELit (LString "\r")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0))))))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTriple") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "startQ")) (EVar "depth")) (EVar "id")) (EVar "leadingNl")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "scanInterpTripleCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanInterpTripleCont" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (ELit (LInt 0)))) (EIf (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "p")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "depth")) (ELit (LInt 0)))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "acc"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"\"")))) (EIf (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "scanInterpTripleEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanInterpTripleEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "acc") (PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\n")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\t")))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\"")))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\\")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (ELit (LString "\r")))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0))))))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "c")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "stripIndent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripIndent" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stripIndentCs") (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "stripIndentCs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripIndentCs" ((PVar "s") (PVar "cs") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EIf (EBinOp "!=" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n"))) (EVar "s") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n")) (ELit (LString "")))) (DoLet false false (PVar "minInd") (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EVar "lines")) (EVar "indentSentinel")))) (DoExpr (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "lines"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitLines" ((PVar "cs") (PVar "p") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EListLit (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "p")) (ELit (LChar "\n"))) (EBinOp "::" (EVar "acc") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n")) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "cs")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "indentSentinel" (TyCon "Int"))
(DFunDef false "indentSentinel" () (ELit (LInt 1000000000)))
(DTypeSig false "indentOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "indentOf" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "indentOfGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "indentOfGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "indentSentinel") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "i")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minInt" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "a") (EVar "b")))
(DTypeSig false "minIndentGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minIndentGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "minIndentGo" ((PCons (PVar "l") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "minIndentGo") (EVar "rest")) (EApp (EApp (EVar "minInt") (EVar "acc")) (EApp (EVar "indentOf") (EVar "l")))))
(DTypeSig false "normalizeMin" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "normalizeMin" ((PVar "m")) (EIf (EBinOp "==" (EVar "m") (EVar "indentSentinel")) (ELit (LInt 0)) (EVar "m")))
(DTypeSig false "stripLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "stripLines" (PWild (PList)) (EListLit))
(DFunDef false "stripLines" ((PVar "k") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "stripLine") (EVar "k")) (EVar "l")) (EApp (EApp (EVar "stripLines") (EVar "k")) (EVar "rest"))))
(DTypeSig false "stripLine" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripLine" ((PVar "k") (PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (EApp (EApp (EVar "minInt") (EVar "k")) (EVar "n"))) (EVar "n")))))
(DTypeSig false "dropCharsToStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "dropCharsToStr" ((PVar "cs") (PVar "k") (PVar "n")) (EIf (EBinOp ">=" (EVar "k") (EVar "n")) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "cs")) (EVar "k"))) (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "joinNlStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinNlStr" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "xs")))
(DTypeSig false "tripleInterpMark" (TyCon "String"))
(DFunDef false "tripleInterpMark" () (EApp (EVar "charToStr") (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 1))))))
(DTypeSig false "hasTripleInterpMark" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasTripleInterpMark" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (EApp (EApp (EVar "fromOption") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 1)))))))))
(DTypeSig false "dropTripleInterpMark" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTripleInterpMark" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "startsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n")))))))
(DTypeSig false "endsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (ELit (LChar "\n")))))))
(DTypeSig false "computeMinIndent" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "computeMinIndent" ((PVar "joined")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "joined"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n")) (ELit (LString "")))) (EVar "indentSentinel"))))))
(DTypeSig false "dedentGroupSegs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dedentGroupSegs" ((PVar "minInd") (PCons (PVar "openStr") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "openStr"))) (DoLet false false (PVar "openLines") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LString "")))) (DoLet false false (PVar "openOut") (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "openLines")))) (DoExpr (EBinOp "::" (EVar "openOut") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "openStr"))) (EVar "rest"))))))
(DFunDef false "dedentGroupSegs" (PWild (PList)) (EListLit))
(DTypeSig false "dedentRestSegs" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dedentRestSegs" (PWild PWild (PList)) (EListLit))
(DFunDef false "dedentRestSegs" ((PVar "minInd") (PVar "atLineStart") (PCons (PVar "seg") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "seg"))) (DoLet false false (PVar "lines") (EApp (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LString "")))) (DoLet false false (PVar "out") (EApp (EVar "joinNlStr") (EApp (EApp (EApp (EVar "stripFirstAware") (EVar "minInd")) (EVar "atLineStart")) (EVar "lines")))) (DoExpr (EBinOp "::" (EVar "out") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "seg"))) (EVar "rest"))))))
(DTypeSig false "stripFirstAware" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stripFirstAware" (PWild PWild (PList)) (EListLit))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "True") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "stripLine") (EVar "minInd")) (EVar "l")) (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "False") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DTypeSig false "splitInterpGroup" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "splitInterpGroup" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpMid" (PVar "s")) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "s") (EVar "segs")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "s"))) (EVar "mo")) (EVar "me")) (EVar "mid")) (EVar "after")))))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpEnd" (PVar "s")) (PVar "eo") (PVar "ee")) (PVar "rest"))) (ETuple (EListLit (EVar "s")) (EListLit (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "s"))) (EVar "eo")) (EVar "ee"))) (EVar "rest")))
(DFunDef false "splitInterpGroup" ((PCons (PVar "t") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EVar "segs") (EBinOp "::" (EVar "t") (EVar "mid")) (EVar "after")))))
(DTypeSig false "substituteOwn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "substituteOwn" (PWild (PList)) (EListLit))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpMid" PWild) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "v"))) (EVar "mo")) (EVar "me")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpEnd" PWild) (PVar "eo") (PVar "ee")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "v"))) (EVar "eo")) (EVar "ee")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PVar "vals") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EVar "vals")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PList) (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EListLit)) (EVar "rest"))))
(DTypeSig false "dedentTripleInterp" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "dedentTripleInterp" ((PList)) (EListLit))
(DFunDef false "dedentTripleInterp" ((PCons (PCon "RTok" (PCon "TInterpOpen" (PVar "s")) (PVar "so") (PVar "eo")) (PVar "rest"))) (EIf (EApp (EVar "hasTripleInterpMark") (EVar "s")) (EBlock (DoLet false false (PVar "sReal") (EApp (EVar "dropTripleInterpMark") (EVar "s"))) (DoLet false false (PTuple (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dedentTripleGroup") (EVar "sReal")) (EVar "so")) (EVar "eo")) (EVar "rawSegs")) (EVar "midToks")) (EVar "afterEnd")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dedentTripleInterp" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "dedentTripleInterp") (EVar "rest"))))
(DTypeSig false "dedentTripleGroup" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "dedentTripleGroup" ((PVar "sReal") (PVar "so") (PVar "eo") (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EIf (EApp (EVar "startsWithNl") (EVar "sReal")) (EBlock (DoLet false false (PVar "allRaw") (EBinOp "::" (EVar "sReal") (EVar "rawSegs"))) (DoLet false false (PVar "minInd") (EApp (EVar "computeMinIndent") (EApp (EVar "concatAll") (EVar "allRaw")))) (DoExpr (EMatch (EApp (EApp (EVar "dedentGroupSegs") (EVar "minInd")) (EVar "allRaw")) (arm (PCons (PVar "openStr'") (PVar "restVals")) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "openStr'"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EApp (EApp (EVar "substituteOwn") (EVar "restVals")) (EVar "midToks")) (EApp (EVar "dedentTripleInterp") (EVar "afterEnd"))))) (arm (PList) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleInterp") (EVar "afterEnd")))))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleInterp") (EVar "afterEnd")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "concatAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "concatAll" ((PList)) (ELit (LString "")))
(DFunDef false "concatAll" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EVar "x") (EApp (EVar "concatAll") (EVar "xs"))))
(DTypeSig false "charEscDecode" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "charEscDecode" ((PVar "e")) (EIf (EApp (EVar "isApos") (EVar "e")) (EApp (EVar "Some") (ELit (LString "'"))) (EIf (EVar "otherwise") (EApp (EVar "commonEscDecode") (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "scanChar" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EApp (EApp (EApp (EApp (EApp (EVar "readChar") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")))
(DTypeSig false "readChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "readChar" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg")) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "u")))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LChar "{")))) (EApp (EApp (EApp (EApp (EApp (EVar "readCharUnicode") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "escChar") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (ELit (LString "character literal is empty. A character is exactly one codepoint — write `'\\0'` for the NUL character, or use a `\"\"` string for an empty value"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "rawChar") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "charUntermMsg" (TyCon "String"))
(DFunDef false "charUntermMsg" () (ELit (LString "character literal is not terminated. A character is one codepoint between single quotes, as in `'a'` or `'\\n'`")))
(DTypeSig false "escChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "escChar" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id") (PVar "e")) (EMatch (EApp (EVar "charEscDecode") (EVar "e")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString "invalid escape sequence '\\")) (EApp (EMethodRef "display") (EApp (EVar "charToStr") (EVar "e")))) (ELit (LString "'"))))) (arm (PCon "Some" (PVar "s")) () (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EVar "s"))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "depth")) (EVar "id"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg"))))))
(DTypeSig false "rawChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "rawChar" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id")) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "depth")) (EVar "id"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EVar "p"))) (DoExpr (EIf (EBinOp ">=" (EVar "e") (EVar "len")) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg")) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EBinOp "++" (EBinOp "++" (ELit (LString "character literal must be a single codepoint, but `'")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "p")) (EVar "e")))) (ELit (LString "'` has more than one. Use a `\"...\"` string for text, or `'\\u{...}'` for one codepoint by its hex value"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "charClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "charClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscWellFormed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "uniEscWellFormed" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "he") (EVar "s")) (EBinOp "<" (EVar "he") (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))))))
(DTypeSig false "uniHexSigLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniHexSigLen" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0"))) (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "-" (EVar "endp") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscCode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "uniEscCode" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 6))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 16))) (ELit (LInt 0))))))))
(DTypeSig false "uniEscText" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "uniEscText" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1)))))
(DTypeSig false "uniEscChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))))
(DFunDef false "uniEscChar" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cp")) () (EApp (EVar "charFromCode") (EVar "cp")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "uniIsSurrogate" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "uniIsSurrogate" ((PVar "cp")) (EBinOp "&&" (EBinOp ">=" (EVar "cp") (ELit (LInt 55296))) (EBinOp "<=" (EVar "cp") (ELit (LInt 57343)))))
(DTypeSig false "uniEscTermErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))))
(DFunDef false "uniEscTermErr" ((PVar "src") (PVar "len") (PVar "s") (PVar "he")) (EIf (EBinOp ">=" (EVar "he") (EVar "len")) (ELit (LString "unicode escape is not terminated. Expected one to six hex digits (0-9, a-f, A-F) then `}`, but the file ended")) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "_"))) (ELit (LString "unicode escape uses a `_` separator, which is not allowed here. `_` groups digits in integer literals (`1_000`, `0xD_EAD`), but a `\\u{...}` codepoint must be an unbroken run of hex digits — write the digits unbroken, as in `\\u{41}` rather than `\\u{4_1}`")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "he") (EVar "s")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))) (ELit (LString "unicode escape `\\u{}` has no digits. A codepoint needs at least one hex digit — `\\u{41}` is 'A' and `\\u{0}` is NUL")) (EIf (EBinOp "==" (EVar "he") (EVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape is not terminated. Expected one to six hex digits (0-9, a-f, A-F) then `}`, but found `")) (EApp (EMethodRef "display") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he"))))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape is not terminated. Expected `}` after the hex digits, but found `")) (EApp (EMethodRef "display") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he"))))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "uniEscErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "uniEscErr" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "uniEscTermErr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3))))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "Some" (PVar "cp")) ((GBool (EApp (EVar "uniIsSurrogate") (EVar "cp")))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape '")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))) (ELit (LString "' is a UTF-16 surrogate, not a character. Codepoints D800-DFFF only ever encode one half of a surrogate pair and are never valid on their own")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape '")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))) (ELit (LString "' is out of range. A codepoint must be at most 10FFFF"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "readCharUnicode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "readCharUnicode" ((PVar "src") (PVar "len") (PVar "p") (PVar "depth") (PVar "id")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "lexErrorTok") (EVar "p")) (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p")))) (arm (PCon "Some" (PVar "c")) () (EBlock (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "he") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "he") (ELit (LInt 1)))))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EApp (EVar "charToStr") (EVar "c")))) (EVar "p")) (EBinOp "+" (EVar "he") (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "he") (ELit (LInt 2)))) (EVar "depth")) (EVar "id"))) (EApp (EApp (EVar "lexErrorTok") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "charUntermMsg"))))))))
(DTypeSig false "uHexEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uHexEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isHexDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isUnicodeEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "isUnicodeEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "u"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LChar "{")))))
(DTypeSig false "uniEscEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniEscEnd" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1))))
(DTypeSig false "emit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))))))))
(DFunDef false "emit" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "tok") (PVar "length") (PVar "ddelta")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "tok")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EMethodRef "length"))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (EMethodRef "length"))) (EBinOp "+" (EVar "depth") (EVar "ddelta"))) (EVar "id"))))
(DTypeSig false "scanOp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "scanOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEllipsis")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDotEq")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "["))) (ELit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLArray")) (ELit (LInt 2))) (ELit (LInt 1))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRArray")) (ELit (LInt 2))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TFatArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "-"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TCons")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColonEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPlusPlus")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "!"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TNeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "/"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TSlashEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TAnd")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TOr")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipeRight")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotLBrace")) (ELit (LInt 2))) (ELit (LInt 1))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotStar")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDot")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))))))))))))))
(DTypeSig false "singleOp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPlus")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "minusTok") (EVar "src")) (EVar "len")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TStar")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "/"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TSlash")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqual")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColon")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ","))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TComma")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "."))) (EIf (EApp (EApp (EApp (EVar "isMalformedLeadingDot") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "malformedLeadingDotTok") (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDot")) (ELit (LInt 1))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipe")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "("))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLParen")) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ")"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRParen")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "["))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "bracketTok") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRBracket")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EVar "openBrace") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EVar "closeBrace") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "!"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TBang")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "%"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TMod")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "@"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "atToken") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "\\"))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "unexpected '\\'. Medaka lambdas are written 'x => e' (not '\\x -> e')"))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "$"))) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (ELit (LString "Medaka has no '$'. Apply directly 'f x', parenthesize '(f x)', or pipe with '|>'"))))
(DFunDef false "singleOp" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected character '")) (EApp (EMethodRef "display") (EApp (EVar "charToStr") (EVar "c")))) (ELit (LString "'")))))
(DTypeSig false "bracketTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "bracketTok" ((PVar "src") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EVar "TLBracketTight") (EIf (EVar "otherwise") (EVar "TLBracket") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExprEnd" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExprEnd" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ")")))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "\"")))))
(DTypeSig false "isMalformedLeadingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedLeadingDot" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "||" (EBinOp "==" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))))
(DTypeSig false "malformedLeadingDotTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "malformedLeadingDotTok" ((PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "d"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "substr") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "lexErrorTok") (EVar "pos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: a float needs a digit before the decimal point — write `0"))) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`")))))))
(DTypeSig false "atToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "atToken" ((PVar "src") (PVar "pos")) (EIf (EBinOp "<=" (EVar "pos") (ELit (LInt 0))) (EVar "TAt") (EIf (EBinOp "&&" (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1))))) (EApp (EApp (EVar "identStartLower") (EVar "src")) (EApp (EApp (EVar "identRunStart") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EVar "TAsAt") (EIf (EVar "otherwise") (EVar "TAt") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minusTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "minusTok" ((PVar "src") (PVar "len") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isSpace") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EVar "TMinusTight") (EIf (EVar "otherwise") (EVar "TMinus") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "identRunStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identRunStart" ((PVar "src") (PVar "p")) (EIf (EBinOp "<=" (EVar "p") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "p") (ELit (LInt 1))))) (EApp (EApp (EVar "identRunStart") (EVar "src")) (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStartLower" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "identStartLower" ((PVar "src") (PVar "p")) (EBinOp "||" (EApp (EVar "isLower") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_")))))
(DTypeSig false "openBrace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "openBrace" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">" (EVar "id") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "+" (EVar "id") (ELit (LInt 1))))) (EIf (EBinOp "<" (EVar "id") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "-" (EVar "id") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "closeBrace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "closeBrace" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">" (EVar "id") (ELit (LInt 1))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "-" (EVar "id") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "id") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (ELit (LString ""))) (EIf (EBinOp "==" (EVar "id") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scanInterpTripleCont") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (ELit (LString ""))) (EIf (EBinOp "<" (EVar "id") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "+" (EVar "id") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "handleNewline" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))
(DFunDef false "handleNewline" ((PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PTuple (PVar "indent") (PVar "np")) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "afterNl") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EVar "indent")) (EVar "pos")))))
(DTypeSig false "consumeNl" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "consumeNl" ((PVar "src") (PVar "len") (PVar "p") (PVar "indent")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (ETuple (EVar "indent") (EVar "p")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LInt 0))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "indent") (ELit (LInt 1)))) (EIf (EApp (EVar "isTab") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "*" (EBinOp "+" (EBinOp "/" (EVar "indent") (ELit (LInt 8))) (ELit (LInt 1))) (ELit (LInt 8)))) (EIf (EVar "otherwise") (ETuple (EVar "indent") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "afterNl" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok"))))))))))
(DFunDef false "afterNl" ((PVar "src") (PVar "len") (PVar "np") (PVar "depth") (PVar "id") (PVar "indent") (PVar "nlPos")) (EIf (EApp (EApp (EApp (EVar "nextIsComment") (EVar "src")) (EVar "len")) (EVar "np")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isContinuation") (EVar "src")) (EVar "len")) (EVar "np")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "continuationTok") (EVar "src")) (EVar "len")) (EVar "np"))) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "RNewline") (EVar "indent")) (EVar "nlPos")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "nextIsComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextIsComment" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))))))
(DTypeSig false "isContinuation" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isContinuation" ((PVar "src") (PVar "len") (PVar "np")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar ">")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "<")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "&"))) (ELit (LChar "&")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar "|")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "+"))) (ELit (LChar "+")))) (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ":"))) (ELit (LChar ":")))))
(DTypeSig false "continuationTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "continuationTok" ((PVar "src") (PVar "len") (PVar "np")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EVar "TPipeRight") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EVar "TRCompose") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EVar "TLCompose") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EVar "TAnd") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EVar "TOr") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EVar "TPlusPlus") (EIf (EVar "otherwise") (EVar "TCons") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "layout" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "layout" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAll") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layout" ((PCons (PCon "RTok" (PVar "t") (PVar "off") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (ELit (LInt 0)) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClose") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "layout" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "flushClose" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PCons (PVar "f") (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "opener")))
(DTypeSig false "flushCloseGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bracketOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketOpener" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TDotLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" (PWild) (EVar "False"))
(DTypeSig false "bracketCloser" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketCloser" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "bracketCloser" (PWild) (EVar "False"))
(DTypeSig false "isOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpener" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isOpener" (PWild) (EVar "False"))
(DTypeSig false "canEndExpr" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canEndExpr" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInterpEnd" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canEndExpr" (PWild) (EVar "False"))
(DTypeSig false "prevCanEnd" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevCanEnd" ((PCon "Some" (PVar "t"))) (EApp (EVar "canEndExpr") (EVar "t")))
(DFunDef false "prevCanEnd" ((PCon "None")) (EVar "False"))
(DTypeSig false "isTrailingContinuationOp" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMinus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TStar")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TSlash")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMod")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TCons")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TEqEq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TNeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TAnd")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TOr")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPipeRight")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TRCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TBacktickIdent" PWild)) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" (PWild) (EVar "False"))
(DTypeSig false "prevIsTrailingOp" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevIsTrailingOp" ((PCon "Some" (PVar "t"))) (EApp (EVar "isTrailingContinuationOp") (EVar "t")))
(DFunDef false "prevIsTrailingOp" ((PCon "None")) (EVar "False"))
(DTypeSig false "armsHerald" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TDo"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "canStartAtom" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canStartAtom" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TAt")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TInterpOpen" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" (PWild) (EVar "False"))
(DTypeSig false "applyNl" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFrame") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFrame" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PVar "f") (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (ELit (LInt 1)) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTop" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTop" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndent") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndent" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "wouldIndent" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveCont") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "bumpFrame" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bumpFrame" ((PList)) (EListLit))
(DFunDef false "bumpFrame" ((PCons (PVar "f") (PVar "fs"))) (EBinOp "::" (EBinOp "+" (EVar "f") (ELit (LInt 1))) (EVar "fs")))
(DTypeSig false "dropFrame" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "dropFrame" ((PList)) (EListLit))
(DFunDef false "dropFrame" ((PCons (PVar "f") (PVar "fs"))) (EBinOp "::" (EBinOp "-" (EVar "f") (ELit (LInt 1))) (EVar "fs")))
(DTypeSig false "resolveCont" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TThen")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TElse")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedents" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAll" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeAll" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedents" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeDedents" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilter" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TElse") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TThen") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PList)) (EListLit))
(DTypeSig false "stripComments" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "stripComments" ((PList)) (EListLit))
(DFunDef false "stripComments" ((PCons (PCon "RComment" PWild PWild) (PVar "rest"))) (EApp (EVar "stripComments") (EVar "rest")))
(DFunDef false "stripComments" ((PCons (PVar "r") (PVar "rest"))) (EBinOp "::" (EVar "r") (EApp (EVar "stripComments") (EVar "rest"))))
(DTypeSig false "layoutWithOffsets" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsets" ((PVar "src") (PVar "len")) (EApp (EVar "elseFilter") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EApp (EVar "stripComments") (EApp (EVar "dedentTripleInterp") (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))
(DTypeSig false "layoutPairs" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "layoutPairs" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAllPairs") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layoutPairs" ((PCons (PCon "RTok" (PVar "t") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (ELit (LInt 0)) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairs") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "layoutPairs" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "flushClosePairs" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PVar "f") (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "opener")))
(DTypeSig false "flushClosePairsGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "s") (EVar "s")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "s") (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFramePairs") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFramePairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PVar "f") (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (ELit (LInt 1)) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EVar "f") (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTopPairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "wouldIndentPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TThen")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "t") (EVar "TElse")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedentsPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeAllPairs" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedentsPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeDedentsPairs" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilterPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TElse") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TThen") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PList)) (EListLit))
(DTypeSig false "layoutWithOffsetPairs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsetPairs" ((PVar "src") (PVar "len")) (EApp (EVar "elseFilterPairs") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EApp (EVar "stripComments") (EApp (EVar "dedentTripleInterp") (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))
(DTypeSig true "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "tokenize" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))))))
(DTypeSig true "tokenizeWithLines" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithLines" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "lines") (EApp (EApp (EVar "offsetsToLines") (EVar "src")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "pairs")))) (DoExpr (ETuple (EVar "toks") (EVar "lines")))))
(DTypeSig true "tokenizeWithOffsets" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithOffsets" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "offs") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "pairs"))) (DoExpr (ETuple (EVar "toks") (EVar "offs")))))
(DTypeSig true "tokenizeWithOffsetPairs" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "tokenizeWithOffsetPairs" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "layoutWithOffsetPairs") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "t") (PVar "_s") (PVar "_e"))) (EVar "t"))) (EVar "triples"))) (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "t") (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e")))) (EVar "triples"))) (DoExpr (ETuple (EVar "toks") (EVar "pairs")))))
(DTypeSig true "offsetToLineCol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineCol" ((PVar "s") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig true "lineStartsOf" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "lineStartsOf" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EVar "arrayFromList") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (ELit (LInt 0))))))))
(DTypeSig false "lineStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "lineStartsGo" ((PVar "src") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\n"))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "offsetToLineColFast" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineColFast" ((PVar "lineStarts") (PVar "off")) (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "lineStarts")) (EVar "off")) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "lineStarts")) (ELit (LInt 1))))) (DoExpr (ETuple (EBinOp "+" (EVar "idx") (ELit (LInt 1))) (EBinOp "-" (EVar "off") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "lineStarts")))))))
(DTypeSig false "lineStartSearch" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lineStartSearch" ((PVar "arr") (PVar "off") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 1))) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "arr")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "mid")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "lo")) (EBinOp "-" (EVar "mid") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "offsetsToLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "offsetsToLines" ((PVar "src") (PVar "offs")) (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "offs")) (ELit (LInt 0))) (ELit (LInt 1))))
(DTypeSig false "offsetsToLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PList) (PVar "p") (PVar "line")) (EListLit))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PCons (PVar "off") (PVar "rest")) (PVar "p") (PVar "line")) (EMatch (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "off")) (EVar "p")) (EVar "line")) (arm (PTuple (PVar "line2") (PVar "p2")) () (EBinOp "::" (EVar "line2") (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "rest")) (EVar "p2")) (EVar "line2"))))))
(DTypeSig false "advanceLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "advanceLine" ((PVar "src") (PVar "target") (PVar "p") (PVar "line")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EVar "p")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "src"))) (ETuple (EVar "line") (EVar "p")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "src")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Abstract "Comment" () ((variant "Comment" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig true "commentLine" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentLine" ((PCon "Comment" (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "commentCol" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentCol" ((PCon "Comment" PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "commentText" (TyFun (TyCon "Comment") (TyCon "String")))
(DFunDef false "commentText" ((PCon "Comment" PWild PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "posLineColFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posLineColFrom" ((PVar "src") (PVar "target") (PVar "p") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EBinOp "-" (EVar "target") (EVar "lineStart"))) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rawToComments" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "rawToComments" ((PVar "src") (PVar "toks")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "toks")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig false "rawToCommentsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "rawToCommentsGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons (PCon "RComment" (PVar "startPos") (PVar "text")) (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "startPos")) (EVar "p")) (EVar "line")) (EVar "lineStart")) (arm (PTuple (PVar "line2") (PVar "col")) () (EBinOp "::" (EApp (EApp (EApp (EVar "Comment") (EVar "line2")) (EVar "col")) (EVar "text")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "startPos")) (EVar "line2")) (EBinOp "-" (EVar "startPos") (EVar "col")))))))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons PWild (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "p")) (EVar "line")) (EVar "lineStart")))
(DTypeSig true "collectComments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "collectComments" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EApp (EVar "rawToComments") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))))
