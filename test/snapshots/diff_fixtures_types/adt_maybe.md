# META
source_lines=15
stages=TYPES_USER
# SOURCE
safeDiv n d =
  match d
    0 => None
    _ => Some (n / d)

showResult r =
  match r
    None => "error"
    Some x => "ok: \{x}"

main : <IO> Unit
main =
  println (showResult (safeDiv 10 2))
  println (showResult (safeDiv 10 0))
  println (showResult (safeDiv 7 3))
# TYPES_USER
safeDiv : Int -> Int -> Option Int
showResult : Display a => Option a -> String
main : Unit
