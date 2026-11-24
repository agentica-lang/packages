## Reads one column chunk into its values: its pages in file order, with a dictionary page first when there is one.

import Metadata from "metadata"
import Pages from "pages"
import Plain from "plain"
import Schema from "schema"
import Values from "values"

## The physical kind a column's values are read with.
def kind_of(column: Schema.Column) -> Plain.Kind
  Plain.Kind(physical: column.physical, text: column.text, width: column.width)
end

## How a column chunk is read, checked against the column it belongs to.
def layout_of(column: Schema.Column, chunk: Metadata.Chunk) -> Result[Pages.Layout]
  return malformed("a chunk of column #{column.name} with another physical type") if chunk.physical != column.physical
  if chunk.path.size != 1 or chunk.path[0] != column.name
    return malformed("a chunk that is not of column #{column.name}")
  end

  ok(Pages.Layout(kind: kind_of(column), max_level: Schema.max_level(column), codec: chunk.codec))
end

## The values of one column chunk: one entry per row, nulls included.
def chunk_values(data: Bytes, chunk: Metadata.Chunk, layout: Pages.Layout) -> Result[Values.Values]
  if chunk.start < 0 or chunk.start > data.size or chunk.size < 0 or chunk.size > data.size - chunk.start
    return malformed("a column chunk past the end of the file")
  end

  end_of_chunk = chunk.start + chunk.size
  acc = Plain.empty(layout.kind)
  dictionary: Optional[Values.Values] = none
  at = chunk.start
  seen = 0
  while seen < chunk.count
    header = try Pages.read_header(data, at)
    body_end = header.start + header.compressed
    return malformed("a page of #{header.compressed} bytes past its column chunk") if body_end > end_of_chunk

    raw = data.slice(header.start, header.compressed)
    at = body_end
    if header.kind == Pages.DICTIONARY_PAGE
      expanded = try Pages.expand(layout.codec, raw, header.size)
      words = try Pages.dictionary_values(layout.kind, header, expanded)
      dictionary = some(words)
    else
      if header.count > chunk.count - seen
        return malformed("#{header.count} values past the #{chunk.count} of a column chunk")
      end

      page = try Pages.page_values(header, raw, layout, dictionary)
      acc = try Values.join(acc, page)
      seen = seen + header.count
    end
  end

  if Values.size(acc) != chunk.count
    return malformed("a column chunk of #{Values.size(acc)} values, not #{chunk.count}")
  end

  ok(acc)
end

private

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")
