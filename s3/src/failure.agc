## The errors of the package, pure: the refusals before a request and the S3 errors of an answer.

import Types from "types"
import Xml from "xml"

## An `error` of the kind `s3.invalid`.
def invalid[T](message: String) -> Result[T] = error(message, kind: Types.INVALID)

## `ok` for a key that is not empty, else an `error` of the kind `s3.invalid`.
def named(key: String) -> Result[Void]
  return invalid("the key is empty") if key == ""

  ok()
end

## An `error` for an answer with a status of 300 or more: the code, message and request id of the XML `Error` body
## become the kind (`s3.no_such_key`), the text and `details`. An answer with no such body (a `HEAD`, a proxy) gets a
## kind from its status: 404 `s3.no_such_key`, 403 `s3.access_denied`, else `s3.http`.
def refused[T](status: Int, body: Bytes) -> Result[T]
  xml = String.from_bytes(body).unwrap_or("")
  case Xml.text(xml, "Code")
    some(code) -> error(message_of(xml, code), kind: kind_of(code), code: status, details: details_of(xml, code))
    none -> error("s3: status #{status}", kind: kind_of_status(status), code: status)
  end
end

## `NoSuchKey` as `s3.no_such_key`: capitals start a word, a run of them (`SHA256`) is one; anything but letters and
## digits is dropped, and a code with none is `s3.http`.
def kind_of(code: String) -> String
  words = snake(code.split("").select { |c| c.bytes.to_a.all? { |b| alphanumeric?(b) } })
  return Types.HTTP_STATUS if words == ""

  "s3.#{words}"
end

private

def kind_of_status(status: Int) -> String
  return Types.NO_SUCH_KEY if status == 404
  return Types.ACCESS_DENIED if status == 403

  Types.HTTP_STATUS
end

def message_of(xml: String, code: String) -> String
  case Xml.text(xml, "Message")
    some(message) -> "#{code}: #{message}"
    none -> code
  end
end

def details_of(xml: String, code: String) -> Map[String, String]
  details = {"s3_code": code}
  case Xml.text(xml, "RequestId")
    some(id) -> details = details.put("request_id", id)
    none -> nil
  end

  details
end

def alphanumeric?(b: Int) -> Bool
  return true if b >= "A".code and b <= "Z".code
  return true if b >= "a".code and b <= "z".code

  b >= "0".code and b <= "9".code
end

def upper?(c: String) -> Bool = c.bytes.to_a.all? { |b| b >= "A".code and b <= "Z".code }

def snake(chars: List[String]) -> String
  out: List[String] = []
  for i in 0...chars.length
    c = chars[i]
    if (
      upper?(c) and
      i > 0 and
      (not upper?(chars[i - 1]) or (i + 1 < chars.length and not upper?(chars[i + 1]) and not digit?(chars[i + 1])))
    )
      out = out.push("_")
    end

    out = out.push(c.downcase)
  end

  out.join("")
end

def digit?(c: String) -> Bool = c.bytes.to_a.all? { |b| b >= "0".code and b <= "9".code }
