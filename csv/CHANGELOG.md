# Changelog

## [Unreleased]

- Make `parse`, `feed` and `encode` faster: a line with no quote is cut with the native `split`, and `encode` checks fields with native calls. The rows and errors are the same.

## [0.1.0] - 2026-11-25

- Add `csv`: reads and writes CSV (RFC 4180) in pure Agentica, as rows of lists or maps, with a chosen separator, a reader that takes the text in chunks, and an error with its line for a malformed file. Needs Agentica 0.37.0.
