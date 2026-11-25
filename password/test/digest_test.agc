import Digest from "../src/digest"

def main() -> Void
  Test.run([
    Test.test("what write makes, parse reads back unchanged") do
      parts = Digest.Parts(
        cost: 1024,
        block_size: 8,
        parallelism: 2,
        salt: Bytes.from_list([1, 2, 3, 255]).unwrap!,
        key: Bytes.from_list([0, 9, 128]).unwrap!,
      )

      text = Digest.write(parts)
      try Test.eq(text, "scrypt$1024$8$2$AQID/w==$AAmA")
      Test.eq(Digest.parse(text), ok(parts))
    end,
    Test.test("a text that is not a digest says which field is wrong, without the text") do
      shown = Digest.parse("scrypt$x$8$2$AQID$AAmA").message
      try Test.assert(shown.include?("cost"), shown)
      Test.assert(not Digest.parse("scrypt$1$8$2$AQID$AAmA$ana-secret").message.include?("ana-secret"), "echoed")
    end,
  ])
end
