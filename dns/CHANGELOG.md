# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The codec of RFC 1035: `DNS.encode_query` and `DNS.decode`, with name compression (a pointer must go before its name, so no name reads a byte twice), a name read once per place, and bounded sizes.
