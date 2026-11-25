## The little XML that S3 speaks, pure: the elements of an answer by name and the escaping of a request body. S3 uses
## no attributes and no mixed content in the elements read here, so a search by tag name is enough.

## The text of the first `<tag>` of `xml`, unescaped, or `none`.
def text(xml: String, tag: String) -> Optional[String]
  pieces = xml.split("<#{tag}>")
  return none if pieces.length < 2

  inner(pieces[1], tag).map { |value| unescape(value) }
end

## The inside of every `<tag>` of `xml`, in order.
def elements(xml: String, tag: String) -> List[String]
  found: List[String] = []
  for piece in xml.split("<#{tag}>").drop(1)
    case inner(piece, tag)
      some(value) -> found = found.push(value)
      none -> nil
    end
  end

  found
end

def escape(text: String) -> String
  text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
end

private

def inner(piece: String, tag: String) -> Optional[String]
  case piece.index_of("</#{tag}>")
    some(end_at) -> some(piece.slice(0, end_at))
    none -> none
  end
end

def unescape(text: String) -> String
  text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
end
