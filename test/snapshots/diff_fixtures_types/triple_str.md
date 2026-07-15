# META
source_lines=22
stages=TYPES_USER
# SOURCE
-- Triple-quoted strings: `"""…"""` keeps single/double quotes literal and
-- dedents (strip_indent) when the content opens with a raw newline; `\{…}`
-- interpolates just like a normal string.

inline = """one "quoted" line"""

block = """
  first
    indented
  last
  """

interp name = """
  Hello, \{name}!
  Bye.
  """

main : <IO> Unit
main =
  println inline
  println block
  println (interp "Medaka")
# TYPES_USER
inline : String
block : String
interp : Display a => a -> String
main : Unit
