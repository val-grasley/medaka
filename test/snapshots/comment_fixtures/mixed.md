# META
source_lines=9
stages=COMMENTS
# SOURCE
-- header
-- second header line
f x = x + 1  -- trailing on f

{- block before g
   line two -}
g y = y - 1
-- between
h = f 3 {- inline -} + g 4 -- end
# COMMENTS
1:0:-- header
2:0:-- second header line
3:13:-- trailing on f
5:0:{- block before g\n   line two -}
8:0:-- between
9:8:{- inline -}
9:27:-- end
