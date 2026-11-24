# Changelog

## [Unreleased]

- Add `parquet`: reads Parquet files in memory, flat columns with plain, dictionary and RLE pages under Snappy or gzip, data pages v1 and v2. A malformed file is a `parquet.malformed` error, a feature it does not read is `parquet.unsupported`. Needs Agentica 0.37.0.
- Fix empty pages: an empty body is read under every codec, an empty gzip page must be a valid empty stream, and an uncompressed v2 page of another size than its header says is `parquet.malformed`.
