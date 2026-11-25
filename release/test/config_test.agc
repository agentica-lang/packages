import Config from "../src/config"

private

TOML = "name = \"app\"\n[tool.release]\nversion = \"1.0.0\"\ninclude = [\"assets\"]\n"

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def test_the_config_has_defaults_and_the_command_line_wins() -> Result[Void]
  plain = try Config.parse(TOML, "")
  try must(plain.name == "app" and plain.version == "1.0.0" and plain.entry == "main.agc", "read #{plain}")
  try must(plain.include == ["assets"] and plain.agentica == "", "read #{plain}")
  given = try Config.parse(TOML, "cli.agc")
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
    case Config.parse(text, "")
      ok(config) -> return error("#{text} was read as #{config}")
      error(e) -> try must(e.kind == "release.invalid", "gave #{e.kind}")
    end
  end

  ok()
end

def test_a_library_found_by_name_is_listed() -> Result[Void]
  config = try Config.parse(
    TOML + "[native.x]\nlinux = { system = \"libx.so\" }\nmacos = { system = \"libx.dylib\" }\n",
    "",
  )

  must(config.system_libraries == ["libx.dylib", "libx.so"], "read #{config.system_libraries}")
end
