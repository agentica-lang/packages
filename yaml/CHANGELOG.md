# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

CI runs it on Agentica 0.35.0; the minimum stays 0.32.0.

### Changed

- The specs compare parsed `JSON.Value`s with `==` (which ignores the order of keys in 0.35), and still check that `1` and `1.0` differ. The package code is unchanged.

## [0.1.0] - 2026-11-18

Needs Agentica 0.32.0.

### Added

- `YAML.parse` and `YAML.parse_all`: YAML 1.2 text to `JSON.Value`, with the core schema only (any other tag is an error), string keys only, no duplicate keys, errors with a line and a column, and `YAML.Options` limits on the depth, the nodes and bytes that aliases add and the size of the text.
