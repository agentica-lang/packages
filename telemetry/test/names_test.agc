import Names from "../src/names"
import Types from "../src/types"

private

def main() -> Void
  Test.run([
    Test.test("an event matches its name, each prefix at a dot, and the star") do
      Test.eq(Names.matching_patterns("jobs.job.stop"), ["jobs", "jobs.job", "jobs.job.stop", "*"])
    end,
    Test.test("a name of one word matches itself and the star") do
      Test.eq(Names.matching_patterns("jobs"), ["jobs", "*"])
    end,
    Test.test("a pattern is one to four words, or the star") do
      options = Types.Options()
      good = ["*", "a", "a_1.b2", "a.b.c.d"]
      bad = ["", "A", "1a", "a.", ".a", "a..b", "a-b", "a b", "a.b.c.d.e", "**"]
      try Test.eq(
        good.map(->(pattern) { Names.check_attach("id", [pattern], options).ok? }),
        good.map(->(_p) { true }),
      )

      Test.eq(bad.map(->(pattern) { Names.check_attach("id", [pattern], options).ok? }), bad.map(->(_p) { false }))
    end,
    Test.test("only the first four words of a long name can match a pattern") do
      Test.eq(Names.matching_patterns("a.b.c.d.e.f"), ["a", "a.b", "a.b.c", "a.b.c.d", "*"])
    end,
    Test.test("a queue is from 1 to the most that an actor takes") do
      try Test.assert(Names.check_attach("id", ["a"], Types.Options(capacity: Names.MAX_CAPACITY)).ok?, "the most")
      try Test.assert(not Names.check_attach("id", ["a"], Types.Options(capacity: Names.MAX_CAPACITY + 1)).ok?, "over")
      Test.assert(Names.check_attach("id", ["a"], Types.Options(capacity: 1)).ok?, "one")
    end,
    Test.test("an attach needs an id, a pattern and a queue of one or more") do
      options = Types.Options()
      try Test.assert(not Names.check_attach("", ["a"], options).ok?, "an empty id")
      try Test.assert(not Names.check_attach("id", [], options).ok?, "no pattern")
      Test.assert(not Names.check_attach("id", ["a"], Types.Options(capacity: 0)).ok?, "a queue of 0")
    end,
  ])
end
