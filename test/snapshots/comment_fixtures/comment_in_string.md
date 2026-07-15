# META
source_lines=3
stages=COMMENTS
# SOURCE
-- real comment
s = "not -- a comment and not {- block -} either"
t = 2
# COMMENTS
1:0:-- real comment
