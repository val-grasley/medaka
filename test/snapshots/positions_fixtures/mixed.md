# META
source_lines=18
stages=POSITIONS
# SOURCE
data Expr
  = Lit Int
  | Add Expr Expr
  | Mul Expr Expr

eval e =
  match e
    Lit n => n
    Add a b => eval a + eval b
    Mul a b => eval a * eval b

data Pair a b = Pair a b

fst p =
  match p
    Pair a _ => a

main = eval (Add (Lit 1) (Mul (Lit 2) (Lit 3)))
# POSITIONS
=== DECLS ===
1:4
6:10
12:12
14:16
18:18
=== VARIANTS ===
2
3
4
12
=== LASTLINE ===
18
