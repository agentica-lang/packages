---
title: parquet
description: Reads Parquet files in pure Agentica. The schema, the row count, and the columns or the rows of a file, with plain, dictionary and RLE pages under Snappy or gzip.
---

`parquet` reads [Parquet](https://parquet.apache.org/docs/file-format/) files that are already in memory. It is pure Agentica and does no I/O: read the file with `File.read_bytes` (or fetch it, or take it from an archive) and give the bytes to `Parquet.open`. It reads flat tables: one value per row in each column.

## Install

Needs Agentica 0.37.0. Once the first release is tagged, add it to a project with an `agentica.toml`:

```sh
agentica add parquet https://github.com/agentica-lang/packages --tag parquet-0.1.0 --subdir parquet
```

The dependency entry is:

```toml
parquet = { git = "https://github.com/agentica-lang/packages", tag = "parquet-0.1.0", subdir = "parquet" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/parquet/CHANGELOG.md).

## What it reads

- Flat columns of the physical types boolean, int32, int64, float, double, byte array and fixed-length byte array. A byte array that the schema marks as UTF-8 is a `String`.
- The PLAIN, PLAIN_DICTIONARY and RLE_DICTIONARY encodings, data pages v1 and v2, and dictionary pages.
- The codecs none, Snappy (with the `snappy` package) and gzip, with pages of up to 256 MiB once expanded.
- Several row groups, and several pages in a column chunk.
- Logical types are read as their physical values, except UINT_32, which is read unsigned and reported as `Int64`. A DECIMAL is its raw integer or bytes, and a DATE or a TIMESTAMP is its integer, so a caller applies the scale or the unit. A UINT_64 column is `parquet.unsupported`, since an `Int` is signed.

What it does not read is an error of kind `parquet.unsupported`: nested or repeated columns, INT96 columns, the ZSTD, LZ4 and Brotli codecs, and the DELTA encodings. `open` refuses a nested, UINT_64 or INT96 column, and a codec or an encoding is refused when its column is read.

## Errors

- `parquet.malformed`: the bytes are not a Parquet file, or a size, an offset or a count in them lies. Every size is checked against the bytes before it is used, so a hostile file is an error and never a crash. Without a `limit` the memory a read uses grows with the number of rows the file claims, so cap the size of the file you accept, and pass a `limit` to read only the first pages of each column.
- `parquet.unsupported`: a feature listed above.
- `parquet.invalid`: a negative limit or a column the file does not have.

## Example

```agentica
import Parquet from "pkg/parquet/parquet"

def main() -> Void
  handle = File.open("../specs/fixtures/plain_one.parquet").unwrap!
  file = Parquet.open(File.read_bytes(handle, 1048576).unwrap!).unwrap!
  IO.puts("#{Parquet.row_count(file)} rows")
  for field in Parquet.schema(file)
    IO.puts("#{field.name} nullable: #{field.nullable}")
  end

  rows = Parquet.rows(file, some(2)).unwrap!
  for row in rows
    IO.puts(JSON.encode(row))
  end
end
```

```output
6 rows
v nullable: true
{"v":5}
{"v":6}
```

## API

### `Parquet.open(data: Bytes) -> Result[Table]`

Checks the magic, the footer, the schema and the row groups of a file, and returns a `Table`. It reads no page: the pages are read when a column or the rows are asked for. A file that is not Parquet is a `parquet.malformed` error, and one with nested columns or an INT96 column is `parquet.unsupported`.

```agentica
import Parquet from "pkg/parquet/parquet"

def main() -> Void
  case Parquet.open("not a parquet file".bytes)
    ok(_) -> IO.puts("read")
    error(e) -> IO.puts(e.kind)
  end
end
```

```output
parquet.malformed
```

### `Parquet.row_count(file: Table) -> Int`

The number of rows in the file, from its footer.

```agentica
import Parquet from "pkg/parquet/parquet"

def main() -> Void
  handle = File.open("../specs/fixtures/row_groups.parquet").unwrap!
  file = Parquet.open(File.read_bytes(handle, 1048576).unwrap!).unwrap!
  IO.puts("#{Parquet.row_count(file)}")
end
```

```output
7
```

### `Parquet.schema(file: Table) -> List[Field]`

The columns in the order of the file. A `Field` has the `name` of the column, its `kind` and `nullable`, which is true for an optional column.

```agentica
import Parquet from "pkg/parquet/parquet"

def main() -> Void
  handle = File.open("../specs/fixtures/row_groups.parquet").unwrap!
  file = Parquet.open(File.read_bytes(handle, 1048576).unwrap!).unwrap!
  for field in Parquet.schema(file)
    case field.kind
      Parquet.Kind.Int64 -> IO.puts("#{field.name}: Int64")
      Parquet.Kind.String -> IO.puts("#{field.name}: String")
      _ -> IO.puts("#{field.name}: other")
    end
  end
end
```

```output
n: Int64
s: String
```

### `Parquet.Kind`

The physical kind of a column: `Boolean`, `Int32`, `Int64`, `Float`, `Double`, `String` (a UTF-8 byte array), `Binary` (any other byte array) and `FixedBinary(size)`.

### `Parquet.Values`

The values of a column, one case for each way of holding them. Each is a list of optionals, `none` is a null, and the list has one entry for each row.

- `Booleans(List[Optional[Bool]])` for `Boolean`.
- `Integers(List[Optional[Int]])` for `Int32` and `Int64`.
- `Floats(List[Optional[Float]])` for `Float` and `Double`. A `Float` column holds the exact 32-bit values as doubles.
- `Texts(List[Optional[String]])` for `String`.
- `Blobs(List[Optional[Bytes]])` for `Binary` and `FixedBinary`.

### `Parquet.column(file: Table, name: String, limit: Optional[Int] = none) -> Result[Values]`

The values of the column `name`, in file order and through the first `limit` rows when a limit is given (the pages after those rows are not read, and the result is cut to the limit). An unknown name or a negative limit is a `parquet.invalid` error. The values are exact: NaN and the infinities stay floats.

```agentica
import Parquet from "pkg/parquet/parquet"

def main() -> Void
  handle = File.open("../specs/fixtures/plain_one.parquet").unwrap!
  file = Parquet.open(File.read_bytes(handle, 1048576).unwrap!).unwrap!
  case Parquet.column(file, "v", some(3))
    ok(Parquet.Values.Integers(numbers)) -> IO.puts("#{numbers}")
    ok(_) -> IO.puts("other values")
    error(e) -> IO.puts(e.kind)
  end

  case Parquet.column(file, "w")
    ok(_) -> IO.puts("read")
    error(e) -> IO.puts(e.kind)
  end
end
```

```output
[some(5), some(6), some(7)]
parquet.invalid
```

### `Parquet.rows(file: Table, limit: Optional[Int] = none) -> Result[List[Map[String, JSON.Value]]]`

The rows as maps from the name of a column to a JSON value, through the first `limit` rows when a limit is given. Binary values are lowercase hex text, and NaN and the infinities are `null`, since JSON has no such numbers. Use `column` when you need them exactly.

```agentica
import Parquet from "pkg/parquet/parquet"

def main() -> Void
  handle = File.open("../specs/fixtures/row_groups.parquet").unwrap!
  file = Parquet.open(File.read_bytes(handle, 1048576).unwrap!).unwrap!
  for row in Parquet.rows(file, some(4)).unwrap!
    IO.puts(JSON.encode(row))
  end
end
```

```output
{"n":1,"s":"a"}
{"n":null,"s":"b"}
{"n":3,"s":null}
{"n":4,"s":"d"}
```
