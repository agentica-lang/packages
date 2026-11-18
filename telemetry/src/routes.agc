## The tables that tie the emitters to the handlers. The hub is the only task that writes them, so a route list is
## never changed by two tasks at once, and an emitter only reads (a read takes no lock). A table holds data only, so a
## route has the address of its handler, not the function.

import Names from "names"
import Types from "types"

# The routes of each pattern, in the order the handlers were attached.
ROUTES: ATS[String, List[Types.Route]] = ATS.new()
# The address of each handler, by id.
HANDLERS: ATS[String, Address[Types.Msg]] = ATS.new()
# The events a handler's full queue refused, by id.
DROPPED: ATS[String, Int] = ATS.new()
# The address of the hub, under one key.
HUB: ATS[String, Address[Types.HubMsg]] = ATS.new()
HUB_KEY = "hub"

## True while no handler is attached: the whole cost of an event nobody hears.
def idle?() -> Bool = ROUTES.size == 0

## The handlers that hear an event, each once, in the order of their patterns.
def matching(name: String) -> List[Types.Route]
  heard: List[Types.Route] = []
  seen: Map[String, Bool] = {}
  for pattern in Names.matching_patterns(name)
    for route in routes_of(pattern)
      if not seen.has_key?(route.id)
        seen = seen.put(route.id, true)
        heard = heard.push(route)
      end
    end
  end

  heard
end

## True when some handler hears an event of this name.
def heard?(name: String) -> Bool
  return false if idle?()

  Names.matching_patterns(name).any?(->(pattern) { ROUTES.has_key?(pattern) })
end

## The ids of the handlers, sorted.
def handler_ids() -> List[String] = HANDLERS.keys().sort()

## The address of the hub, if there is one.
def hub() -> Optional[Address[Types.HubMsg]]
  case HUB.get(HUB_KEY)
    ok(address) -> some(address)
    error(_) -> none
  end
end

## The hub adds a handler to the route of each pattern.
def add(id: String, patterns: List[String], address: Address[Types.Msg]) -> Void
  for pattern in patterns
    ROUTES.put(pattern, routes_of(pattern).push(Types.Route(id: id, address: address)))
  end

  HANDLERS.put(id, address)
  DROPPED.put(id, 0)
end

## The hub takes a handler off its routes; a pattern with no route left is deleted, so `idle?` is true again.
def remove(id: String, patterns: List[String]) -> Void
  for pattern in patterns
    kept = routes_of(pattern).select(->(route) { route.id != id })
    if kept.empty?
      ROUTES.delete(pattern)
    else
      ROUTES.put(pattern, kept)
    end
  end

  HANDLERS.delete(id)
  DROPPED.delete(id)
end

## The hub forgets every handler.
def clear() -> Void
  ROUTES.clear()
  HANDLERS.clear()
  DROPPED.clear()
end

## Forgets the handlers and the hub, for a start that finds a hub that is gone.
def reset() -> Void
  clear()
  HUB.clear()
end

private

def routes_of(pattern: String) -> List[Types.Route]
  case ROUTES.get(pattern)
    ok(routes) -> routes
    error(_) -> []
  end
end
