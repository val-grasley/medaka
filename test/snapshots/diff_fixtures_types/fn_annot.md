# META
source_lines=10
stages=TYPES_USER
# SOURCE
double : Int -> Int
double x = x * 2

greet : String -> String
greet name = "Hello, " ++ name ++ "!"

main : <IO> Unit
main =
  println (double 21)
  println (greet "world")
# TYPES_USER
double : Int -> Int
greet : String -> String
main : Unit
