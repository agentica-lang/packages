import Zstd from "../zstd"
import Xxh64 from "../src/xxh64"

private

# A frame with a checksum, made by `zstd`: the text "a", then the 4 bytes of the checksum.
FRAME = "28b52ffd0458090000615b6e8ca9"

# The bytes (i * 7 + 3) % 256 for i below size.
def sample(size: Int) -> Bytes = Bytes.from_list((0...size).map { |i| (i * 7 + 3) % 256 }).unwrap!

def low(data: Bytes) -> Int = Xxh64.hash(data).bit_and(0xFFFFFFFF)

def high(data: Bytes) -> Int = Xxh64.hash(data).shift_right_unsigned(32)

# The published XXH64 values of the empty string, "a" and "abc" (all 64 bits), and the checksums that `zstd` wrote for
# samples around the sizes where XXH64 changes its loop: 32 bytes (the stripes), 8 and 4.
def test_xxh64_of_known_strings() -> Result[Void]
  try Test.eq(high("".bytes), 0xEF46DB37)
  try Test.eq(low("".bytes), 0x51D8E999)
  try Test.eq(high("a".bytes), 0xD24EC4F1)
  try Test.eq(low("a".bytes), 0xA98C6E5B)
  try Test.eq(high("abc".bytes), 0x44BC2CF5)
  Test.eq(low("abc".bytes), 0xAD770999)
end

def test_xxh64_of_samples_matches_zstd() -> Result[Void]
  try Test.eq(low(sample(31)), 0xCC4A6119)
  try Test.eq(low(sample(32)), 0xF790FD97)
  try Test.eq(low(sample(33)), 0xBA588784)
  try Test.eq(low(sample(45)), 0x897C4B41)
  try Test.eq(low(sample(100)), 0x170FE531)
  Test.eq(low(sample(257)), 0xE4F822FA)
end

def frame_bytes(hex: String) -> Bytes = OpenSSL.Digest.hexdecode(hex).unwrap!

def test_a_wrong_checksum_is_refused_unless_verify_is_false() -> Result[Void]
  wrong = frame_bytes("28b52ffd0458090000615b6e8caa")
  try Test.eq(Zstd.decompress(frame_bytes(FRAME), 10), ok("a".bytes))
  try Test.eq(Zstd.decompress(wrong, 10).ok?, false)
  Test.eq(Zstd.decompress(wrong, 10, false), ok("a".bytes))
end

def test_verify_false_still_needs_the_checksum_bytes() -> Result[Void]
  cut = frame_bytes("28b52ffd0458090000615b6e8c")
  try Test.eq(Zstd.decompress(cut, 10, false).ok?, false)
  try Test.eq(Zstd.decompress(frame_bytes(FRAME), 0, false).ok?, false)
  Test.eq(Zstd.decompress(frame_bytes(FRAME), 1), ok("a".bytes))
end
