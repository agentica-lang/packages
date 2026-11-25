import Config from "../src/config"

private

TOML = "name = \"app\"\n[tool.release]\nversion = \"1.0.0\"\ninclude = [\"assets\"]\n"

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def test_the_config_has_defaults_and_the_command_line_wins() -> Result[Void]
  plain = try Config.parse(TOML, "", "")
  try must(plain.name == "app" and plain.version == "1.0.0" and plain.entry == "main.agc", "read #{plain}")
  try must(plain.include == ["assets"] and plain.agentica == "", "read #{plain}")
  given = try Config.parse(TOML, "2.0.0", "cli.agc")
  must(given.version == "2.0.0" and given.entry == "cli.agc", "read #{given}")
end

def test_a_name_that_is_a_path_or_a_library_stored_by_path_is_refused() -> Result[Void]
  for text in [
    "name = \"a/b\"\n[tool.release]\nversion = \"1\"\n",
    TOML + "[native.x]\nlinux = { file = \"native/x.so\" }\n",
  ]
    case Config.parse(text, "", "")
      ok(config) -> return error("#{text} was read as #{config}")
      error(e) -> try must(e.kind == "release.invalid", "gave #{e.kind}")
    end
  end

  ok()
end
