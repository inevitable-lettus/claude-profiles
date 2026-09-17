# lib/json.awk
#
# Flattens a JSON document on stdin into one line per scalar leaf:
#
#     <path><TAB><type><TAB><encoded-value>
#
# where path is dotted with array indices in brackets:
#
#     .version              number  1
#     .profiles.work.cli.configDir  string  /Users/me/.claude-work
#     .profiles.work.desktop.args[0]  string  --foo
#
# WHY AWK
# -------
# The alternatives were all worse. `jq` is not installed everywhere (and on
# Linux is often absent from minimal images). `python3` is not guaranteed on
# a bare macOS without Command Line Tools. A hand-rolled bash parser is slow
# and fragile. awk is on every POSIX system, this is a genuine parser rather
# than a pile of regexes, and you can read it.
#
# Bash reads the output with `while IFS=$'\t' read -r path type value`, which
# is why values are encoded: a literal tab or newline inside a JSON string
# would otherwise break the line format. See json_decode() in lib/registry.sh
# for the other half.
#
# ENCODING of the value field:  \\ -> backslash   \t -> tab
#                               \n -> newline     \r -> carriage return
#
# Containers only produce a line when they are EMPTY ("{}" -> type object,
# "[]" -> type array). A non-empty container is represented entirely by the
# leaves underneath it.
#
# LIMITATION, deliberate: a \uXXXX escape above U+007F is a parse error rather
# than being decoded. awk's sprintf("%c") is not portable for multi-byte code
# points, and silently corrupting someone's path is worse than refusing it.
# JSON permits raw UTF-8, and this tool always writes raw UTF-8, so this only
# ever bites on a hand-edited file. The error message says what to do.
#
# Exit status: 0 parsed, 2 malformed input.
# ---------------------------------------------------------------------------

BEGIN {
  # Hex lookup for \u escapes.
  for (i = 0; i <= 9; i++) HEX[i "" ] = i
  HEX["a"] = 10; HEX["b"] = 11; HEX["c"] = 12
  HEX["d"] = 13; HEX["e"] = 14; HEX["f"] = 15
  HEX["A"] = 10; HEX["B"] = 11; HEX["C"] = 12
  HEX["D"] = 13; HEX["E"] = 14; HEX["F"] = 15
}

# Slurp the whole document. Doing this by accumulating lines rather than with
# RS="^$" keeps it working on one-true-awk (the macOS default), where that
# slurp idiom is a gawk extension.
{ doc = doc $0 "\n" }

END {
  s = doc
  slen = length(s)
  pos = 1

  skipws()
  if (pos > slen) { err("empty document") }
  parse_value("")
  skipws()
  if (pos <= slen) { err("trailing content after top-level value") }
}


function err(msg) {
  printf("json.awk: %s (at byte %d)\n", msg, pos) > "/dev/stderr"
  exit 2
}


function skipws(   c) {
  while (pos <= slen) {
    c = substr(s, pos, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") { pos++ } else { return }
  }
}


# Encode a scalar so it survives as a single tab-delimited field.
function encode(v) {
  gsub(/\\/, "\\\\", v)
  gsub(/\t/, "\\t", v)
  gsub(/\n/, "\\n", v)
  gsub(/\r/, "\\r", v)
  return v
}


function emit(path, type, value) {
  # A leaf at the document root has an empty path; give it "." so the field
  # is never empty and bash's read loop stays well-behaved.
  if (path == "") { path = "." }
  printf("%s\t%s\t%s\n", path, type, encode(value))
}


function parse_value(path,   c) {
  skipws()
  if (pos > slen) { err("unexpected end of document") }
  c = substr(s, pos, 1)

  if (c == "{") { parse_object(path);  return }
  if (c == "[") { parse_array(path);   return }
  if (c == "\"") { emit(path, "string", parse_string()); return }
  parse_literal(path)
}


function parse_object(path,   key, c) {
  pos++            # consume {
  skipws()

  if (substr(s, pos, 1) == "}") {
    pos++
    emit(path, "object", "")
    return
  }

  while (1) {
    skipws()
    if (substr(s, pos, 1) != "\"") { err("expected a quoted object key") }
    key = parse_string()

    skipws()
    if (substr(s, pos, 1) != ":") { err("expected ':' after object key") }
    pos++

    parse_value(path "." key)

    skipws()
    c = substr(s, pos, 1)
    if (c == ",") { pos++; continue }
    if (c == "}") { pos++; return }
    err("expected ',' or '}' in object")
  }
}


function parse_array(path,   idx, c) {
  pos++            # consume [
  skipws()

  if (substr(s, pos, 1) == "]") {
    pos++
    emit(path, "array", "0")
    return
  }

  idx = 0
  while (1) {
    parse_value(path "[" idx "]")
    idx++

    skipws()
    c = substr(s, pos, 1)
    if (c == ",") { pos++; continue }
    if (c == "]") { pos++; return }
    err("expected ',' or ']' in array")
  }
}


function parse_string(   out, c, esc, cp) {
  pos++            # consume the opening quote
  out = ""

  while (1) {
    if (pos > slen) { err("unterminated string") }
    c = substr(s, pos, 1)

    if (c == "\"") { pos++; return out }

    if (c == "\\") {
      pos++
      esc = substr(s, pos, 1)
      pos++
      if      (esc == "\"") { out = out "\"" }
      else if (esc == "\\") { out = out "\\" }
      else if (esc == "/")  { out = out "/" }
      else if (esc == "n")  { out = out "\n" }
      else if (esc == "t")  { out = out "\t" }
      else if (esc == "r")  { out = out "\r" }
      else if (esc == "b")  { out = out sprintf("%c", 8) }
      else if (esc == "f")  { out = out sprintf("%c", 12) }
      else if (esc == "u") {
        cp = hex4(substr(s, pos, 4))
        pos += 4
        if (cp > 127) {
          err("\\u escape above U+007F is not supported — write the character literally as UTF-8")
        }
        out = out sprintf("%c", cp)
      }
      else { err("invalid escape \\" esc) }
      continue
    }

    out = out c
    pos++
  }
}


function hex4(h,   i, c, v) {
  if (length(h) != 4) { err("truncated \\u escape") }
  v = 0
  for (i = 1; i <= 4; i++) {
    c = substr(h, i, 1)
    if (!(c in HEX)) { err("invalid hex digit in \\u escape") }
    v = v * 16 + HEX[c]
  }
  return v
}


# true / false / null / number
function parse_literal(path,   start, tok) {
  start = pos
  while (pos <= slen && substr(s, pos, 1) ~ /[-+0-9eE.aeflnrstu]/) { pos++ }
  tok = substr(s, start, pos - start)

  if (tok == "true" || tok == "false") { emit(path, "bool", tok);   return }
  if (tok == "null")                   { emit(path, "null", "");    return }
  if (tok ~ /^-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][-+]?[0-9]+)?$/) {
    emit(path, "number", tok)
    return
  }

  err("not a valid JSON value: '" tok "'")
}
