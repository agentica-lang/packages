import Hpack from "../hpack"
import BDD from "std/bdd"

def main() -> Void
  BDD.run([
    BDD.step("the decoder processes these operations:", &decode_blocks),
    BDD.step("the encoder writes and round trips these blocks:", &encode_blocks),
  ])
end

private

def decode_blocks(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  state = Hpack.decoder()
  for row in BDD.table(ctx).drop(1)
    if row[0] == "limit"
      case Hpack.set_decoder_limit(state, row[1].to_i!)
        ok(next_state) ->
          return BDD.assert(ctx, false, "accepted table limit #{row[1]}") if row[2] != "-"
          state = next_state
        error(e) -> return BDD.assert(ctx, false, e.message) if not e.is_a?(row[2])
      end

      next
    end

    block = hex(row[1])
    budget = row[0].to_i!
    case Hpack.decode(state, block, budget)
      ok(decoded) ->
        if row[2].start_with?("hpack.") or not same_headers?(decoded.headers, headers(row[2]))
          return BDD.assert(ctx, false, "unexpected output for #{row[1]}")
        end

        state = decoded.state
      error(e) -> return BDD.assert(ctx, false, "#{row[1]} gave #{e.message}") if not e.is_a?(row[2])
    end
  end

  BDD.assert(ctx, BDD.table(ctx).size > 1, "no blocks to check")
end

def encode_blocks(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  state = Hpack.decoder()
  for row in BDD.table(ctx).drop(1)
    fields = headers(row[0])
    block = Hpack.encode(fields).unwrap!
    return BDD.assert(ctx, false, "wrong encoding for #{row[0]}") if block != hex(row[1])
    decoded = Hpack.decode(state, block).unwrap!
    return BDD.assert(ctx, false, "wrong round trip for #{row[0]}") if not same_headers?(decoded.headers, fields)
    state = decoded.state
  end

  BDD.assert(ctx, BDD.table(ctx).size > 1, "no blocks to check")
end

def headers(spec: String) -> List[Hpack.Header]
  return [] if spec == "-" or spec.empty?
  spec.split(",").map do |field| header(field) end
end

def header(spec: String) -> Hpack.Header
  parts = spec.split(":")
  Hpack.Header(name: hex(parts[0]), value: hex(parts[1]), never_indexed: parts.size == 3)
end

def same_headers?(actual: List[Hpack.Header], expected: List[Hpack.Header]) -> Bool
  return false if actual.size != expected.size
  for i in 0...expected.size
    left = actual[i]
    right = expected[i]
    return false if left.name != right.name or left.value != right.value or left.never_indexed != right.never_indexed
  end

  true
end

def hex(value: String) -> Bytes
  return "".bytes if value == "-"
  OpenSSL.Digest.hexdecode(value).unwrap!
end
