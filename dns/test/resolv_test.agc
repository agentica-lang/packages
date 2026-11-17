import DNS from "../dns"

private

def hosts(servers: List[DNS.Server]) -> List[String]
  servers.map do |server|
    case server
      DNS.Server.Tcp(host, port) -> "#{host}:#{port}"
      _ -> "other"
    end
  end
end

def test_a_resolv_conf_gives_its_nameservers_in_order() -> Result[Void]
  lines = [
    "# comment",
    "search example.com",
    "nameserver 192.0.2.1",
    "  NameServer\t2001:db8::1 # the second",
    "nameserver fe80::1%eth0",
    "options timeout:2",
    "nameserver 192.0.2.3",
    "nameserver 192.0.2.4",
  ]

  text = lines.join("\n")

  Test.eq(hosts(DNS.parse_resolv_conf(text)), ["192.0.2.1:53", "2001:db8::1:53", "192.0.2.3:53"])
end

def test_a_resolv_conf_without_a_nameserver_is_an_error() -> Result[Void]
  try Test.eq(DNS.parse_resolv_conf("search example.com\nnameserver\n").length, 0)
  Test.assert(not DNS.system_servers("/nonexistent/resolv.conf").ok?, "a file that is not there")
end

def test_the_file_is_read_only_when_asked() -> Result[Void]
  path = "resolv_test_#{OpenSSL.Random.hex(4)}.conf"
  try File.write_text(path, "nameserver 192.0.2.9\n")
  found = DNS.system_servers(path)
  _ = Path.remove(path)
  Test.eq(hosts(try found), ["192.0.2.9:53"])
end

def test_a_resolver_takes_https_servers_with_an_https_url_only() -> Result[Void]
  try Test.assert(DNS.resolver([DNS.Server.Https("https://dns.example/dns-query")]).ok?, "an https URL")
  try Test.assert(not DNS.resolver([DNS.Server.Https("http://dns.example/dns-query")]).ok?, "an http URL")
  Test.assert(not DNS.resolver([DNS.Server.Https("https://")]).ok?, "no host")
end
