# META
source_lines=24
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- Valid character literals: exactly ONE codepoint each (#668). Covers the plain
-- ASCII char, every supported escape (`\n \t \r \0 \\ \' \"` and `\u{..}`), and
-- single MULTI-BYTE codepoints (`é`, `λ`, `😀`) — one codepoint, several UTF-8
-- bytes, all accepted. The char lexer counts codepoints, never bytes.
plainC = 'a'
newlineC = '\n'
tabC = '\t'
returnC = '\r'
nulC = '\0'
backslashC = '\\'
aposC = '\''
quoteC = '\"'
uniC = '\u{41}'
accentC = 'é'
lambdaC = 'λ'
emojiC = '😀'

classify c =
  match c
    'a' => 1
    '\n' => 2
    '\u{41}' => 3
    'é' => 4
    _ => 0
# PARSE
(DFunDef false "plainC" () (ELit (LChar "a")))
(DFunDef false "newlineC" () (ELit (LChar "\n")))
(DFunDef false "tabC" () (ELit (LChar "\t")))
(DFunDef false "returnC" () (ELit (LChar "\r")))
(DFunDef false "nulC" () (ELit (LChar "\0")))
(DFunDef false "backslashC" () (ELit (LChar "\\")))
(DFunDef false "aposC" () (ELit (LChar "'")))
(DFunDef false "quoteC" () (ELit (LChar "\"")))
(DFunDef false "uniC" () (ELit (LChar "A")))
(DFunDef false "accentC" () (ELit (LChar "é")))
(DFunDef false "lambdaC" () (ELit (LChar "λ")))
(DFunDef false "emojiC" () (ELit (LChar "😀")))
(DFunDef false "classify" ((PVar "c")) (EMatch (EVar "c") (arm (PLit (LChar "a")) () (ELit (LInt 1))) (arm (PLit (LChar "\n")) () (ELit (LInt 2))) (arm (PLit (LChar "A")) () (ELit (LInt 3))) (arm (PLit (LChar "é")) () (ELit (LInt 4))) (arm PWild () (ELit (LInt 0)))))
# PRINTER
plainC = 'a'
newlineC = '\n'
tabC = '\t'
returnC = '\r'
nulC = '\0'
backslashC = '\\'
aposC = '\''
quoteC = '"'
uniC = 'A'
accentC = 'é'
lambdaC = 'λ'
emojiC = '😀'
classify c = match c
  'a' => 1
  '\n' => 2
  'A' => 3
  'é' => 4
  _ => 0
# DESUGAR
(DFunDef false "plainC" () (ELit (LChar "a")))
(DFunDef false "newlineC" () (ELit (LChar "\n")))
(DFunDef false "tabC" () (ELit (LChar "\t")))
(DFunDef false "returnC" () (ELit (LChar "\r")))
(DFunDef false "nulC" () (ELit (LChar "\0")))
(DFunDef false "backslashC" () (ELit (LChar "\\")))
(DFunDef false "aposC" () (ELit (LChar "'")))
(DFunDef false "quoteC" () (ELit (LChar "\"")))
(DFunDef false "uniC" () (ELit (LChar "A")))
(DFunDef false "accentC" () (ELit (LChar "é")))
(DFunDef false "lambdaC" () (ELit (LChar "λ")))
(DFunDef false "emojiC" () (ELit (LChar "😀")))
(DFunDef false "classify" ((PVar "c")) (EMatch (EVar "c") (arm (PLit (LChar "a")) () (ELit (LInt 1))) (arm (PLit (LChar "\n")) () (ELit (LInt 2))) (arm (PLit (LChar "A")) () (ELit (LInt 3))) (arm (PLit (LChar "é")) () (ELit (LInt 4))) (arm PWild () (ELit (LInt 0)))))
# MARK
(DFunDef false "plainC" () (ELit (LChar "a")))
(DFunDef false "newlineC" () (ELit (LChar "\n")))
(DFunDef false "tabC" () (ELit (LChar "\t")))
(DFunDef false "returnC" () (ELit (LChar "\r")))
(DFunDef false "nulC" () (ELit (LChar "\0")))
(DFunDef false "backslashC" () (ELit (LChar "\\")))
(DFunDef false "aposC" () (ELit (LChar "'")))
(DFunDef false "quoteC" () (ELit (LChar "\"")))
(DFunDef false "uniC" () (ELit (LChar "A")))
(DFunDef false "accentC" () (ELit (LChar "é")))
(DFunDef false "lambdaC" () (ELit (LChar "λ")))
(DFunDef false "emojiC" () (ELit (LChar "😀")))
(DFunDef false "classify" ((PVar "c")) (EMatch (EVar "c") (arm (PLit (LChar "a")) () (ELit (LInt 1))) (arm (PLit (LChar "\n")) () (ELit (LInt 2))) (arm (PLit (LChar "A")) () (ELit (LInt 3))) (arm (PLit (LChar "é")) () (ELit (LInt 4))) (arm PWild () (ELit (LInt 0)))))
