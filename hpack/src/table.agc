import Static from "static"
import {Header} from "types"

struct Dynamic
  entries: List[Header] = []
  size: Int = 0
  capacity: Int = 4096
end

struct Match
  name_index: Int = 0
  field_index: Int = 0
end

def get(table: Dynamic, index: Int, offset: Int) -> Result[Header]
  static_count = Static.ENTRIES.size
  return ok(Static.ENTRIES[index - 1]) if index > 0 and index <= static_count

  if index > static_count and index - static_count <= table.entries.size
    return ok(table.entries[table.entries.size - (index - static_count)])
  end

  error("invalid hpack index #{index} at byte #{offset}", kind: "hpack.index")
end

def match_static(header: Header) -> Match
  name_index = 0
  for i in 0...Static.ENTRIES.size
    entry = Static.ENTRIES[i]
    next if header.name != entry.name
    if name_index == 0
      name_index = i + 1
    end

    if not header.never_indexed and header.value == entry.value
      return Match(name_index: name_index, field_index: i + 1)
    end
  end

  Match(name_index: name_index)
end

def resize(table: Dynamic, capacity: Int) -> Dynamic = trim(table, capacity, capacity)

def insert(table: Dynamic, header: Header) -> Dynamic
  weight = entry_size(header)
  return Dynamic(capacity: table.capacity) if weight > table.capacity
  kept = trim(table, table.capacity - weight, table.capacity)
  Dynamic(entries: kept.entries.push(header), size: kept.size + weight, capacity: table.capacity)
end

def entry_size(header: Header) -> Int = header.name.size + header.value.size + 32

private

def trim(table: Dynamic, limit: Int, capacity: Int) -> Dynamic
  size = table.size
  removed = 0
  while size > limit
    size = size - entry_size(table.entries[removed])
    removed = removed + 1
  end

  entries = table.entries
  if removed > 0
    entries = entries.drop(removed)
  end

  Dynamic(entries: entries, size: size, capacity: capacity)
end
