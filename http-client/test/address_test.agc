import Address from "../src/address"

private

def test_ip_literals_are_read_as_inet_pton_reads_them() -> Result[Void]
  try Test.eq(Address.parse("192.168.1.20"), some([192, 168, 1, 20]))
  try Test.eq(Address.parse("::1"), some([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
  try Test.eq(
    Address.parse("2001:DB8::ff00:42:8329"),
    some([32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 255, 0, 0, 66, 131, 41]),
  )

  try Test.eq(Address.parse("::ffff:10.0.0.1"), some([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 10, 0, 0, 1]))
  try Test.eq(Address.parse("1:2:3:4:5:6:7:8"), some([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8]))
  for bad in [
    "", "1.2.3", "1.2.3.256", "01.2.3.4", "1.2.3.4.5", "a.b.c.d", "1::2::3", "1:2:3:4:5:6:7:8:9", "12345::",
    "fe80::1%eth0", "api.test", "1:2:3:4:5:6:7::8",
  ]
    try Test.eq("#{bad} #{Address.parse(bad).some?}", "#{bad} false")
  end

  try Test.eq(Address.literal?("[::1]"), true)
  Test.eq(Address.literal?("example.com"), false)
end

def test_a_mapped_address_is_its_ipv4_address_for_connect_to() -> Result[Void]
  try Test.eq(Address.unmapped("::ffff:127.0.0.1"), "127.0.0.1")
  try Test.eq(Address.unmapped("::FFFF:7f00:1"), "127.0.0.1")
  try Test.eq(Address.unmapped("0:0:0:0:0:ffff:93.184.216.34"), "93.184.216.34")
  for kept in ["93.184.216.34", "::1", "2001:db8::1", "64:ff9b::1.2.3.4", "::ffff:0:1.2.3.4", "api.test"]
    try Test.eq(Address.unmapped(kept), kept)
  end

  ok()
end

def test_only_global_unicast_addresses_are_public() -> Result[Void]
  public = [
    "8.8.8.8", "1.1.1.1", "100.63.255.255", "172.32.0.1", "2606:4700:4700::1111", "2a00:1450::1", "::ffff:8.8.8.8",
    "64:ff9b::808:808", "2002:808:808::1",
  ]

  not_public = [
    "0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.8",
    "192.0.2.1", "192.168.0.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::",
    "::1", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::127.0.0.1", "64:ff9b::a00:1", "64:ff9b:1::1", "100::1",
    "2001::1", "2001:db8::1", "2002:a00:1::1", "fc00::1", "fd12:3456::1", "fe80::1", "fec0::1", "ff02::1",
    "3fff::1:0:0:0:0", "4000::1", "not an ip",
  ]

  for address in public
    try Test.eq("#{address} #{Address.public?(address)}", "#{address} true")
  end

  for address in not_public
    try Test.eq("#{address} #{Address.public?(address)}", "#{address} false")
  end

  ok()
end
