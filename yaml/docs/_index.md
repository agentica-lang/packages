---
title: yaml
description: A YAML 1.2 parser. Read configuration files and fixtures into JSON values, with the core schema only, limits against hostile texts, and errors with a line and a column.
---

`yaml` reads YAML 1.2 text into Agentica's `JSON.Value`. From there, `JSON.decode` turns it into your records, so a configuration file or a test fixture can be YAML. It is pure Agentica and does no I/O: give it the text.

It is safe by design. It reads the core schema only, so a document gives data and nothing else: any tag other than the core ones is an error, and limits stop deep nesting, alias bombs and huge texts before they use the stack or the memory.

```agentica
import YAML from "pkg/yaml/yaml"

TEXT = <<~YAML
  # The settings of the app
  name: shop
  debug: false
  servers:
    - host: a.example.com
      port: 8080
      tags: &web [web, eu]
    - {host: b.example.com, port: 0x1F90, tags: *web}
YAML

struct Server
  host: String
  port: Int
  tags: List[String]
end

struct Config
  name: String
  debug: Bool
  servers: List[Server]
end

def load(text: String) -> Result[Config]
  value = try YAML.parse(text)
  JSON.decode(value, Config)
end

def main() -> Void
  case load(TEXT)
    ok(config) -> puts("#{config.name}: #{config.servers.map(->(s) { "#{s.host}:#{s.port} #{s.tags}" }).join(", ")}")
    error(e) -> puts(e.message)
  end

  case YAML.parse("name: shop\n  debug: [true")
    ok(value) -> puts(value)
    error(e) -> puts("#{e.kind} at #{e.details["line"]}:#{e.details["column"]}: #{e.message}")
  end
end
```

```output
shop: a.example.com:8080 ["web", "eu"], b.example.com:8080 ["web", "eu"]
yaml.parse at 2:8: line 2, column 8: mapping values are not allowed here
```

## Install

Needs Agentica 0.32.0 or later. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add yaml https://github.com/agentica-lang/packages --tag yaml-0.1.0 --subdir yaml
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
yaml = { git = "https://github.com/agentica-lang/packages", tag = "yaml-0.1.0", subdir = "yaml" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/yaml/CHANGELOG.md).

## Reference

Everything is under `YAML`, from `import YAML from "pkg/yaml/yaml"`.

```text
YAML.parse(text: String, options: YAML.Options = YAML.Options()) -> Result[JSON.Value]
YAML.parse_all(text: String, options: YAML.Options = YAML.Options()) -> Result[List[JSON.Value]]
```

- `YAML.parse` reads a text of one document. A text with no document (empty, or only comments) is `null`; a second document is an error.
- `YAML.parse_all` reads a stream: the documents between `---` and `...` markers, in order, with their `%YAML` and `%TAG` directives.

`YAML.Options` holds the limits; give only the ones you change, as in `YAML.Options(max_bytes: 16_777_216)`:

| Field | Default | What it limits |
|---|---|---|
| `max_depth` | 256 | the nested collections, aliases included, 1 to 1000 (another value is an `argument` error) |
| `max_alias_nodes` | 100,000 | the nodes that aliases add, counted as if each alias were a copy of its anchor |
| `max_alias_bytes` | 10,485,760 | the bytes of scalars and keys that aliases add, counted the same way |
| `max_bytes` | 4,194,304 | the bytes of the text, checked before any parsing |

## What it reads

All of YAML 1.2 that has a JSON value:

- block and flow mappings and sequences, explicit keys (`? key`), and compact forms (`- name: x`);
- every scalar style: plain, single-quoted, double-quoted with all its escapes, literal `|` and folded `>` with the chomping (`-`, `+`) and indentation indicators;
- comments, anchors `&a` and aliases `*a`, documents, and the `%YAML` and `%TAG` directives.

A plain scalar takes its type from the core schema: `null`, `~` and an empty value are null; `true` and `false` (also `True`, `TRUE`, ...) are booleans; `42`, `-7`, `0x1F` and `0o17` are integers (one past 64 bits keeps its exact digits); `1.5`, `.5` and `1e3` are floats; anything else is a string. `yes`, `no`, `on` and `off` are strings, as in YAML 1.2. A quoted or block scalar is always a string. The core tags pick a type: `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq`, `!!map`, and `!` (a string).

## Errors

A failure is an `error` whose message starts with the line and the column (from 1, in characters), which `e.details` also has as `"line"` and `"column"`. Its kind is `yaml.parse` for a text that is not valid, or that has no JSON value, and `yaml.limit` for a text over a limit of the options. These are errors:

- a tag other than the core ones (`!foo`, `!!set`, `!!binary`, `!!timestamp`): no document builds anything but data;
- a mapping key that is not a string (`200: ok`, `[a, b]: c`, an empty key), since JSON keys are strings: quote it (`"200": ok`);
- a key given twice in one mapping;
- `.inf`, `-.inf` and `.nan`, and a float that does not fit, since JSON has no infinity or NaN;
- an alias with no anchor before it.

Not read, for now: writing YAML, the YAML 1.1 extras (`yes` and `no` as booleans, `<<` merge keys, sexagesimal numbers) and custom tags.
