import Address from "../src/address"

private

def test_a_peer_is_a_host_and_a_port() -> Result[Void]
  try Test.eq(try Address.parse("127.0.0.1:4000"), Address.Endpoint(host: "127.0.0.1", port: 4000))
  try Test.eq(try Address.parse("node1.example.com:65535"), Address.Endpoint(host: "node1.example.com", port: 65535))
  try Test.eq(try Address.parse("[::1]:4000"), Address.Endpoint(host: "::1", port: 4000))
  Test.eq(try Address.parse("[fe80::1]:1"), Address.Endpoint(host: "fe80::1", port: 1))
end

def test_a_peer_without_a_host_or_with_a_bad_port_is_refused() -> Result[Void]
  for text in [
    "", "localhost", ":4000", "host:", "host:0", "host:65536", "host:abc", "host:-1", "host:123456", "[]:4000",
  ]
    try Test.error?(Address.parse(text))
  end

  ok()
end

def test_loopback_is_this_machine() -> Result[Void]
  for host in ["localhost", "::1", "127.0.0.1", "127.1.2.3", "127.255.255.255"]
    try Test.eq(Address.loopback?(host), true)
  end

  for host in [
    "", "0.0.0.0", "10.0.0.1", "128.0.0.1", "127.0.0", "127.0.0.1.1", "127.0.0.256", "127.a.0.1", "::", "example.com",
    "127.0.0.1 ",
  ]
    try Test.eq(Address.loopback?(host), false)
  end

  ok()
end
