## The tables that tie the emitters to the handlers. The hub is the only task that writes them, so a route list is
## never changed by two tasks at once, and an emitter only reads (a read takes no lock). A table holds data only, so a
## route has the address of its handler, not the function.

import Names from "names"
import Types from "types"

# The routes of each pattern, in the order the handlers were attached.
ROUTES: ATS[String, List[Types.Route]] = ATS.new()
# The address of each handler, by id.
HANDLERS: ATS[String, Address[Types.Msg]] = ATS.new()
# The ids of the tasks of the handlers, to refuse a `flush` from inside one.
TASKS: ATS[Int, Int] = ATS.new()
# The events a handler's full queue refused, by id. The count stays after a detach, until the id is attached again.
DROPPED: ATS[String, Int] = ATS.new()
# The address of the hub, under one key.
HUB: ATS[String, Address[Types.HubMsg]] = ATS.new()
HUB_KEY = "hub"
# Held by the task that is starting a hub, so two starts never run at once.
STARTING: ATS[String, Int] = ATS.new()

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

## True in the task of a handler: a call that waits for the handlers would wait for itself.
def in_handler?() -> Bool = TASKS.has_key?(Task.current().id)

## Counts an event that the full queue of the handler `id` refused. An id that was detached is not counted again.
def count_drop(id: String) -> Void
  if DROPPED.has_key?(id)
    _ = DROPPED.add(id, 1)
  end
end

## The address of the hub, if there is one.
def hub() -> Optional[Address[Types.HubMsg]]
  case HUB.get(HUB_KEY)
    ok(address) -> some(address)
    error(_) -> none
  end
end

## The hub adds a handler to the route of each pattern.
def add(id: String, patterns: List[String], address: Address[Types.Msg], task: Int) -> Void
  for pattern in patterns
    ROUTES.put(pattern, routes_of(pattern).push(Types.Route(id: id, address: address)))
  end

  HANDLERS.put(id, address)
  TASKS.put(task, 1)
  DROPPED.put(id, 0)
end

## The hub takes a handler off its routes; a pattern with no route left is deleted, so `idle?` is true again.
def remove(id: String, patterns: List[String], task: Int) -> Void
  for pattern in patterns
    kept = routes_of(pattern).select(->(route) { route.id != id })
    if kept.empty?
      ROUTES.delete(pattern)
    else
      ROUTES.put(pattern, kept)
    end
  end

  HANDLERS.delete(id)
  TASKS.delete(task)
end

## The hub forgets every handler.
def clear() -> Void
  ROUTES.clear()
  HANDLERS.clear()
  TASKS.clear()
  DROPPED.clear()
end

## Forgets the handlers and the hub at `address`, which has ended. A hub that started since is not touched.
def forget_hub(address: Address[Types.HubMsg]) -> Void
  case hub()
    some(current) if current == address ->
      clear()
      HUB.delete(HUB_KEY)
    _ -> nil
  end
end

private

def routes_of(pattern: String) -> List[Types.Route]
  case ROUTES.get(pattern)
    ok(routes) -> routes
    error(_) -> []
  end
end
