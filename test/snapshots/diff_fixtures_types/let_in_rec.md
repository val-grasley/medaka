# META
source_lines=11
stages=TYPES_USER
# SOURCE
-- T2: inline `let … in` recursive function binding.  The RHS references `go`
-- itself, so the typechecker must pre-bind `go` (placeholder) before inferring
-- the body and generalize after (a function is a value).  Historically the
-- inline `ELet` arm dropped the is_fun flag and panicked `unbound variable: go`.
countdown : Int -> Int
countdown start = let go n = if n == 0 then 0 else go (n - 1) in go start

main : <IO> Unit
main =
  println (countdown 5)
  println (countdown 0)
# TYPES_USER
countdown : Int -> Int
main : Unit
