# META
source_lines=8
stages=POSITIONS
# SOURCE
data Color = Red | Green | Blue

data Shape
  = Circle Int
  | Rect Int Int
  | Tri Int Int Int

data Maybe a = Nothing | Just a
# POSITIONS
=== DECLS ===
1:1
3:6
8:8
=== VARIANTS ===
1
1
1
4
5
6
8
8
=== LASTLINE ===
8
