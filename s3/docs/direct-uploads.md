---
title: Direct uploads
description: Let a browser upload to the bucket with presigned URLs, one request or many parts, while the server never reads the bytes.
weight: 2
---

A direct upload keeps the bytes away from your server. The browser asks the server for a URL, the server signs one and returns it, and the browser sends the file to the bucket. The server holds the credentials, and the browser holds a URL that does one thing for a few minutes.

## One request

Make a URL for the key and send it to the browser, which `PUT`s the file to it:

```agentica {mode="check"}
import S3 from "pkg/s3/s3"

def upload_url(config: S3.Config, key: String) -> Result[String]
  S3.presign_put(config, key, S3.Presign(expires_s: 600))
end
```

```sh
curl -T photo.jpg "$URL"
```

S3 answers with the `ETag` of the object. When the key is not yours to choose, make it on the server (a random id), so a client cannot overwrite another one's file. A single `PUT` can carry up to 5 GiB.

## Many parts

A big file goes in parts, which the browser can send in parallel and retry one by one. The server starts the upload and signs one URL per part:

```agentica {mode="check"}
import S3 from "pkg/s3/s3"

struct Plan
  upload_id: String
  urls: List[String]
end

def plan(client: S3.Client, key: String, parts: Int) -> Result[Plan]
  id = try S3.create_multipart(client, key)
  urls: List[String] = []
  for number in 1..parts
    urls = urls.push(try S3.presign_part(client.config, key, id, number))
  end

  ok(Plan(upload_id: id, urls: urls))
end
```

The browser cuts the file into parts of 5 MiB or more (the last one may be smaller), `PUT`s each to its URL, and keeps the `ETag` of each answer. When all are in, the server completes the upload with the numbers and the ETags that the browser reports:

```agentica {mode="check"}
import S3 from "pkg/s3/s3"

def finish(client: S3.Client, key: String, upload_id: String, etags: List[String]) -> Result[S3.ObjectInfo]
  parts: List[S3.Part] = []
  for index in 0...etags.length
    parts = parts.push(S3.Part(number: index + 1, etag: etags[index]))
  end

  S3.complete_multipart(client, key, upload_id, parts)
end
```

An upload that the browser abandons keeps its parts in the bucket, and they are billed. Keep the id of each upload you start, and `S3.abort_multipart` those that never complete (or set a lifecycle rule on the bucket that aborts incomplete uploads).

## CORS

A browser sends a preflight `OPTIONS` before a cross-origin `PUT`, and it can read the `ETag` of the answer only when the bucket exposes it. The bucket needs a CORS rule for the origin of your app:

```json
[
  {
    "AllowedOrigins": ["https://app.example.com"],
    "AllowedMethods": ["GET", "PUT"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

`aws s3api put-bucket-cors --bucket photos --cors-configuration '{"CORSRules": [...]}'` sets it on AWS S3, MinIO and rustfs.

## Downloads

Redirect the browser to a presigned `GET`, and add `response-content-disposition` to the query so that the file downloads with its own name:

```agentica {mode="check"}
import S3 from "pkg/s3/s3"

def download_url(config: S3.Config, key: String, filename: String) -> Result[String]
  disposition = "attachment; filename=\"#{filename}\""
  query = [S3.Param(name: "response-content-disposition", value: disposition)]
  S3.presign_get(config, key, S3.Presign(expires_s: 60, query: query))
end
```

## Checking an upload

After the browser says it is done, ask S3 what is there before you trust it: `S3.head(client, key)` gives the `size` and the `content_type` that S3 stored, which are the ones to check against a limit, not the ones the browser claimed when it asked for the URL.
