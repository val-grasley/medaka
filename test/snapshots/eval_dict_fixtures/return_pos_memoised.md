# META
source_lines=27
stages=EVAL
# SOURCE
-- TYPECHECK-AUDIT C6: a point-free (nullary) RETURN-POSITION impl method
-- (`theUnit : a`, no discriminating argument) referenced twice at the same
-- concrete type.  The OCaml oracle evaluates the impl body once (eagerly, at
-- binding time); the self-hosted eval used to re-force the un-memoised inner
-- thunk on every occurrence via stripBody, duplicating the body's side effect
-- (`[eval]` printed per reference).  With the C6 memoisation the body runs once,
-- so both print `[eval] XX` — `[eval]` exactly once — byte-identical.
interface HasUnit a where
  theUnit : a

data Box = Box String

impl HasUnit Box where
  theUnit =
    let _ = putStr "[eval] "
    Box "X"

unBox : Box -> String
unBox (Box s) = s

label : Box -> String
label _ =
  let a = unBox (theUnit : Box)
  let b = unBox (theUnit : Box)
  a ++ b

main = putStrLn (label (Box "ignored"))
# EVAL
[eval] XX
