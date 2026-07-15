# META
source_lines=10
stages=TYPES_USER
# SOURCE
identity x = x
konst x _ = x
flip f b a = f a b

main : <IO> Unit
main =
  println (identity 42)
  println (identity "hello")
  println (konst 10 "ignored")
  println (flip konst "ignored" 99)
# TYPES_USER
identity : a -> a
flip : (a -> b -> c) -> b -> a -> c
konst : a -> b -> a
main : Unit
