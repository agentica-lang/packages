## An S3 client in Agentica: SigV4 requests, presigned URLs and multipart uploads, for AWS S3, MinIO and rustfs.

import Service from "src/service"
import Multipart from "src/multipart"
import Objects from "src/objects"
import Presigned from "src/presigned"
import Types from "src/types"

export Types.Addressing
export Types.Config
export Types.Client
export Types.Options
export Types.Param
export Types.Presign
export Types.PutOptions
export Types.UploadOptions
export Types.ObjectInfo
export Types.Object
export Types.Part
export Types.INVALID
export Types.PROTOCOL
export Types.HTTP_STATUS
export Types.NO_SUCH_KEY
export Types.NO_SUCH_BUCKET
export Types.NO_SUCH_UPLOAD
export Types.ACCESS_DENIED
export Types.SIGNATURE_DOES_NOT_MATCH
export Service.client
export Service.close
export Objects.put
export Objects.put_file
export Objects.get
export Objects.get_range
export Objects.get_file
export Objects.open
export Objects.head
export Objects.delete
export Multipart.upload_part
export Multipart.list_parts
export Multipart.upload_file

## A URL for a `GET` of `key`, signed for the host of the endpoint. The `query` of the options may carry
## `response-content-disposition` and `response-content-type`.
def presign_get(config: Types.Config, key: String, options: Types.Presign = Types.Presign()) -> Result[String]
  Presigned.url(config, "GET", key, options)
end

## A URL for a `PUT` of `key`. A `headers` entry of the options (`content-type`) is signed, so the client of the URL
## must send it as it is; with none, any header goes.
def presign_put(config: Types.Config, key: String, options: Types.Presign = Types.Presign()) -> Result[String]
  Presigned.url(config, "PUT", key, options)
end

## A URL for a `PUT` of part `number` of a multipart upload, for a browser that uploads the parts itself. The answer
## carries the `ETag` of the part, which `complete_multipart` needs.
def presign_part(
  config: Types.Config,
  key: String,
  upload_id: String,
  number: Int,
  options: Types.Presign = Types.Presign(),
) -> Result[String]
  Presigned.part(config, key, upload_id, number, options)
end

## Starts a multipart upload of `key` and gives its id.
def create_multipart(
  client: Types.Client,
  key: String,
  options: Types.PutOptions = Types.PutOptions(),
) -> Result[String]
  Multipart.create(client, key, options)
end

## Finishes a multipart upload with its `parts`, in ascending order, and gives the `etag` of the object.
def complete_multipart(
  client: Types.Client,
  key: String,
  upload_id: String,
  parts: List[Types.Part],
) -> Result[Types.ObjectInfo]
  Multipart.complete(client, key, upload_id, parts)
end

## Drops a multipart upload and its parts.
def abort_multipart(client: Types.Client, key: String, upload_id: String) -> Result[Void]
  Multipart.abort(client, key, upload_id)
end
