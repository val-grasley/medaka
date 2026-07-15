# META
source_lines=3
stages=TYPES
diagnostics=TYPES
# SOURCE
f a =
  x <- a
  x
# TYPES
TYPE ERROR: `<-` bind is only valid inside a `do` block. For IO sequencing use a bare indented block without `<-`
