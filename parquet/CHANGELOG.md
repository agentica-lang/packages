# Changelog

## [Unreleased]

- Add `parquet`: reads Parquet files in memory, flat columns with plain, dictionary and RLE pages under Snappy or gzip, data pages v1 and v2. A malformed file is a `parquet.malformed` error, a feature it does not read is `parquet.unsupported`. Needs Agentica 0.37.0.
