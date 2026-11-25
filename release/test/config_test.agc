import Config from "../src/config"

private

TOML = "name = \"app\"\n[tool.release]\nversion = \"1.0.0\"\ninclude = [\"assets\"]\n"

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def test_the_config_has_defaults_and_the_command_line_wins() -> Result[Void]
  plain = try Config.parse(TOML, "", "linux")
  try must(plain.name == "app" and plain.version == "1.0.0" and plain.entry == "main.agc", "read #{plain}")
  try must(plain.include == ["assets"], "read #{plain}")
  given = try Config.parse(TOML, "cli.agc", "linux")
  must(given.version == "1.0.0" and given.entry == "cli.agc", "read #{given}")
end

def test_a_name_a_path_or_a_native_shape_that_cannot_travel_is_refused() -> Result[Void]
  head = "name = \"app\"\n[tool.release]\nversion = \"1\"\n"
  for text in [
    "name = \"a/b\"\n[tool.release]\nversion = \"1\"\n",
    TOML + "[native.x]\nlinux = { file = \"native/x.so\" }\n",
    TOML + "[native.x]\nbuild = { sources = [\"native/x.c\"] }\n",
    TOML + "[native.x]\nlinux = { system = \"libx.so\", extra = 1 }\n",
    TOML + "[native.x]\nplan9 = { system = \"libx.so\" }\n",
    TOML + "[native.x]\nlinux = \"libx.so\"\n",
    head + "include = [\"./assets\"]\n",
    head + "include = [\"assets\", \"assets\"]\n",
    head + "include = [\"assets\", \"assets/more\"]\n",
    head + "include = [\"lib/data\"]\n",
  ]
    case Config.parse(text, "", "linux")
      ok(config) -> return error("#{text} was read as #{config}")
      error(e) -> try must(e.kind == "release.invalid", "gave #{e.kind}")
    end
  end

  ok()
end

def test_only_the_libraries_of_the_system_are_listed_once() -> Result[Void]
  text = (
    TOML +
    "[native.x]\nlinux = { system = \"libx.so\" }\nmacos = { system = [\"libx.dylib\", \"/opt/lib/libx.dylib\"] }\n" +
    "[native.y]\nlinux = { system = \"libx.so\" }\nwindows = { system = \"y.dll\" }\n"
  )

  linux = try Config.parse(text, "", "linux")
  macos = try Config.parse(text, "", "macos")
  try must(linux.system_libraries == ["libx.so"], "read #{linux.system_libraries}")
  must(macos.system_libraries == ["libx.dylib or /opt/lib/libx.dylib"], "read #{macos.system_libraries}")
end

def test_a_list_of_candidates_must_be_strings() -> Result[Void]
  for list in ["[]", "[1]", "[\"a\", 2]"]
    case Config.parse(TOML + "[native.x]\nlinux = { system = #{list} }\n", "", "linux")
      ok(config) -> return error("#{list} was read as #{config}")
      error(e) -> try must(e.kind == "release.invalid", "gave #{e.kind}")
    end
  end

  ok()
end
