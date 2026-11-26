## The program under test of the specs: it decodes the requests that it reads, one per line, in a process of its own,
## where the step budget of a scenario does not count.
##
##   decode MAX FRAME_HEX    ->  `ok SHA256_OF_DATA_HEX` or `error KIND MESSAGE`
##   cuts FRAME_HEX          ->  the frame cut at every length below its own: `ok=N kinds=KIND,...`
##   flips FRAME_HEX SHA256  ->  the frame with each of its bits flipped, one at a time: how many gave the data with that
##                               SHA-256 (hex), other data or an error, and the kinds of the errors

import Zstd from "../zstd"

def main() -> Void
  while true
    case IO.gets()
      ok(line) -> puts(answer(line.split("\t")))
      error(_) -> break
    end
  end
end

private

LIMIT = 100_000_000

def answer(parts: List[String]) -> String
  return outcome(Zstd.decompress(bytes_of(parts[2]), parts[1].to_i!)) if parts[0] == "decode"

  return cuts(bytes_of(parts[1])) if parts[0] == "cuts"

  flips(bytes_of(parts[1]), parts[2])
end

def digest_of(data: Bytes) -> String = OpenSSL.Digest.hexencode(OpenSSL.Digest.sha256(data))

def outcome(decoded: Result[Bytes]) -> String
  case decoded
    ok(data) -> "ok\t#{digest_of(data)}"
    error(e) -> "error\t#{e.kind}\t#{e.message}"
  end
end

def cuts(frame: Bytes) -> String
  accepted = 0
  kinds: Set[String] = Set.new([])
  for n in 0...frame.size
    case Zstd.decompress(frame.take(n), LIMIT)
      ok(_) -> accepted += 1
      error(e) -> kinds = kinds.add(e.kind)
    end
  end

  "ok=#{accepted} kinds=#{kinds.to_a.sort.join(",")}"
end

def flips(frame: Bytes, digest: String) -> String
  same = 0
  other = 0
  refused = 0
  kinds: Set[String] = Set.new([])
  for i in 0...frame.size
    for bit in 0...8
      flipped = frame.take(i) + Bytes.from_list([frame[i].bit_xor(1.shift_left(bit))]).unwrap! + frame.drop(i + 1)
      case Zstd.decompress(flipped, LIMIT)
        ok(back) ->
          if digest_of(back) == digest
            same += 1
          else
            other += 1
          end

        error(e) ->
          refused += 1
          kinds = kinds.add(e.kind)
      end
    end
  end

  "same=#{same} other=#{other} refused=#{refused} kinds=#{kinds.to_a.sort.join(",")}"
end

def bytes_of(text: String) -> Bytes
  return "".bytes if text == "-" or text == ""
  OpenSSL.Digest.hexdecode(text).unwrap!
end
