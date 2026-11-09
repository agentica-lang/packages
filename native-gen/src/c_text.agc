## C text (pure): comments, string literals and enums of the generated header.

## One enum of `items`, numbered from 0 in their order.
export def numbered(items: List[String]) -> String
  at = 0
  rows: List[String] = []
  for item in items
    rows = rows.push("#{item} = #{at}")
    at += 1
  end

  return "enum { #{rows.join(", ")} };"
end

## The lines of `parts`, in order.
export def joined(parts: List[List[String]]) -> List[String]
  return parts.flat_map do |part: List[String]| part end
end

## `doc` as a C comment above a declaration; nothing for no doc.
export def doc_comment(doc: String) -> List[String]
  if doc.empty?
    return []
  end

  lines = comment_safe(doc).split("\n")
  last = lines.size - 1
  at = 0
  out: List[String] = []
  for line in lines
    lead = "   "
    if at == 0
      lead = "/* "
    end

    text = "#{lead}#{line}"
    if line.empty?
      text = ""
    end

    if at == last
      text = "#{text} */"
    end

    out = out.push(text)
    at += 1
  end

  return out
end

## `text` with no `*/`, which would end the comment that holds it, no `/*`, which -Wcomment refuses inside one, and no
## `??`, which starts a trigraph (`-std=c11` reads them).
export def comment_safe(text: String) -> String
  return text.replace("*/", "* /").replace("/*", "/ *").replace("??", "? ?")
end

## `text` as a C string literal: a quote, a backslash, a control character and the second `?` of `??` (a trigraph)
## escaped, the control characters in octal, three digits, so the next character never joins the escape.
export def c_string(text: String) -> String
  out: List[String] = []
  previous = ""
  for c in text.split("")
    code = c.code
    if c == "\"" or c == "\\" or (c == "?" and previous == "?")
      out = out.push("\\#{c}")
    elsif code < 32 or code == 127
      out = out.push("\\#{octal(code)}")
    else
      out = out.push(c)
    end

    previous = c
  end

  return "\"#{out.join("")}\""
end

# `code` (0 to 127) in three octal digits.
def octal(code: Int) -> String
  return "#{code / 64}#{code / 8 % 8}#{code % 8}"
end
