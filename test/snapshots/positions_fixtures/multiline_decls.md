# META
source_lines=8
stages=POSITIONS
# SOURCE
add a b =
  let s = a + b
  s

double x =
  x * 2

triple x = x + x + x
# POSITIONS
=== DECLS ===
1:3
5:6
8:8
=== VARIANTS ===
=== LASTLINE ===
8
