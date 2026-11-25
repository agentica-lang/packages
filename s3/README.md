# s3

An S3 client for Agentica, for AWS S3, MinIO and rustfs: Signature Version 4 requests, presigned URLs for direct uploads and downloads, objects from memory, a file or a stream, and multipart uploads. It is written in Agentica over `std/http` and the `OpenSSL` builtins.

Add it in a project with an `agentica.toml`:

```sh
agentica add s3 https://github.com/agentica-lang/packages --tag s3-0.1.0 --subdir s3
```

The docs, with examples and the API: <https://www.agentica-lang.com/packages/s3/>.
