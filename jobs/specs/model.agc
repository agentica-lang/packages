## An independent reference model of the memory backend, for the differential scenario of memory.feature: it makes a
## script of random calls on a manual clock, with the reply that the contract gives to each one, and the memory backend
## must answer the same. The contract (docs/contract.md) leaves some things open that the memory backend fixes, and the
## model fixes them in the same way: jobs come by `run_at_ms` and then by insertion, and a duplicate key is answered
## before `max_jobs` is looked at.
##
## It imports nothing of the package: no heap, no store, no rules of `settle`. The jobs are a plain list that each call
## scans, so nothing here can share a mistake with the code under test. A random number comes from a generator of its
## own, so that a seed gives the same script on every run.

import {Add, Backoff, Batch, Extension, Request, Take} from "protocol"

## One call of the script: the request, and the reply that the contract gives to it.
struct Call
  req: Request
  reply: String
end

## The script of `count` random calls after the one that starts the backend (`max_jobs` 8, so that it fills up).
def script(seed: Int, count: Int) -> List[Call]
  gen: ATS[String, Int] = ATS.new()
  gen.put(STATE, seed % MODULUS + SALT)
  start = Request.Start(settings([["max_jobs", "8"], ["max_dead", "1000"]]))
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
GROUPS = ["", "", "g1", "g2", "g3"]
LIMITS = [0, 0, 1, 2]
LEASES = [1_000, 5_000, 30_000]
STEPS = [1, 500, 1_000, 1_001, 5_000, 60_000]
AMOUNTS = [1, 500, 1_000, 5_000, 60_000]
ATTEMPTS = [1, 2, 3, 5]
DELAYS = [0, 0, 0, 1_000, 5_000, 60_000]
KINDS = ["ack", "ack", "retry", "release", "kill", "extend"]
MAXES = [1, 1, 2, 3]
WHYS = ["", "", "boom", "the server is down"]
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
  last_error: String
  group: String
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
  again: Again
end

# The queue and the key of the job that went back last, so that the script asks for that key again soon: a key that
# is taken, or free, after a retry or a release.
struct Again
  queue: String
  key: String
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
  return again_request(gen, world, serial) if world.again.key != "" and roll < 60

  return enqueue_request(gen, serial) if roll < 24

  return enqueue_all_request(gen, serial) if roll < 28

  return fetch_request(gen) if roll < 52

  if roll < 72 and not world.held.empty?
    kind = pick(gen, KINDS)
    name = pick(gen, world.held.keys)
    amount = pick(gen, AMOUNTS)
    return lease_request(kind, name, amount, pick(gen, WHYS))
  end

  return Request.Advance(pick(gen, STEPS)) if roll < 86

  Request.Counts(pick(gen, QUEUES))
end

# A call on the lease that a name holds: `amount` is the ms of a retry or an extend, and `why` the error of a retry.
def lease_request(kind: String, name: String, amount: Int, why: String) -> Request
  case kind
    "ack" -> Request.Ack(name)
    "kill" -> Request.Kill(name)
    "release" -> Request.Release(name)
    "extend" -> Request.Extend(Extension(name: name, ms: amount))
    _ -> Request.Retry(Backoff(name: name, ms: amount, why: why))
  end
end

def enqueue_request(gen: ATS[String, Int], serial: Int) -> Request
  enqueue_with(gen, serial, pick(gen, QUEUES), pick(gen, KEYS))
end

def again_request(gen: ATS[String, Int], world: World, serial: Int) -> Request
  enqueue_with(gen, serial, world.again.queue, world.again.key)
end

def fetch_request(gen: ATS[String, Int]) -> Request
  Request.Fetch(
    Take(
      queue: pick(gen, QUEUES),
      name: pick(gen, NAMES),
      lease_ms: pick(gen, LEASES),
      max: pick(gen, MAXES),
      limit: pick(gen, LIMITS),
    ),
  )
end

# Two or three jobs in one batch.
def enqueue_all_request(gen: ATS[String, Int], serial: Int) -> Request
  payloads = (0...(2 + draw(gen, 2))).map(->(n) { "p#{serial}x#{n}" })
  Request.EnqueueAll(Batch(queue: pick(gen, QUEUES), text: payloads.join(",")))
end

def enqueue_with(gen: ATS[String, Int], serial: Int, queue: String, key: String) -> Request
  attempts = pick(gen, ATTEMPTS)
  delay = pick(gen, DELAYS)
  rows = [["max_attempts", "#{attempts}"]]
  if delay > 0
    rows = rows.push(["run_in_ms", "#{delay}"])
  end

  if key != ""
    rows = rows.push(["unique_key", key])
  end

  group = pick(gen, GROUPS)
  if group != ""
    rows = rows.push(["group", group])
  end

  Request.Enqueue(Add(queue: queue, text: "p#{serial}", table: settings(rows)))
end

# The world after a call, and the reply of the contract to it. A lease that ran out is over before any call.
def apply(before: World, req: Request) -> Step
  world = tick(before)
  case req
    Request.Start(table) -> Step(world: empty(number(table, "max_jobs", MAX_JOBS)), reply: "ok")
    Request.Enqueue(add) -> enqueue(world, add)
    Request.EnqueueAll(batch) -> enqueue_all(world, batch)
    Request.Fetch(take) -> fetch(world, take)
    Request.Advance(ms) -> Step(world: world.with(now: world.now + ms), reply: "ok")
    Request.Counts(queue) -> Step(world: world, reply: counts(world, queue))
    Request.Ack(name) -> on_lease(world, name, ->(item) { remove(world, item) })
    Request.Kill(name) -> on_lease(world, name, ->(item) { bury(world, item) })
    Request.Release(name) ->
      on_lease(
        world,
        name,
        ->(item) { back_again(replace(world, item.with(attempt: item.attempt - 1, token: 0)), item) },
      )
    Request.Extend(extension) ->
      on_lease(world, extension.name, ->(item) { replace(world, item.with(expires: world.now + extension.ms)) })
    Request.Retry(backoff) -> on_lease(world, backoff.name, ->(item) { retry(world, item, backoff) })
    _ -> Step(world: world, reply: "the model does not know this call")
  end
end

def number(table: List[List[String]], name: String, default: Int) -> Int
  rows = table.filter(->(row) { row[0] == name })
  return default if rows.empty?

  rows[0][1].to_i.unwrap_or(default)
end

def text(table: List[List[String]], name: String) -> String
  rows = table.filter(->(row) { row[0] == name })
  return "" if rows.empty?

  rows[0][1]
end

def empty(max_jobs: Int) -> World
  World(
    now: 0,
    max_jobs: max_jobs,
    jobs: [],
    dead: [],
    held: {},
    next_id: 1,
    next_token: 1,
    again: Again(queue: "", key: ""),
  )
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

def enqueue(world: World, add: Add) -> Step
  key = text(add.table, "unique_key")
  twin = world.jobs.find(->(item) { key != "" and item.queue == add.queue and item.key == key })
  case twin
    ok(item) -> return Step(world: forgotten(world), reply: "ok #{item.id} duplicate")
    error(_) -> nil
  end

  return Step(world: forgotten(world), reply: "error jobs.full") if world.jobs.size >= world.max_jobs

  item = new_item(world, world.next_id, add, key)
  added = world.with(jobs: world.jobs.push(item), next_id: world.next_id + 1)
  Step(world: forgotten(added), reply: "ok #{item.id}")
end

# The batch adds all its jobs, or none when they do not fit.
def enqueue_all(world: World, batch: Batch) -> Step
  payloads = batch.text.split(",")
  return Step(world: forgotten(world), reply: "error jobs.full") if world.jobs.size + payloads.size > world.max_jobs

  items = (0...payloads.size).map(
    ->(n) { new_item(world, world.next_id + n, Add(queue: batch.queue, text: payloads[n]), "") },
  )

  added = world.with(jobs: world.jobs + items, next_id: world.next_id + payloads.size)
  Step(world: forgotten(added), reply: "ok #{items.map(->(item) { "#{item.id}" }).join(",")}")
end

def new_item(world: World, id: Int, add: Add, key: String) -> Item
  Item(
    id: id,
    queue: add.queue,
    payload: add.text,
    max_attempts: number(add.table, "max_attempts", 5),
    run_at: world.now + number(add.table, "run_in_ms", 0),
    key: key,
    attempt: 0,
    token: 0,
    expires: 0,
    last_error: "",
    group: text(add.table, "group"),
  )
end

def forgotten(world: World) -> World = world.with(again: Again(queue: "", key: ""))

# The jobs that come first, up to `max`: the earliest time, then the first added. A job whose group already has `limit`
# live leases in its queue is passed over, when there is a limit; the leases of this call count.
def fetch(world: World, take: Take) -> Step
  ready = world.jobs.filter(->(item) { item.queue == take.queue and item.token == 0 and item.run_at <= world.now })
  state = world
  texts: List[String] = []
  for item in ready.sort_by(->(one) { one.run_at * 1_000_000 + one.id })
    if texts.size < take.max and not full?(state, item, take.limit)
      state = lend(state, item, lease_name(take.name, texts.size), take.lease_ms)
      texts = texts.push(delivery_text(item))
    end
  end

  return Step(world: world, reply: "ok none") if texts.empty?

  Step(world: state, reply: "ok #{texts.join(", ")}")
end

def full?(world: World, item: Item, limit: Int) -> Bool
  return false if limit == 0 or item.group == ""

  held = world.jobs.filter(->(one) { one.queue == item.queue and one.group == item.group and one.token != 0 })
  held.size >= limit
end

def lease_name(name: String, position: Int) -> String
  return name if position == 0

  "#{name}/#{position + 1}"
end

def delivery_text(item: Item) -> String
  base = "#{item.payload} attempt #{item.attempt + 1}"
  with_error = case item.last_error
    "" -> base
    _ -> "#{base} last_error #{item.last_error}"
  end

  return with_error if item.group == ""

  "#{with_error} group #{item.group}"
end

def lend(world: World, item: Item, name: String, lease_ms: Int) -> World
  leased = item.with(attempt: item.attempt + 1, token: world.next_token, expires: world.now + lease_ms)
  state = replace(world, leased)
  held = state.held.put(name, Held(id: item.id, token: world.next_token))
  state.with(held: held, next_token: world.next_token + 1)
end

# The call on the delivery that a name holds, which gives the world after it, or a lease that was lost.
def on_lease(world: World, name: String, finish: Fn[Item, World]) -> Step
  case live(world, name)
    none -> Step(world: world, reply: "error jobs.lease_lost")
    some(item) -> Step(world: finish.call(item), reply: "ok")
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

# A retry on the last attempt is the end of the job. One that says nothing keeps the last error.
def retry(world: World, item: Item, backoff: Backoff) -> World
  return bury(world, item) if item.attempt >= item.max_attempts

  last_error = case backoff.why
    "" -> item.last_error
    _ -> backoff.why
  end

  back_again(replace(world, item.with(run_at: world.now + backoff.ms, token: 0, last_error: last_error)), item)
end

def back_again(world: World, item: Item) -> World = world.with(again: Again(queue: item.queue, key: item.key))

def counts(world: World, queue: String) -> String
  mine = world.jobs.filter(->(item) { item.queue == queue })
  leased = mine.filter(->(item) { item.token != 0 }).size
  waiting = mine.filter(->(item) { item.token == 0 })
  ready = waiting.filter(->(item) { item.run_at <= world.now }).size
  dead = world.dead.filter(->(one) { one == queue }).size
  "ready #{ready} scheduled #{waiting.size - ready} leased #{leased} dead #{dead}"
end
