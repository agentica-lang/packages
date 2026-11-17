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

def test_lines_that_end_with_a_carriage_return_and_other_white_space_are_read() -> Result[Void]
  text = "nameserver 1.1.1.1\r\nnameserver\t\t2606:4700::1111  \r\n\tnameserver 9.9.9.9 \r"
  Test.eq(hosts(DNS.parse_resolv_conf(text)), ["1.1.1.1:53", "2606:4700::1111:53", "9.9.9.9:53"])
end

def test_only_ip_literals_are_nameservers() -> Result[Void]
  good = ["1.1.1.1", "255.0.0.0", "::1", "::", "2001:db8::1", "1:2:3:4:5:6:7:8", "::ffff:1.2.3.4", "1::", "fe80::1"]
  for address in good
    try Test.eq(hosts(DNS.parse_resolv_conf("nameserver #{address}")), ["#{address}:53"])
  end

  bad = [
    "localhost",
    "-bad",
    "http://x",
    "1.1.1",
    "1.1.1.1.1",
    "256.1.1.1",
    "01.1.1.1",
    "1.1.1.a",
    ":::",
    "1:2:3:4:5:6:7",
    "1:2:3:4:5:6:7:8:9",
    "1::2::3",
    "12345::1",
    "g::1",
    ":1:2:3:4:5:6:7",
    "1:2:3:4:5:6:7::8",
    "fe80::1%eth0",
    "1.2.3.4::1",
  ]

  for address in bad
    try Test.eq(hosts(DNS.parse_resolv_conf("nameserver #{address}")), [])
  end

  ok()
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
