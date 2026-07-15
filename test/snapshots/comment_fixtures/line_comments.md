# META
source_lines=5
stages=COMMENTS
# SOURCE
-- top of file
x = 1
-- standalone before y
y = 2
z = 3 -- trailing
# COMMENTS
1:0:-- top of file
3:0:-- standalone before y
5:6:-- trailing
