# META
source_lines=4
stages=TYPES
diagnostics=TYPES
# SOURCE
data Pt = { x : Int }

f r = match r
  Pt { x = a, y = b } => a + b
# TYPES
TYPE ERROR: Field 'y' does not belong to record 'Pt'
