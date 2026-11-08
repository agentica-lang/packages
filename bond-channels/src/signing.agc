## The signed stream names of Turbo, in the format of Rails (turbo-rails `Turbo.signed_stream_verifier`), so that a
## name signed by Rails verifies here and the other way round. The name is signed, not encrypted: anybody can read it;
## the signature is what stops a person from subscribing to a stream of somebody else. Pure.
##
## What Rails does (`turbo-rails/app/channels/turbo/streams/stream_name.rb`, `ActiveSupport::MessageVerifier`):
##
## 1. The key is `generate_key("turbo/signed_stream_verifier_key")`: PBKDF2-HMAC-SHA256 of `secret_key_base`, 1000
##    iterations, 64 bytes (`stream_key`).
## 2. The verifier has the JSON serializer and no `_rails` envelope (the metadata of Active Record signed ids is not
##    here): the message is the JSON text of the name, a quoted string.
## 3. A signed name is `base64(json) + "--" + hex(HMAC-SHA256(key, base64(json)))`, with the standard padded Base64
##    (not the URL-safe one of `signed_id`).

SALT = "turbo/signed_stream_verifier_key"
ITERATIONS = 1_000
KEY_BYTES = 64
SEPARATOR = "--"
# The hex of HMAC-SHA256.
DIGEST_LENGTH = 64

## The signing key for `secret_key_base` (the secret of the Rails app, or the app's own). Make it once, at start-up. An
## empty secret is an `error`: a key from it would sign anything. The secret must be strong, as the `SECRET_KEY_BASE`
## of an app is: the key is only as hard to guess as it is, and no length is checked here, as in Rails.
export def stream_key(secret_key_base: String) -> Result[Bytes]
  if secret_key_base.empty?
    return error("stream key: the secret is empty")
  end

  return OpenSSL.KDF.pbkdf2_hmac_sha256(secret_key_base.bytes, SALT.bytes, ITERATIONS, KEY_BYTES)
end

## The signed form of `name`, for `<turbo-cable-stream-source signed-stream-name="...">`. `name` is what Rails'
## `stream_name_from` makes of its streamables: the parts joined with `:` (a record is its GlobalID param).
##
## `JSON.encode` writes `<`, `>` and `&` as they are, where Rails escapes them when `escape_html_entities_in_json` is
## on. The signature covers the text as written, and `verified_stream_name` reads either form, so a name signed by
## either side verifies on both.
export def signed_stream_name(key: Bytes, name: String) -> String
  encoded = Base64.strict_encode64(JSON.encode(JSON.from(name)).bytes)
  return "#{encoded}#{SEPARATOR}#{OpenSSL.HMAC.sha256_hexdigest(key, encoded.bytes)}"
end

## The name in `signed` when it was signed with `key`; `none` for anything else (a bad signature, a bad encoding, a
## message that is not a JSON string, such as a number or the envelope of a signed id, and a validly signed empty name,
## which would stream from the topic ""). The reason is not told, as in Rails. The signature is checked first, in
## constant time.
export def verified_stream_name(key: Bytes, signed: String) -> Optional[String]
  cut = signed.length - DIGEST_LENGTH - SEPARATOR.length
  if cut <= 0 or signed.slice(cut, SEPARATOR.length) != SEPARATOR
    return none
  end

  encoded = signed.slice(0, cut)
  digest = signed.slice(cut + SEPARATOR.length, DIGEST_LENGTH)
  if not OpenSSL.HMAC.secure_compare(OpenSSL.HMAC.sha256_hexdigest(key, encoded.bytes).bytes, digest.bytes)
    return none
  end

  return name_of(encoded)
end

def name_of(encoded: String) -> Optional[String]
  bytes = Base64.strict_decode64(encoded)
  if not bytes.ok?
    return none
  end

  text = String.from_bytes(bytes.unwrap!)
  if not text.ok?
    return none
  end

  parsed = JSON.parse(text.unwrap!)
  if not parsed.ok?
    return none
  end

  name = JSON.string(parsed.unwrap!)
  if not name.ok?
    return none
  end

  if name.unwrap!.empty?
    return none
  end

  return some(name.unwrap!)
end
