## The core schema of YAML 1.2: what a scalar is, from its text, whether it was plain, and its tag. A plain scalar
## with no tag is a null, a boolean, an integer, a float or a string by its text; a quoted or block one is a string.
## The only tags are the core ones; JSON has no infinity or NaN, so `.inf` and `.nan` are errors.

CORE = "tag:yaml.org,2002:"

def scalar(text: String, plain: Bool, tag: String) -> Result[JSON.Value]
  if tag == ""
    return implicit(text) if plain

    return ok(JSON.from(text))
  end

  case tag
    "!", "tag:yaml.org,2002:str" -> ok(JSON.from(text))
    "tag:yaml.org,2002:null" -> tagged_null(text)
    "tag:yaml.org,2002:bool" -> tagged_bool(text)
    "tag:yaml.org,2002:int" -> tagged_int(text)
    "tag:yaml.org,2002:float" -> tagged_float(text)
    "tag:yaml.org,2002:seq", "tag:yaml.org,2002:map" -> error("a scalar cannot be tagged #{shown(tag)}")
    _ -> error("unsupported tag #{shown(tag)}")
  end
end

## Whether a collection may carry the tag: none, `!`, or its own core tag.
def collection_tag?(tag: String, own: String) -> Bool = tag == "" or tag == "!" or tag == CORE + own

## A tag as YAML writes it: `!!str` for a core tag.
def shown(tag: String) -> String
  if tag.start_with?(CORE)
    "!!#{tag.slice(CORE.length, tag.length - CORE.length)}"
  else
    tag
  end
end

private

NULLS = Set.new(["", "~", "null", "Null", "NULL"])
TRUES = Set.new(["true", "True", "TRUE"])
FALSES = Set.new(["false", "False", "FALSE"])
INFINITIES = Set.new([".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF"])
NANS = Set.new([".nan", ".NaN", ".NAN"])
# A `0x` or `0o` integer past 64 bits becomes decimal digits in time quadratic in its length, so it has a cap.
MAX_RADIX_DIGITS = 256
# The most characters of a scalar that an error shows.
SHOWN = 80
NUMBER_STARTS = Set.new("+-.0123456789".bytes.to_a)
ZERO = 48
NINE = 57
PLUS = 43
MINUS = 45
DOT = 46

def implicit(text: String) -> Result[JSON.Value]
  return ok(JSON.null()) if NULLS.include?(text)
  return ok(JSON.from(true)) if TRUES.include?(text)
  return ok(JSON.from(false)) if FALSES.include?(text)
  return ok(JSON.from(text)) if not NUMBER_STARTS.include?(text.bytes[0])

  if int?(text)
    return int_value(text)
  elsif float?(text)
    return float_value(text)
  end

  ok(JSON.from(text))
end

def tagged_null(text: String) -> Result[JSON.Value]
  return ok(JSON.null()) if NULLS.include?(text)

  error("!!null cannot be \"#{cut(text)}\"")
end

def tagged_bool(text: String) -> Result[JSON.Value]
  return ok(JSON.from(true)) if TRUES.include?(text)
  return ok(JSON.from(false)) if FALSES.include?(text)

  error("!!bool cannot be \"#{cut(text)}\"")
end

def tagged_int(text: String) -> Result[JSON.Value]
  return int_value(text) if int?(text)

  error("!!int cannot be \"#{cut(text)}\"")
end

def tagged_float(text: String) -> Result[JSON.Value]
  return float_value(text) if int?(text) or float?(text)

  error("!!float cannot be \"#{cut(text)}\"")
end

def digits?(bytes: List[Int], from: Int, low: Int, high: Int) -> Bool
  from < bytes.size and bytes.drop(from).all? do |c| c >= low and c <= high end
end

def hex?(bytes: List[Int]) -> Bool = bytes.size > 2 and bytes.drop(2).all? do |c| hex_digit(c) >= 0 end

def hex_digit(c: Int) -> Int
  if c >= ZERO and c <= NINE
    c - ZERO
  elsif c >= "a".code and c <= "f".code
    c - "a".code + 10
  elsif c >= "A".code and c <= "F".code
    c - "A".code + 10
  else
    -1
  end
end

def sign_length(bytes: List[Int]) -> Int
  if not bytes.empty? and (bytes[0] == PLUS or bytes[0] == MINUS)
    1
  else
    0
  end
end

# `[-+]?[0-9]+`, `0o[0-7]+` or `0x[0-9a-fA-F]+`.
def int?(text: String) -> Bool
  bytes = text.bytes.to_a
  return digits?(bytes, 2, ZERO, "7".code) if text.start_with?("0o")
  return hex?(bytes) if text.start_with?("0x")

  digits?(bytes, sign_length(bytes), ZERO, NINE)
end

# `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`, or an infinity or NaN.
def float?(text: String) -> Bool
  return true if INFINITIES.include?(text) or NANS.include?(text)

  bytes = text.bytes.to_a
  i = sign_length(bytes)
  whole = digit_run(bytes, i)
  i += whole
  fraction = 0
  if i < bytes.size and bytes[i] == DOT
    fraction = digit_run(bytes, i + 1)
    i += 1 + fraction
  end

  return false if whole == 0 and fraction == 0

  if i < bytes.size and (bytes[i] == "e".code or bytes[i] == "E".code)
    i += 1
    i += sign_length(bytes.drop(i))
    exponent = digit_run(bytes, i)
    return false if exponent == 0

    i += exponent
  end

  i == bytes.size
end

def digit_run(bytes: List[Int], from: Int) -> Int
  i = from
  while i < bytes.size and bytes[i] >= ZERO and bytes[i] <= NINE
    i += 1
  end

  i - from
end

def int_value(text: String) -> Result[JSON.Value]
  if text.start_with?("0o")
    return radix_value(text, 8)
  elsif text.start_with?("0x")
    return radix_value(text, 16)
  end

  case text.to_i
    ok(n) -> ok(JSON.from(n))
    error(_) -> big_int(text)
  end
end

# A decimal integer outside 64 bits keeps its exact digits as a JSON number.
def big_int(text: String) -> Result[JSON.Value]
  negative = text.start_with?("-")
  digits = text
  if text.start_with?("-") or text.start_with?("+")
    digits = text.slice(1, text.length - 1)
  end

  digits = digits.split("").drop_while(->(c) { c == "0" }).join("")
  if negative
    digits = "-#{digits}"
  end

  JSON.parse(digits)
end

def radix_value(text: String, radix: Int) -> Result[JSON.Value]
  value = 0
  for c in text.bytes.drop(2)
    digit = hex_digit(c)
    if value > (9_223_372_036_854_775_807 - digit) / radix
      if text.length - 2 > MAX_RADIX_DIGITS
        return error("the integer #{cut(text)} has more than #{MAX_RADIX_DIGITS} digits")
      end

      return big_radix(text, radix)
    end

    value = value * radix + digit
  end

  ok(JSON.from(value))
end

def float_value(text: String) -> Result[JSON.Value]
  if INFINITIES.include?(text) or NANS.include?(text)
    return error("#{text} has no JSON value: JSON has no infinity or NaN")
  end

  bytes = text.bytes.to_a
  sign = text.slice(0, sign_length(bytes))
  rest = text.slice(sign.length, text.length - sign.length)
  mantissa = rest
  exponent = ""
  for marker in ["e", "E"]
    case rest.index_of(marker)
      some(at) ->
        mantissa = rest.slice(0, at)
        exponent = rest.slice(at, rest.length - at)
      none -> nil
    end
  end

  parts = "#{mantissa}.".split(".")
  whole = parts[0]
  fraction = parts[1]
  if whole == ""
    whole = "0"
  end

  if fraction == ""
    fraction = "0"
  end

  value = try "#{sign.replace("+", "")}#{whole}.#{fraction}#{exponent}".to_f
  return error("the float #{cut(text)} is out of range") if value - value != 0.0

  ok(JSON.from(value))
end

# A `0x` or `0o` integer outside 64 bits, as its exact decimal digits.
def big_radix(text: String, radix: Int) -> Result[JSON.Value]
  # The decimal digits, the lowest first.
  digits = [0]
  for c in text.bytes.drop(2)
    carry = hex_digit(c)
    next_digits: List[Int] = []
    for d in digits
      product = d * radix + carry
      next_digits = next_digits.push(product % 10)
      carry = product / 10
    end

    while carry > 0
      next_digits = next_digits.push(carry % 10)
      carry = carry / 10
    end

    digits = next_digits
  end

  JSON.parse(digits.reverse.map(->(d) { d.to_s }).join(""))
end

def cut(text: String) -> String
  return text if text.length <= SHOWN

  "#{text.slice(0, SHOWN)}..."
end
