# META
source_lines=9
stages=EVAL
# SOURCE
data Box a = Box a

impl Eq (Box a) requires Eq a where
  eq (Box x) (Box y) = x == y

main : <IO> Unit
main =
  println (Box 1 == Box 2)
  println (Box 3 == Box 3)
# EVAL
False
True
