import BDD from "std/bdd"
import Dial from "../../src/dial"
import HTTP from "std/http"
import Pools from "../../src/pools"

def idle(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  before = Task.pending_count()
  time: ATS[String, Int] = ATS.new()
  time.put("now", 0)
  dialer = Dial.Dialer(own: false, resolver: ->(_host) { ok([]) }, cache: ATS.new(), cache_ms: 0, public_only: false)
  pools = Pools.start(
    Pools.Settings(
      size: 1,
      wait_ms: 100,
      idle_ms: 100,
      health_ms: 100,
      options: HTTP.ClientOptions(),
      dialer: dialer,
      clock: some(-> { time.get("now").unwrap! }),
    ),
  )

  result = eviction(pools, time)
  Pools.close(pools, 0)
  case result
    error(e) -> BDD.assert(ctx, false, e.message)
    ok(_) -> BDD.assert(ctx, Task.pending_count() == before, "pool close left tasks behind")
  end
end

private

WATCHED = "http://127.0.0.1:1"
UNUSED = "http://127.0.0.1:2"

# The unused pool's close proves the sweep ran at the advanced time. Merely checking that a later request succeeds
# would also pass if the old pool never closed.
def eviction(pools: Pools.Pools, time: ATS[String, Int]) -> Result[Void]
  watched = try owner(pools, WATCHED)
  unused = try owner(pools, UNUSED)
  expired: Channel[Bool] = Channel.new(1)
  Task.monitor(unused, expired) do |_down| true end

  release: Channel[Bool] = Channel.new(1)
  ready: Channel[Result[Void]] = Channel.new(1)
  reader = Task.spawn do watch_reader(pools, ready, release) end
  result = kept(pools, watched, ready, expired, time)
  release.close
  _ = Task.await(reader)
  try result

  closed: Channel[Bool] = Channel.new(1)
  Task.monitor(watched, closed) do |_down| true end
  time.put("now", 20_000)
  _ = try closed.recv(2_500)
  replacement = try owner(pools, WATCHED)
  return error("the manager returned the expired pool") if replacement.id == watched.id
  ok()
end

def kept(
  pools: Pools.Pools,
  watched: Task[Void],
  ready: Channel[Result[Void]],
  expired: Channel[Bool],
  time: ATS[String, Int],
) -> Result[Void]
  registered = try ready.recv(2_500)
  try registered
  # A reply to a later message means the manager has registered the reader before the clock advances.
  _ = try owner(pools, WATCHED)
  time.put("now", 10_000)
  _ = try expired.recv(2_500)
  still = try owner(pools, WATCHED)
  return error("the manager evicted a pool with a live stream") if still.id != watched.id
  ok()
end

def watch_reader(pools: Pools.Pools, ready: Channel[Result[Void]], release: Channel[Bool]) -> Result[Bool]
  try ready.send(Pools.watch(pools, Task.current, WATCHED), 0)
  release.recv(3_000)
end

def owner(pools: Pools.Pools, origin: String) -> Result[Task[Void]]
  case try Pools.pool_for(pools, origin, 100)
    Pools.OriginPool.Http1(pool) -> ok(pool.owner)
    Pools.OriginPool.Http2(_) -> error("expected an HTTP/1 pool")
  end
end
