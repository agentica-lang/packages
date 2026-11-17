import DNS from "../dns"

private

def tcp(port: Int) -> DNS.Server = DNS.Server.Tcp("127.0.0.1", port)

def refused?(result: Result[DNS.Resolver]) -> Bool
  case result
    ok(_) -> false
    error(e) -> e.is_a?(DNS.MALFORMED)
  end
end

def test_a_resolver_needs_a_server_and_a_valid_port() -> Result[Void]
  try Test.assert(DNS.resolver([tcp(53)]).ok?, "one server")
  try Test.assert(refused?(DNS.resolver([])), "no server")
  try Test.assert(refused?(DNS.resolver([tcp(0)])), "port 0")
  try Test.assert(refused?(DNS.resolver([tcp(65_536)])), "port 65536")
  try Test.assert(refused?(DNS.resolver([DNS.Server.Tcp("", 53)])), "no host")
  try Test.assert(refused?(DNS.resolver([DNS.Server.Tls("", 853, "name")])), "no host over TLS")
  many: List[DNS.Server] = []
  for port in 1..17
    many = many.push(tcp(port))
  end

  Test.assert(refused?(DNS.resolver(many)), "17 servers")
end

def test_the_options_are_bounded() -> Result[Void]
  servers = [tcp(53)]
  try Test.assert(DNS.resolver(servers, DNS.Options(timeout_ms: DNS.MAX_TIMEOUT_MS, max_cnames: 32)).ok?, "the limits")
  try Test.assert(refused?(DNS.resolver(servers, DNS.Options(timeout_ms: 0))), "timeout 0")
  try Test.assert(
    refused?(DNS.resolver(servers, DNS.Options(timeout_ms: DNS.MAX_TIMEOUT_MS + 1))),
    "a timeout over a day",
  )

  try Test.assert(refused?(DNS.resolver(servers, DNS.Options(max_cnames: -1))), "max_cnames -1")
  Test.assert(refused?(DNS.resolver(servers, DNS.Options(max_cnames: 33))), "max_cnames 33")
end
