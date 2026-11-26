import Zstd from "../zstd"
import Xxh64 from "../src/xxh64"

private

# The frames of the tests, in hex: written from RFC 8878 or made by `zstd`. A_FRAME is the text "a", then the 4
# bytes of its checksum; the text frames hold three times TEXT_UNIT, TEXT_FRAME_CHECKED with a checksum.
A_FRAME = "28b52ffd0458090000615b6e8ca9"
EMPTY_FRAME = "28b52ffd240001000099e9d851"
RAW_ABC = "28b52ffd2003190000616263"
SKIPPABLE = "502a4d180300000078797a"
TEXT_UNIT = "the quick brown fox jumps over the lazy dog. the lazy dog sleeps. "
TEXT_FRAME = (
  "28b52ffd0058050200340374686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c61" +
  "7a7920646f672e20736c656570730300bd0809e0c40ce39865"
)

TEXT_FRAME_CHECKED = (
  "28b52ffd0458050200340374686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c61" +
  "7a7920646f672e20736c656570730300bd0809e0c40ce3986521d894b3"
)

def frame_bytes(hex: String) -> Bytes = OpenSSL.Digest.hexdecode(hex).unwrap!

def text(times: Int) -> String = (0...times).map { |_| TEXT_UNIT }.join("")

def with_checksum(checksum: String) -> String = TEXT_FRAME_CHECKED.slice(0, TEXT_FRAME_CHECKED.length - 8) + checksum

def reads(frame: String, data: String) -> Result[Void]
  Test.eq(Zstd.decompress(frame_bytes(frame), 1000), ok(data.bytes))
end

def refuses(frame: String, max_bytes: Int, kind: String) -> Result[Void]
  refused = case Zstd.decompress(frame_bytes(frame), max_bytes)
    ok(_) -> "read"
    error(e) -> e.kind
  end

  Test.eq(refused, kind)
end

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

def test_a_wrong_checksum_is_refused_unless_verify_is_false() -> Result[Void]
  wrong = frame_bytes("28b52ffd0458090000615b6e8caa")
  try Test.eq(Zstd.decompress(frame_bytes(A_FRAME), 10), ok("a".bytes))
  try Test.eq(Zstd.decompress(wrong, 10).ok?, false)
  Test.eq(Zstd.decompress(wrong, 10, false), ok("a".bytes))
end

def test_verify_false_still_needs_the_checksum_bytes() -> Result[Void]
  cut = frame_bytes("28b52ffd0458090000615b6e8c")
  try Test.eq(Zstd.decompress(cut, 10, false).ok?, false)
  try Test.eq(Zstd.decompress(frame_bytes(A_FRAME), 0, false).ok?, false)
  Test.eq(Zstd.decompress(frame_bytes(A_FRAME), 1), ok("a".bytes))
end

def test_reads_an_empty_frame_with_a_checksum() -> Result[Void] = reads(EMPTY_FRAME, "")

def test_reads_an_empty_frame_with_a_raw_block() -> Result[Void] = reads("28b52ffd2000010000", "")

def test_reads_a_frame_with_a_checksum() -> Result[Void] = reads(A_FRAME, "a")

def test_reads_a_raw_block() -> Result[Void] = reads(RAW_ABC, "abc")

def test_reads_an_rle_block() -> Result[Void] = reads("28b52ffd20052b000061", "aaaaa")

def test_reads_a_compressed_block_with_no_checksum() -> Result[Void] = reads(TEXT_FRAME, text(3))

def test_reads_a_compressed_block_with_a_checksum() -> Result[Void] = reads(TEXT_FRAME_CHECKED, text(3))

def test_reads_a_skippable_frame_alone() -> Result[Void] = reads(SKIPPABLE, "")

def test_reads_a_skippable_frame_before_a_frame() -> Result[Void] = reads(SKIPPABLE + A_FRAME, "a")

def test_reads_a_skippable_frame_between_two_frames() -> Result[Void] = reads(A_FRAME + SKIPPABLE + RAW_ABC, "aabc")

def test_reads_three_frames_in_a_row() -> Result[Void] = reads(TEXT_FRAME_CHECKED + TEXT_FRAME + EMPTY_FRAME, text(6))

def test_refuses_an_empty_input() -> Result[Void] = refuses("", 1000, "zstd.malformed")

def test_refuses_a_cut_frame_magic() -> Result[Void] = refuses("28b52f", 1000, "zstd.malformed")

def test_refuses_a_cut_frame_header() -> Result[Void] = refuses("28b52ffd", 1000, "zstd.malformed")

def test_refuses_bytes_with_no_frame_magic() -> Result[Void] = refuses("deadbeef00", 1000, "zstd.malformed")

def test_refuses_a_frame_header_with_a_reserved_bit_set() -> Result[Void]
  refuses("28b52ffd0800", 1000, "zstd.malformed")
end

def test_refuses_a_block_of_the_reserved_type() -> Result[Void] = refuses("28b52ffd2000070000", 1000, "zstd.malformed")

def test_refuses_a_raw_block_over_a_content_size_of_0() -> Result[Void]
  refuses("28b52ffd200019000061", 1000, "zstd.malformed")
end

def test_refuses_a_cut_raw_block() -> Result[Void] = refuses("28b52ffd2003190000", 1000, "zstd.malformed")

def test_refuses_a_non_zero_dictionary_id_as_unsupported() -> Result[Void]
  refuses("28b52ffd210500010000", 1000, "zstd.unsupported")
end

def test_refuses_a_raw_block_over_a_content_size_of_1() -> Result[Void]
  refuses("28b52ffd2001190000", 1000, "zstd.malformed")
end

def test_refuses_a_content_size_larger_than_the_data() -> Result[Void]
  refuses("28b52ffd200a190000616263", 1000, "zstd.malformed")
end

def test_refuses_a_cut_checksum() -> Result[Void]
  refuses(TEXT_FRAME_CHECKED.slice(0, TEXT_FRAME_CHECKED.length - 2), 1000, "zstd.malformed")
end

def test_refuses_a_checksum_of_zeros() -> Result[Void] = refuses(with_checksum("00000000"), 1000, "zstd.malformed")

def test_refuses_a_checksum_with_a_wrong_last_byte() -> Result[Void]
  refuses(with_checksum("21d89400"), 1000, "zstd.malformed")
end

def test_refuses_a_byte_after_the_checksum() -> Result[Void] = refuses(A_FRAME + "00", 1000, "zstd.malformed")

def test_refuses_a_skippable_frame_that_runs_past_the_end() -> Result[Void]
  refuses("502a4d18050000000102", 1000, "zstd.malformed")
end

def test_refuses_a_cut_skippable_frame_header() -> Result[Void] = refuses("502a4d18", 1000, "zstd.malformed")

def test_refuses_an_extra_bit_after_a_huffman_stream() -> Result[Void]
  refuses(
    "28b52ffd0058b50400220606811200591d3c103028590a0aed23ba102c533bab226dc40143a861b29385d23007200242" +
    "0cb47a1010d3d40d230d611347c49b66d350482826550aed4c7d8e73ccfb27874ba66f78dacefdaa53018402159ab484" +
    "6a2a4238abbc1043d8535404d633a4f0e566dff8eedf9e2d1c58ab5c38801971d63a7521cc879925e1f4a99f34eb4070" +
    "2858008dab5c0d5e35532abadf7ea9",
    1000,
    "zstd.malformed",
  )
end

def test_refuses_a_compressed_block_over_the_content_size() -> Result[Void]
  refuses("28b52ffd20042d00000861010001", 1000, "zstd.malformed")
end

def test_refuses_a_sequence_that_writes_over_the_content_size() -> Result[Void]
  refuses(
    "28b52ffda032000000050100a0f5b165224a58b791df6af1d8303e61cdc4bb86c3145401020048ce33fd2301",
    1000,
    "zstd.malformed",
  )
end

def test_refuses_an_offset_one_byte_before_the_start() -> Result[Void]
  refuses(
    "28b52ffda050000000050100a0f5b165224a58b791df6af1d8303e61cdc4bb86c3145801020048ce33fd2301",
    1000,
    "zstd.malformed",
  )
end

def test_refuses_a_table_symbol_over_its_maximum() -> Result[Void]
  refuses(
    "28b52ffda050000000050100a0f5b165224a58b791df6af1d8303e61cdc4bb86c3145428020048ce33fd2301",
    1000,
    "zstd.malformed",
  )
end

def test_refuses_reserved_bits_of_the_sequence_modes() -> Result[Void]
  refuses(
    "28b52ffda050000000050100a0f5b165224a58b791df6af1d8303e61cdc4bb86c3145501020048ce33fd2301",
    1000,
    "zstd.malformed",
  )
end

def test_refuses_a_repeated_table_with_no_table_before_it() -> Result[Void]
  refuses(
    "28b52ffda050000000050100a0f5b165224a58b791df6af1d8303e61cdc4bb86c314d401020048ce33fd2301",
    1000,
    "zstd.malformed",
  )
end

def test_refuses_a_content_size_over_max_bytes() -> Result[Void] = refuses(TEXT_FRAME, 100, "zstd.too_large")

def test_refuses_a_negative_max_bytes() -> Result[Void] = refuses(TEXT_FRAME, -1, "zstd.too_large")

def test_refuses_an_rle_block_over_max_bytes() -> Result[Void] = refuses("28b52ffd20052b000061", 4, "zstd.too_large")

def test_refuses_two_frames_over_max_bytes_together() -> Result[Void] = refuses(A_FRAME + A_FRAME, 1, "zstd.too_large")
