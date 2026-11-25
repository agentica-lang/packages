# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-25

- Add `s3`: an S3 client for AWS S3, MinIO and rustfs, written in Agentica over `std/http` and the `OpenSSL` builtins. Signature Version 4 in the header and in the query, path-style and virtual-host addressing, a configurable endpoint and region, session tokens, presigned `GET`, `PUT` and part URLs, `put`, `put_file`, `get`, `get_range`, `get_file`, `open`, `head` and `delete`, multipart uploads (`create_multipart`, `upload_part`, `complete_multipart`, `abort_multipart`, `list_parts`) and `upload_file`, which cuts a file into parts. The kind of an error is the S3 error code (`s3.no_such_key`). Needs Agentica 0.35.0.
