# META
source_lines=13
stages=TYPES_USER
# SOURCE
greet name = "Hello, " ++ name ++ "!"

repeat n s =
  match n
    0 => ""
    n => s ++ repeat (n - 1) s

main : <IO> Unit
main =
  println (greet "Medaka")
  println (repeat 3 "ab")
  let x = 42
  println "value: \{x}"
# TYPES_USER
greet : String -> String
repeat : Int -> String -> String
main : Unit
