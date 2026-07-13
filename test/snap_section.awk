# snap_section.awk — print ONE section's body out of a `medaka snapshot` .md file.
#
#   awk -v want=PARSE -f test/snap_section.awk foo.md
#
# Mirrors `parseSnapshot` in compiler/tools/snapshot.mdk EXACTLY, and for the same
# reason: `# SOURCE` is consumed by the exact line count in `# META`
# (`source_lines=N`), NEVER by scanning for the next header.  Medaka is
# indentation-sensitive and `#` is not a comment character, so a fixture may
# legitimately contain a line that reads exactly `# TOKENS`; scanning would
# truncate it.  Every other section IS header-delimited.
BEGIN { cur = ""; sl = 0; skip = 0 }
skip > 0 {
  skip--
  if (cur == want) print
  next
}
/^# (META|SOURCE|TOKENS|PARSE|DESUGAR|MARK|TYPES|CORE_IR|LLVM|WASM|EVAL|CRASH)$/ {
  cur = substr($0, 3)
  if (cur == "SOURCE") skip = sl
  next
}
{
  if (cur == "META" && $0 ~ /^source_lines=/) sl = substr($0, 14) + 0
  if (cur == want) print
}
