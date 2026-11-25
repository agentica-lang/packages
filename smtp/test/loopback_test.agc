import Smtp from "../smtp"

def main() -> Void
  Test.run([
    Test.test("the hosts of this machine are loopback") do
      try Test.eq(Smtp.loopback?("localhost"), true)
      try Test.eq(Smtp.loopback?("LOCALHOST"), true)
      try Test.eq(Smtp.loopback?("::1"), true)
      try Test.eq(Smtp.loopback?("[::1]"), true)
      try Test.eq(Smtp.loopback?("127.0.0.1"), true)
      Test.eq(Smtp.loopback?("127.0.0.2"), true)
    end,
    Test.test("a name that only looks like this machine is not loopback") do
      try Test.eq(Smtp.loopback?("127.1"), false)
      try Test.eq(Smtp.loopback?("127.evil.com"), false)
      try Test.eq(Smtp.loopback?("localhost."), false)
      try Test.eq(Smtp.loopback?("127.0.0.256"), false)
      try Test.eq(Smtp.loopback?("127.0.0.1.example.com"), false)
      try Test.eq(Smtp.loopback?("128.0.0.1"), false)
      Test.eq(Smtp.loopback?(""), false)
    end,
  ])
end
