# META
source_lines=4
stages=TYPES_USER
# SOURCE
wrap x y = x
  :: y

main = println (wrap 1 [2, 3])
# TYPES_USER
wrap : a -> List a -> List a
main : Unit
