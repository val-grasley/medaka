# META
source_lines=7
stages=TYPES
# SOURCE
-- range patterns in match arms: int (1..9) and char ('a'..='z')
classifyInt n = match n
  1..9 => "digit"
  _ => "other"
isLower c = match c
  'a'..='z' => True
  _ => False
# TYPES
classifyInt : Int -> String
isLower : Char -> Bool
