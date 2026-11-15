# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.32.0.

### Added

- `YAML.parse` and `YAML.parse_all`: YAML 1.2 text to `JSON.Value`, with the core schema only (any other tag is an error), string keys only, no duplicate keys, errors with a line and a column, and `YAML.Options` limits on the depth, the nodes that aliases add and the size of the text.
