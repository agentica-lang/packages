## An independent model of the jobs contract (docs/contract.md), for the differential scenario of memory.feature: it
## makes a script of random calls on a manual clock, with the reply that the contract gives to each one, and the memory
## backend must answer the same.
##
## It imports nothing of the package: no heap, no store, no rules of `settle`. The jobs are a plain list that each call
## scans, so nothing here can share a mistake with the code under test. A random number comes from a generator of its
## own, so that a seed gives the same script on every run.

import {Request} from "protocol"

## One call of the script: the request, and the reply that the contract gives to it.
struct Call
  req: Request
  reply: String
end

## The script of `count` random calls after the one that starts the backend (`max_jobs` 8, so that it fills up).
def script(seed: Int, count: Int) -> List[Call]
  gen: ATS[String, Int] = ATS.new()
  gen.put(STATE, seed % MODULUS + SALT)
  start = Request(op: "start", table: settings([["max_jobs", "8"], ["max_dead", "1000"]]))
  stepped = apply(empty(MAX_JOBS), start)
  world = stepped.world
  calls = [Call(req: start, reply: stepped.reply)]
  for _step in 0...count
    req = next_request(gen, world, calls.size)
    stepped = apply(world, req)
    world = stepped.world
    calls = calls.push(Call(req: req, reply: stepped.reply))
  end

  calls
end

## The replies that the contract gives to a list of calls, from a fresh backend that the first call starts.
def replies(calls: List[Request]) -> List[String]
  world = empty(MAX_JOBS)
  out: List[String] = []
  for req in calls
    stepped = apply(world, req)
    world = stepped.world
    out = out.push(stepped.reply)
  end

  out
end

private

MAX_JOBS = 8
QUEUES = ["q1", "q2"]
NAMES = ["a", "b", "c", "d"]
KEYS = ["", "", "k1", "k2", "k3"]
LEASES = [1_000, 5_000, 30_000]
STEPS = [1, 500, 1_000, 1_001, 5_000, 60_000]
AMOUNTS = [1, 500, 1_000, 5_000, 60_000]
ATTEMPTS = [1, 2, 3, 5]
DELAYS = [0, 0, 0, 1_000, 5_000, 60_000]
KINDS = ["ack", "ack", "retry", "release", "kill", "extend"]
STATE = "state"
MODULUS = 2_147_483_648
SALT = 7_919

# A job of the model. `key` is "" for no key; `token` is 0 while nobody holds the job, else the number of the delivery
# that does, until `expires`.
struct Item
  id: Int
  queue: String
  payload: String
  max_attempts: Int
  run_at: Int
  key: String
  attempt: Int
  token: Int
  expires: Int
end

# The delivery that a name holds.
struct Held
  id: Int
  token: Int
end

struct World
  now: Int
  max_jobs: Int
  jobs: List[Item]
  dead: List[String]
  held: Map[String, Held]
  next_id: Int
  next_token: Int
end

struct Step
  world: World
  reply: String
end

def settings(rows: List[List[String]]) -> List[List[String]] = [["setting", "value"]] + rows

def draw(gen: ATS[String, Int], limit: Int) -> Int
  state = (gen.get(STATE).unwrap_or(1) * 1_103_515_245 + 12_345) % MODULUS
  gen.put(STATE, state)
  (state / 65_536) % limit
end

def pick[T](gen: ATS[String, Int], choices: List[T]) -> T = choices[draw(gen, choices.size)]

# A random call. The names that hold a lease are the ones that a lease call can use, stale or not.
def next_request(gen: ATS[String, Int], world: World, serial: Int) -> Request
  roll = draw(gen, 100)
  return enqueue_request(gen, serial) if roll < 28

  return Request(op: "fetch", queue: pick(gen, QUEUES), name: pick(gen, NAMES), number: pick(gen, LEASES)) if roll < 52

  if roll < 72 and not world.held.empty?
    kind = pick(gen, KINDS)
    return Request(op: kind, name: pick(gen, world.held.keys), number: pick(gen, AMOUNTS))
  end

  return Request(op: "advance", number: pick(gen, STEPS)) if roll < 86

  Request(op: "counts", queue: pick(gen, QUEUES))
end

def enqueue_request(gen: ATS[String, Int], serial: Int) -> Request
  queue = pick(gen, QUEUES)
  attempts = pick(gen, ATTEMPTS)
  delay = pick(gen, DELAYS)
  key = pick(gen, KEYS)
  rows = [["max_attempts", "#{attempts}"]]
  if delay > 0
    rows = rows.push(["run_in_ms", "#{delay}"])
  end

  if key != ""
    rows = rows.push(["unique_key", key])
  end

  Request(op: "enqueue", queue: queue, text: "p#{serial}", table: settings(rows))
end

# The world after a call, and the reply of the contract to it. A lease that ran out is over before any call.
def apply(before: World, req: Request) -> Step
  world = tick(before)
  case req.op
    "start" -> Step(world: empty(number(req, "max_jobs", MAX_JOBS)), reply: "ok")
    "enqueue" -> enqueue(world, req)
    "fetch" -> fetch(world, req)
    "advance" -> Step(world: world.with(now: world.now + req.number), reply: "ok")
    "counts" -> Step(world: world, reply: counts(world, req.queue))
    _ -> on_lease(world, req.name, req.op, req.number)
  end
end

def number(req: Request, name: String, default: Int) -> Int
  rows = req.table.filter(->(row) { row[0] == name })
  return default if rows.empty?

  rows[0][1].to_i.unwrap_or(default)
end

def text(req: Request, name: String) -> String
  rows = req.table.filter(->(row) { row[0] == name })
  return "" if rows.empty?

  rows[0][1]
end

def empty(max_jobs: Int) -> World
  World(now: 0, max_jobs: max_jobs, jobs: [], dead: [], held: {}, next_id: 1, next_token: 1)
end

# A lease that ran out is over: the job is back, or dead when that was its last attempt.
def tick(world: World) -> World
  over = world.jobs.filter(->(item) { item.token != 0 and item.expires <= world.now })
  state = world
  for item in over
    if item.attempt >= item.max_attempts
      state = bury(state, item)
    else
      state = replace(state, item.with(token: 0))
    end
  end

  state
end

def replace(world: World, item: Item) -> World = world.with(jobs: world.jobs.map(->(one) { same_or(one, item) }))

def same_or(one: Item, item: Item) -> Item
  return item if one.id == item.id

  one
end

def remove(world: World, item: Item) -> World = world.with(jobs: world.jobs.filter(->(one) { one.id != item.id }))

def bury(world: World, item: Item) -> World
  gone = remove(world, item)
  gone.with(dead: gone.dead.push(item.queue))
end

def enqueue(world: World, req: Request) -> Step
  key = text(req, "unique_key")
  twin = world.jobs.find(->(item) { key != "" and item.queue == req.queue and item.key == key })
  case twin
    ok(item) -> return Step(world: world, reply: "ok #{item.id} duplicate")
    error(_) -> nil
  end

  return Step(world: world, reply: "error jobs.full") if world.jobs.size >= world.max_jobs

  item = Item(
    id: world.next_id,
    queue: req.queue,
    payload: req.text,
    max_attempts: number(req, "max_attempts", 5),
    run_at: world.now + number(req, "run_in_ms", 0),
    key: key,
    attempt: 0,
    token: 0,
    expires: 0,
  )

  added = world.with(jobs: world.jobs.push(item), next_id: world.next_id + 1)
  Step(world: added, reply: "ok #{item.id}")
end

# The job that comes first: the earliest time, then the first added.
def fetch(world: World, req: Request) -> Step
  ready = world.jobs.filter(->(item) { item.queue == req.queue and item.token == 0 and item.run_at <= world.now })
  case ready.min_by(->(item) { item.run_at * 1_000_000 + item.id })
    none -> Step(world: world, reply: "ok none")
    some(item) -> lend(world, item, req.name, req.number)
  end
end

def lend(world: World, item: Item, name: String, lease_ms: Int) -> Step
  leased = item.with(attempt: item.attempt + 1, token: world.next_token, expires: world.now + lease_ms)
  state = replace(world, leased)
  held = state.held.put(name, Held(id: item.id, token: world.next_token))
  Step(
    world: state.with(held: held, next_token: world.next_token + 1),
    reply: "ok #{item.payload} attempt #{leased.attempt}",
  )
end

# ack, retry (`amount` ms from now), release, kill or extend (`amount` ms from now) of the delivery that a name holds.
def on_lease(world: World, name: String, kind: String, amount: Int) -> Step
  case live(world, name)
    none -> Step(world: world, reply: "error jobs.lease_lost")
    some(item) -> Step(world: finish(world, item, kind, amount), reply: "ok")
  end
end

def live(world: World, name: String) -> Optional[Item]
  case world.held.get(name)
    none -> none
    some(held) ->
      case world.jobs.find(->(item) { item.id == held.id and item.token == held.token })
        ok(item) -> some(item)
        error(_) -> none
      end
  end
end

def finish(world: World, item: Item, kind: String, amount: Int) -> World
  case kind
    "ack" -> remove(world, item)
    "kill" -> bury(world, item)
    "release" -> replace(world, item.with(attempt: item.attempt - 1, token: 0))
    "extend" -> replace(world, item.with(expires: world.now + amount))
    _ -> retry(world, item, amount)
  end
end

# A retry on the last attempt is the end of the job.
def retry(world: World, item: Item, amount: Int) -> World
  return bury(world, item) if item.attempt >= item.max_attempts

  replace(world, item.with(run_at: world.now + amount, token: 0))
end

def counts(world: World, queue: String) -> String
  mine = world.jobs.filter(->(item) { item.queue == queue })
  leased = mine.filter(->(item) { item.token != 0 }).size
  waiting = mine.filter(->(item) { item.token == 0 })
  ready = waiting.filter(->(item) { item.run_at <= world.now }).size
  dead = world.dead.filter(->(one) { one == queue }).size
  "ready #{ready} scheduled #{waiting.size - ready} leased #{leased} dead #{dead}"
end
