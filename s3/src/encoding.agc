## The pure text of SigV4: percent-encoding, hex and the two forms of a date.

import Failure from "failure"

## Encodes a query name or value, or one path segment: everything but `A-Z a-z 0-9 - . _ ~` becomes `%XX` in capitals.
def component(text: String) -> String
  encoded = Bytes.build do |out|
    for byte in text.bytes
      if unreserved?(byte)
        out.write(Bytes.from_list([byte]).unwrap!)
      else
        out.write("%#{HEX_DIGITS.slice(byte / 16, 1)}#{HEX_DIGITS.slice(byte % 16, 1)}")
      end
    end
  end

  String.from_bytes(encoded).unwrap!
end

## Encodes a path: each segment as `component`, the slashes kept.
def path(text: String) -> String = text.split("/").map { |segment| component(segment) }.join("/")

## The date of a time as SigV4 writes it in `X-Amz-Date`: `20130524T000000Z`. A time that cannot be written is an `error`
## of the kind `s3.invalid`.
def amz_date(seconds: Int) -> Result[String]
  time = Time.at(seconds)
  return Failure.invalid("the time #{seconds} cannot be written as a date") if not time.ok?

  ok(time.unwrap!.strftime("%Y%m%dT%H%M%SZ"))
end

## The first eight characters of an `X-Amz-Date`: the day of the credential scope.
def day_of(amz: String) -> String = amz.slice(0, 8)

def hex(bytes: Bytes) -> String = OpenSSL.Digest.hexencode(bytes)

private

HEX_DIGITS = "0123456789ABCDEF"

def unreserved?(byte: Int) -> Bool
  return true if byte >= "A".code and byte <= "Z".code
  return true if byte >= "a".code and byte <= "z".code
  return true if byte >= "0".code and byte <= "9".code

  byte == "-".code or byte == ".".code or byte == "_".code or byte == "~".code
end
