import Digest from "../src/digest"

def main() -> Void
  Test.run([
    Test.test("what write makes, parse reads back unchanged") do
      parts = Digest.Parts(
        cost: 1024,
        block_size: 8,
        parallelism: 2,
        salt: Bytes.from_list([1, 2, 3, 4, 5, 6, 7, 255]).unwrap!,
        key: Bytes.from_list([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 128]).unwrap!,
      )

      text = Digest.write(parts)
      try Test.eq(text, "scrypt$1024$8$2$AQIDBAUGB/8=$AAECAwQFBgcICQoLDA0OgA==")
      Test.eq(Digest.parse(text), ok(parts))
    end,
    Test.test("a text that is not a digest says which field is wrong, without the text") do
      shown = Digest.parse("scrypt$x$8$2$AQIDBAUGB/8=$AAECAwQFBgcICQoLDA0OgA==").message
      try Test.assert(shown.include?("cost"), shown)
      echoed = Digest.parse("scrypt$1024$8$2$AQIDBAUGB/8=$AAECAwQFBgcICQoLDA0OgA==$ana-secret").message
      Test.assert(not echoed.include?("ana-secret"), "echoed")
    end,
    Test.test("the bounds of a digest are checked in the parse, and each error names its field") do
      salt = "AQIDBAUGB/8="
      key = "AAECAwQFBgcICQoLDA0OgA=="
      try Test.assert(Digest.parse("scrypt$1024$32$16$#{salt}$#{key}").ok?, "the largest r and p")
      try Test.assert(Digest.parse("scrypt$1048576$8$1$#{salt}$#{key}").message.include?("memory"), "memory")
      try Test.assert(Digest.parse("scrypt$1000$8$2$#{salt}$#{key}").message.include?("cost"), "cost")
      try Test.assert(Digest.parse("scrypt$1024$33$2$#{salt}$#{key}").message.include?("block size"), "r")
      try Test.assert(Digest.parse("scrypt$1024$8$17$#{salt}$#{key}").message.include?("parallelism"), "p")
      try Test.assert(Digest.parse("scrypt$1024$8$2$AQIDBAUGBw==$#{key}").message.include?("salt"), "salt")
      Test.assert(Digest.parse("scrypt$1024$8$2$#{salt}$AAECAwQFBgcICQoLDA0O").message.include?("key"), "key")
    end,
  ])
end
