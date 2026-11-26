# Changelog

## [0.1.0] - 2026-11-26

- Add `zstd`: a Zstandard (RFC 8878) decoder in pure Agentica. It reads raw, RLE and compressed blocks, concatenated and skippable frames and the XXH64 content checksum, refuses a hostile input with a `zstd.malformed`, `zstd.unsupported` or `zstd.too_large` error, and takes a limit on the output size. Needs Agentica 0.37.0.
