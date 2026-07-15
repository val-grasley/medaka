# META
source_lines=20
stages=TYPES_USER
# SOURCE
data Inv = { shared : Int }

data Wat = { shared : String }

invShared : Inv -> Int
invShared a = a.shared

watShared : Wat -> String
watShared b = b.shared

charAt : String -> Char
charAt s = s.[0]

main : <IO> Unit
main =
  let i = Inv { shared = 7 }
  let w = Wat { shared = "hi" }
  println (invShared i)
  println (watShared w)
  println (charAt "abc")
# TYPES_USER
invShared : Inv -> Int
watShared : Wat -> String
charAt : String -> Char
main : Unit
