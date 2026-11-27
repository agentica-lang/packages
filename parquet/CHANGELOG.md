# Changelog

## [0.2.0] - 2026-11-27

- **Breaking:** needs Agentica 0.40.0-beta.2: `Binary.read_u32_le`, `read_i32_le` and `read_f32_le` return `UInt32`, `Int32` and `Float32` there, so the package checks and runs on that version and no longer on 0.37.0. Every length read from a file is still checked against the data size, now as an `Int`.

## [0.1.0] - 2026-11-24

- Add `parquet`: reads Parquet files in memory, flat columns with plain, dictionary and RLE pages under Snappy or gzip, data pages v1 and v2. A malformed file is a `parquet.malformed` error, a feature it does not read is `parquet.unsupported`. Needs Agentica 0.37.0.
- Fix empty pages: an empty body is read under every codec, an empty gzip page must be a valid empty stream, and an uncompressed v2 page of another size than its header says is `parquet.malformed`.
