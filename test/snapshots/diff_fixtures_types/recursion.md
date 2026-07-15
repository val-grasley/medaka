# META
source_lines=15
stages=TYPES_USER
# SOURCE
factorial n =
  match n
    0 => 1
    n => n * factorial (n - 1)

fib n =
  match n
    0 => 0
    1 => 1
    n => fib (n - 1) + fib (n - 2)

main : <IO> Unit
main =
  println (factorial 10)
  println (fib 10)
# TYPES_USER
factorial : Int -> Int
fib : Int -> Int
main : Unit
