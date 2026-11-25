## The text of a digest, `scrypt$N$r$p$salt$key` (salt and key in base64), and nothing else: no hashing here.

## What a digest says: the cost that made it, and the salt and the key.
struct Parts
  cost: Int
  block_size: Int
  parallelism: Int
  salt: Bytes
  key: Bytes
end

## The digest text of the parts.
def write(parts: Parts) -> String
  salt = Base64.strict_encode64(parts.salt)
  key = Base64.strict_encode64(parts.key)
  "#{SCHEME}$#{parts.cost}$#{parts.block_size}$#{parts.parallelism}$#{salt}$#{key}"
end

## The parts of a digest text, or an `error` that names the field that is wrong. The text of the digest is never part of
## the error.
def parse(text: String) -> Result[Parts]
  fields = text.split("$")
  if fields.size != FIELDS or fields[0] != SCHEME
    return error("password: not a digest of the form scrypt$N$r$p$salt$key")
  end

  cost = try number(fields[1], "cost")
  block_size = try number(fields[2], "block size")
  parallelism = try number(fields[3], "parallelism")
  salt = Base64.strict_decode64(fields[4])
  return error("password: the salt of the digest is not base64") if not salt.ok? or salt.unwrap!.empty?

  key = Base64.strict_decode64(fields[5])
  return error("password: the key of the digest is not base64") if not key.ok? or key.unwrap!.empty?

  ok(Parts(cost: cost, block_size: block_size, parallelism: parallelism, salt: salt.unwrap!, key: key.unwrap!))
end

private

SCHEME = "scrypt"
FIELDS = 6

def number(text: String, name: String) -> Result[Int]
  value = text.to_i
  return error("password: the #{name} of the digest is not a number") if not value.ok? or value.unwrap! <= 0

  value
end
