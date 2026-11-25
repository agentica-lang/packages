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

## The parts of a digest text, or an `error` that names the field that is wrong. The digest comes from a store, but it
## is still bounded here, so that a digest that was damaged or planted cannot make a check ask the machine for gigabytes
## or for hours: the memory of the work (`128 * r * (N + p + 2)` bytes) is at most 256 MiB, `r` at most 32, `p` at most
## 16, `N` a power of 2 from 1024, the salt 8 to 64 bytes and the key 16 to 64. The text of the digest is never part of
## the error.
def parse(text: String) -> Result[Parts]
  fields = text.split("$")
  if fields.size != FIELDS or fields[0] != SCHEME
    return error("password: not a digest of the form scrypt$N$r$p$salt$key")
  end

  cost = try number(fields[1], "cost")
  block_size = try number(fields[2], "block size")
  parallelism = try number(fields[3], "parallelism")
  try check_cost(cost, block_size, parallelism)
  salt = try bytes_of(fields[4], "salt", MIN_SALT_BYTES, MAX_SALT_BYTES)
  key = try bytes_of(fields[5], "key", MIN_KEY_BYTES, MAX_KEY_BYTES)
  ok(Parts(cost: cost, block_size: block_size, parallelism: parallelism, salt: salt, key: key))
end

private

SCHEME = "scrypt"
FIELDS = 6
MIN_COST = 1024
MAX_BLOCK_SIZE = 32
MAX_PARALLELISM = 16
MAX_WORK_BYTES = 268_435_456
MIN_SALT_BYTES = 8
MAX_SALT_BYTES = 64
MIN_KEY_BYTES = 16
MAX_KEY_BYTES = 64

# A decimal as `write` makes it: `+8` and `08` are other texts for the same number, so they are not digests of ours.
def number(text: String, name: String) -> Result[Int]
  value = text.to_i
  if not value.ok? or value.unwrap! <= 0 or value.unwrap!.to_s != text
    return error("password: the #{name} of the digest is not a number")
  end

  value
end

def check_cost(cost: Int, block_size: Int, parallelism: Int) -> Result[Void]
  return error("password: the cost of the digest is not a power of 2 from #{MIN_COST}") if not power_of_two?(cost)

  return error("password: the block size of the digest is over #{MAX_BLOCK_SIZE}") if block_size > MAX_BLOCK_SIZE

  return error("password: the parallelism of the digest is over #{MAX_PARALLELISM}") if parallelism > MAX_PARALLELISM

  # Divides instead of multiplying, so that a huge cost cannot overflow the check.
  if cost + parallelism + 2 > MAX_WORK_BYTES / (128 * block_size)
    return error("password: the digest asks for more than #{MAX_WORK_BYTES / 1_048_576} MiB of memory")
  end

  ok()
end

def power_of_two?(value: Int) -> Bool
  return false if value < MIN_COST

  rest = value
  while rest > 1 and rest % 2 == 0
    rest = rest / 2
  end

  rest == 1
end

def bytes_of(text: String, name: String, least: Int, most: Int) -> Result[Bytes]
  decoded = Base64.strict_decode64(text)
  return error("password: the #{name} of the digest is not base64") if not decoded.ok?

  size = decoded.unwrap!.size
  return error("password: the #{name} of the digest is not #{least} to #{most} bytes") if size < least or size > most

  decoded
end
