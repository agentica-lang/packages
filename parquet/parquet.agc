## Reads Parquet files in memory: the schema and the row count of a file, and its columns or its rows. A malformed file
## is the error kind `parquet.malformed`; a feature this package does not read is `parquet.unsupported`.

import Binary from "std/binary"
import Metadata from "src/metadata"
import Plain from "src/plain"
import Reader from "src/reader"
import Schema from "src/schema"
import Vals from "src/values"

export Vals.Values

## The physical kind of a column, as a value a caller can match on. `FixedBinary` carries the length of each value.
enum Kind
  Boolean
  Int32
  Int64
  Float
  Double
  String
  Binary
  FixedBinary(Int)
end

## One column as the schema names it: its name, its kind and whether it may be null.
struct Field
  name: String
  kind: Kind
  nullable: Bool
end

## An open file: its bytes, its footer and the columns of its flat schema.
struct Table
  data: Bytes
  meta: Metadata.Meta
  columns: List[Schema.Column]
end

## Opens a file from its bytes and checks its footer and its row groups. Pages are read when a column or the rows are asked for.
def open(data: Bytes) -> Result[Table]
  return malformed("a file of #{data.size} bytes is too short") if data.size < MIN_SIZE

  magic_bad = data.slice(0, 4) != MAGIC or data.slice(data.size - 4, 4) != MAGIC
  return malformed("no PAR1 magic at the start and the end") if magic_bad

  length = try Binary.read_u32_le(data, data.size - 8)
  return malformed("a footer of #{length} bytes in a file of #{data.size}") if length > data.size - MIN_SIZE

  meta = try Metadata.read_meta(data.slice(data.size - 8 - length, length))
  columns = try Schema.columns(meta.elements)
  if group_rows(meta.groups) != meta.rows
    return malformed("the row groups hold #{group_rows(meta.groups)} rows, the footer #{meta.rows}")
  end

  for group in meta.groups
    if group.chunks.size != columns.size
      return malformed("a row group of #{group.chunks.size} chunks for #{columns.size} columns")
    end
  end

  ok(Table(data: data, meta: meta, columns: columns))
end

## The number of rows in the file.
def row_count(file: Table) -> Int = file.meta.rows

## The columns of the file, in schema order.
def schema(file: Table) -> List[Field]
  fields: List[Field] = []
  for col in file.columns
    fields = fields.push(Field(name: col.name, kind: field_kind(col), nullable: col.nullable))
  end

  fields
end

## The values of the column `name`, through the first `limit` rows when a limit is given.
def column(file: Table, name: String, limit: Optional[Int] = none) -> Result[Vals.Values]
  return invalid("a negative limit") if negative(limit)

  index = try column_index(file, name)
  read_column(file, index, limit)
end

## The rows of the file as JSON objects keyed by column name, through the first `limit` rows when a limit is given.
## Binary values are lowercase hex text, and NaN and infinite floats are null; `column` keeps the exact values.
def rows(file: Table, limit: Optional[Int] = none) -> Result[List[Map[String, JSON.Value]]]
  return invalid("a negative limit") if negative(limit)

  cells_of: List[List[JSON.Value]] = []
  for index in 0...file.columns.size
    values = try read_column(file, index, limit)
    cells_of = cells_of.push(json_cells(values))
  end

  count = 0
  if cells_of.size > 0
    count = cells_of[0].size
  end

  out: List[Map[String, JSON.Value]] = []
  for r in 0...count
    row: Map[String, JSON.Value] = {}
    for index in 0...file.columns.size
      row = row.put(file.columns[index].name, cells_of[index][r])
    end

    out = out.push(row)
  end

  ok(out)
end

private

MAGIC = "PAR1".bytes
MIN_SIZE = 12
MAX_FINITE = Float.from_bits(9218868437227405311)

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def invalid[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.invalid")

def negative(limit: Optional[Int]) -> Bool
  case limit
    some(n) -> n < 0
    none -> false
  end
end

def group_rows(groups: List[Metadata.Group]) -> Int
  total = 0
  for group in groups
    total = total + group.rows
  end

  total
end

def column_index(file: Table, name: String) -> Result[Int]
  for index in 0...file.columns.size
    return ok(index) if file.columns[index].name == name
  end

  invalid("no column named #{name}")
end

def read_column(file: Table, index: Int, limit: Optional[Int]) -> Result[Vals.Values]
  col = file.columns[index]
  acc = Plain.empty(Reader.kind_of(col))
  for group in file.meta.groups
    return ok(clip(acc, limit)) if reached(limit, Vals.size(acc))

    chunk = group.chunks[index]
    layout = try Reader.layout_of(col, chunk)
    values = try Reader.chunk_values(file.data, chunk, layout)
    if Vals.size(values) != group.rows
      return malformed("a row group of #{group.rows} rows holds #{Vals.size(values)} values")
    end

    acc = try Vals.join(acc, values)
  end

  ok(clip(acc, limit))
end

def reached(limit: Optional[Int], have: Int) -> Bool
  case limit
    some(n) -> have >= n
    none -> false
  end
end

def clip(values: Vals.Values, limit: Optional[Int]) -> Vals.Values
  case limit
    some(n) -> Vals.take(values, n)
    none -> values
  end
end

def field_kind(col: Schema.Column) -> Kind
  if col.physical == Plain.BOOLEAN
    Kind.Boolean
  elsif col.physical == Plain.INT32
    Kind.Int32
  elsif col.physical == Plain.INT64
    Kind.Int64
  elsif col.physical == Plain.FLOAT
    Kind.Float
  elsif col.physical == Plain.DOUBLE
    Kind.Double
  elsif col.text
    Kind.String
  elsif col.physical == Plain.FIXED_LEN_BYTE_ARRAY
    Kind.FixedBinary(col.width)
  else
    Kind.Binary
  end
end

def json_cells(values: Vals.Values) -> List[JSON.Value]
  case values
    Vals.Values.Booleans(xs) -> cells(xs, ->(b) { JSON.from(b) })
    Vals.Values.Integers(xs) -> cells(xs, ->(i) { JSON.from(i) })
    Vals.Values.Floats(xs) -> cells(xs, ->(f) { float_json(f) })
    Vals.Values.Texts(xs) -> cells(xs, ->(s) { JSON.from(s) })
    Vals.Values.Blobs(xs) -> cells(xs, ->(b) { JSON.from(OpenSSL.Digest.hexencode(b)) })
  end
end

def cells[T](xs: List[Optional[T]], convert: Fn[T, JSON.Value]) -> List[JSON.Value]
  out: List[JSON.Value] = []
  for x in xs
    out = out.push(cell(x, convert))
  end

  out
end

def cell[T](x: Optional[T], convert: Fn[T, JSON.Value]) -> JSON.Value
  case x
    some(v) -> convert.call(v)
    none -> JSON.null()
  end
end

def float_json(f: Float) -> JSON.Value
  return JSON.null() if f != f or f > MAX_FINITE or f < 0.0 - MAX_FINITE

  JSON.from(f)
end
