# META
source_lines=4
stages=COMMENTS
# SOURCE
-- leading on a
a = 10  -- trailing on a
-- leading on b
b = 20
# COMMENTS
1:0:-- leading on a
2:8:-- trailing on a
3:0:-- leading on b
