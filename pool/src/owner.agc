## The owner task of a pool: the one task that holds the state of the workers and the line of callers, and changes it
## one message at a time. It runs no user code: `init`, `ping` and `terminate` run in the keepers (keeper.agc),
## `checkout` in the callers, and `checkin` in the caller when `lease_ms` is 0, else in the keeper (also for a caller
## that is gone), so a slow or crashing function of the spec never stalls the pool or ends it.
##
## It is written by hand on a channel, not with `std/actor`: `Actor.call` does not close its reply channel when it
## gives up and `Actor.reply` drops a send that fails, so a worker lent to a caller that has just given up would be
## lost, and a behaviour has no receive timeout for the deadlines of the pool (agentica-lang/agentica#1523).

import Keeper from "keeper"
import Types from "types"

## The channels that the owner task owns: they close when it ends, however it ends, so that no caller waits for a
## pool that is gone. `ready` answers once, when the start is done or has failed.
struct Chans[W]
  inbox: Channel[Types.Msg[W]]
  ready: Channel[Result[Void]]
end

## New channels for an owner.
def chans[W]() -> Chans[W]
  # A monitor's notice that finds the inbox full is dropped (agentica-lang/agentica#1522), and the end of a task that
  # holds a worker comes only as such a notice, so the inbox has the largest room a channel can have. Room costs
  # nothing until it is used.
  inbox: Channel[Types.Msg[W]] = Channel.new(1_048_576)
  ready: Channel[Result[Void]] = Channel.new(1)
  Chans(inbox: inbox, ready: ready)
end

## Runs the pool until it is closed or its start fails, and keeps `waiting` and `live` in `counts`.
def own[A, W](spec: Types.Spec[A, W], counts: ATS[String, Int], chans: Chans[W]) -> Void
  core = Core(spec: spec, inbox: chans.inbox, ready: chans.ready, counts: counts)
  state = publish(core, top_up(core, fresh(spec, Time.monotonic_ms())))
  if not state.booting
    _ = core.ready.send(ok(), 0)
  end

  ticked = 0
  while not state.done
    case next_msg(core, state)
      ok(msg) -> state = handle(core, state, msg)
      error(_) -> nil
    end

    # The timers and the counts are looked at once a millisecond while messages keep coming, so that a burst pays for
    # them once, and always before the owner waits; a close is looked at after every message.
    now = Time.monotonic_ms()
    if state.closing or now != ticked or core.inbox.empty?
      ticked = now
      state = publish(core, tick(core, state, now))
    end
  end

  _ = publish(core, state)
end

private

# The longest wait for a message when no deadline is nearer.
MAX_WAIT_MS = 60_000
# How long the owner waits before it calls `init` again after a failure, so that a database that is down is not asked
# once for every caller.
INIT_RETRY_MS = 1_000
# How long the keepers have to end their workers once the drain of a close is over; the ones still running are
# cancelled then, and the VM closes the handles they own. It is longer than a keeper gives a ping or a `checkin`
# (HOOK_MS), so that `terminate` runs after one that is in flight.
CLOSE_GRACE_MS = 6_000
WAITING = "waiting"
LIVE = "live"

struct Core[A, W]
  spec: Types.Spec[A, W]
  inbox: Channel[Types.Msg[W]]
  ready: Channel[Result[Void]]
  counts: ATS[String, Int]
end

# A made worker is idle, lent to a caller, given back by a caller that runs `checkin` (`lease_ms` 0), pinged in its
# keeper, or checked in there; a worker on its way out is no longer a slot at all, and its keeper ends it. A lent
# worker has the number of its lease (`seq`), its caller's task id (`holder`), the ticket channel the grant went to
# (`reply`: while the grant is there, the caller has not used the worker) and the task of its body when `lease_ms` is
# above 0 (`runner`).
enum Phase
  Idle
  Lent
  Returning
  Pinging
  Checking
end

struct Slot[W]
  worker: W
  phase: Phase
  orders: Channel[Types.Order]
  seq: Int
  holder: Int
  reply: Optional[Channel[Types.Grant[W]]]
  runner: Optional[TaskRef]
  born_ms: Int
  idle_since_ms: Int
end

struct Keeping
  task: Task[Void]
  slot: Int
end

# `starting` holds the workers whose `init` runs (by slot id, with their keeper's channel), `slots` the made ones and
# `idle` the ids of the idle ones, the most recently given back last: the pool lends that one first, so that a pool
# with more workers than its load keeps using a few of them and the others reach `idle_ms` and `overflow_idle_ms`.
# The line is `waiters` from `head` to `tail` - 1. `keepers` is every keeper task that has not ended, by task id
# (its worker is being made, is alive, or is being ended); `watched` the callers' tasks that the owner monitors.
# `checking` counts the workers that their keeper pings or checks in, which come back soon. `failure` is the last
# `init` error until a worker is made, and `retry_at_ms` when `init` may run again (0: now). `check_at_ms` is the next
# time an overflow worker may be idle long enough to end (0: none), and `tick_ms` the next health tick (0: none). A
# close sets `closing`, the end of the drain (`deadline_ms`) and the callers of `close` (`dones`); `grace_ms` is when
# the keepers left are cancelled.
struct State[W]
  starting: Map[Int, Channel[Types.Order]]
  slots: Map[Int, Slot[W]]
  idle: List[Int]
  waiters: Map[Int, Types.Ticket[W]]
  head: Int
  tail: Int
  keepers: Map[Int, Keeping]
  watched: Set[Int]
  checking: Int
  next_id: Int
  next_seq: Int
  failure: Result[Void]
  retry_at_ms: Int
  check_at_ms: Int
  tick_ms: Int
  booting: Bool
  closing: Bool
  deadline_ms: Int
  dones: List[Channel[Bool]]
  grace_ms: Int
  done: Bool
  shown_waiting: Int
  shown_live: Int
end

def fresh[A, W](spec: Types.Spec[A, W], now: Int) -> State[W]
  tick = 0
  if spec.health_ms > 0
    tick = now + spec.health_ms
  end

  State(
    starting: {},
    slots: {},
    idle: [],
    waiters: {},
    head: 0,
    tail: 0,
    keepers: {},
    watched: Set.new([]),
    checking: 0,
    next_id: 1,
    next_seq: 1,
    failure: ok(),
    retry_at_ms: 0,
    check_at_ms: 0,
    tick_ms: tick,
    booting: not spec.lazy,
    closing: false,
    deadline_ms: 0,
    dones: [],
    grace_ms: 0,
    done: false,
    shown_waiting: -1,
    shown_live: -1,
  )
end

# The next message: at once when there is one, so that a busy owner does not work out how long it may wait.
def next_msg[A, W](core: Core[A, W], state: State[W]) -> Result[Types.Msg[W]]
  got = core.inbox.recv(0)
  return got if got.ok?

  core.inbox.recv(wait_ms(state))
end

def handle[A, W](core: Core[A, W], state: State[W], msg: Types.Msg[W]) -> State[W]
  case msg
    Types.Msg.Checkout(ticket) -> checkout(core, watch(core, state, ticket.client), ticket)
    Types.Msg.Returning(held) -> returning(state, held)
    Types.Msg.Checkin(back) -> checkin(core, state, back)
    Types.Msg.Run(running) -> run(state, running)
    Types.Msg.Ready(made) -> ready(core, state, made)
    Types.Msg.Check(checked) -> checked(core, state, checked)
    Types.Msg.Down(down) -> down(core, state, down)
    Types.Msg.Failure(answer) -> answer_failure(state, answer)
    Types.Msg.Close(closing) -> close(state, closing)
  end
end

# The end of a caller's task comes as a notice; each task is monitored once (a monitor cannot be removed).
def watch[A, W](core: Core[A, W], state: State[W], client: TaskRef) -> State[W]
  return state if state.watched.include?(client.id)

  Task.monitor(client, core.inbox) do |down| Types.Msg.Down(down) end
  state.with(watched: state.watched.add(client.id))
end

def checkout[A, W](core: Core[A, W], state: State[W], ticket: Types.Ticket[W]) -> State[W]
  return refuse(state, ticket, Types.Refusal.Closed) if state.closing

  current = state
  if current.idle.empty? and full?(core, current)
    current = purge(current)
    return refuse(current, ticket, Types.Refusal.Full) if full?(core, current)
  end

  serve(core, current.with(waiters: current.waiters.put(current.tail, ticket), tail: current.tail + 1))
end

# True when one more caller would wait over `max_waiting`. The callers that a worker being made, pinged or checked in
# will serve, or one the pool may still make, do not wait in this sense: with `max_waiting` 0 the pool still makes a
# worker for a caller.
def full?[A, W](core: Core[A, W], state: State[W]) -> Bool
  room = cap(core) - live(state) + state.starting.size + state.checking
  state.tail - state.head - room >= core.spec.max_waiting
end

def refuse[W](state: State[W], ticket: Types.Ticket[W], refusal: Types.Refusal) -> State[W]
  _ = ticket.reply.send(Types.Grant.Refused(refusal), 0)
  state
end

# A caller whose worker `checkout` refused goes back to the front of the line, whatever `max_waiting` says.
def to_front[W](state: State[W], ticket: Types.Ticket[W]) -> State[W]
  state.with(waiters: state.waiters.put(state.head - 1, ticket), head: state.head - 1)
end

# Drops the tickets of the callers that gave up (they closed them), keeping the order of the others.
def purge[W](state: State[W]) -> State[W]
  renumber(state, tickets(state).select { |ticket| not ticket.reply.closed? })
end

def renumber[W](state: State[W], kept: List[Types.Ticket[W]]) -> State[W]
  waiters: Map[Int, Types.Ticket[W]] = {}
  for ticket in kept
    waiters = waiters.put(waiters.size, ticket)
  end

  state.with(waiters: waiters, head: 0, tail: kept.size)
end

def tickets[W](state: State[W]) -> List[Types.Ticket[W]]
  return [] if state.head == state.tail

  (state.head..(state.tail - 1)).to_a.map { |i| state.waiters.get(i).unwrap! }
end

# Lends the idle workers to the callers at the head of the line, then makes the workers that are missing. A ticket
# whose caller gave up refuses the send, and its worker stays idle for the next one.
def serve[A, W](core: Core[A, W], state: State[W]) -> State[W]
  current = state
  while current.head < current.tail and not current.idle.empty?
    # The keys from head to tail - 1 are always there: `checkout`, `to_front` and `purge` keep them so.
    ticket = current.waiters.get(current.head).unwrap!
    current = lend(current.with(waiters: current.waiters.delete(current.head), head: current.head + 1), ticket)
  end

  top_up(core, current)
end

def lend[W](state: State[W], ticket: Types.Ticket[W]) -> State[W]
  id = state.idle.last
  # Every id in `idle` is a slot: `retire` takes it out of both.
  slot = state.slots.get(id).unwrap!
  lease = Types.Lease(id: id, seq: state.next_seq, worker: slot.worker, orders: slot.orders)
  return state if not ticket.reply.send(Types.Grant.Lent(lease), 0).ok?

  lent = slot.with(phase: Phase.Lent, seq: state.next_seq, holder: ticket.client.id, reply: some(ticket.reply))
  state.with(
    idle: state.idle.take(state.idle.size - 1),
    slots: state.slots.put(id, lent),
    next_seq: state.next_seq + 1,
  )
end

# Starts the keepers of the workers that are wanted and missing: `size` of them in an eager pool, and in any pool one
# for each caller in line that no idle, starting, pinged or checked-in worker will serve, up to `size + max_overflow`
# keepers alive, so a replacement starts once the keeper of the worker it replaces has ended it. The tickets of the
# callers that gave up are dropped first: they want nothing. A failed `init` holds the next one back until
# `retry_at_ms`.
def top_up[A, W](core: Core[A, W], state: State[W]) -> State[W]
  return state if not missing?(core, state) or state.retry_at_ms > Time.monotonic_ms()

  current = purge(state)
  while missing?(core, current)
    current = spawn_keeper(core, current)
  end

  current
end

def missing?[A, W](core: Core[A, W], state: State[W]) -> Bool
  live(state) < cap(core) and kept(state) < wanted(core, state)
end

# The most keepers alive at once.
def cap[A, W](core: Core[A, W]) -> Int = core.spec.size + core.spec.max_overflow

# The keepers alive: their worker is being made, is alive, or is being ended.
def live[W](state: State[W]) -> Int = state.keepers.size

# The workers made or being made, which the pool keeps.
def kept[W](state: State[W]) -> Int = state.slots.size + state.starting.size

def wanted[A, W](core: Core[A, W], state: State[W]) -> Int
  wanted = kept(state) + state.tail - state.head - state.idle.size - state.starting.size - state.checking
  if wanted < core.spec.size and not (core.spec.lazy or state.closing)
    wanted = core.spec.size
  end

  return cap(core) if wanted > cap(core)

  wanted
end

def spawn_keeper[A, W](core: Core[A, W], state: State[W]) -> State[W]
  # Two orders are pending at most: a lent worker's `checkin` from its caller and one from the owner, for a caller that
  # is gone or a close; the owner pings only an idle worker.
  orders: Channel[Types.Order] = Channel.new(2)
  keep_fn: Fn[Keeper.Keeper[A, W], Void] = &Keeper.keep
  task = Task.spawn(keep_fn, Keeper.Keeper(spec: core.spec, id: state.next_id, inbox: core.inbox, orders: orders))
  Task.monitor(task, core.inbox) do |down| Types.Msg.Down(down) end
  state.with(
    starting: state.starting.put(state.next_id, orders),
    keepers: state.keepers.put(task.id, Keeping(task: task, slot: state.next_id)),
    next_id: state.next_id + 1,
  )
end

def ready[A, W](core: Core[A, W], state: State[W], made: Types.Made[W]) -> State[W]
  case state.starting.get(made.id)
    # A worker whose slot was given up (a close): its keeper finds its channel closed and ends it.
    none -> state
    some(orders) ->
      rest = state.with(starting: state.starting.delete(made.id))
      case made.worker
        error(e) -> failed(core, rest, error(e))
        ok(worker) ->
          now = Time.monotonic_ms()
          slot = Slot(
            worker: worker,
            phase: Phase.Idle,
            orders: orders,
            seq: 0,
            holder: 0,
            reply: none,
            runner: none,
            born_ms: now,
            idle_since_ms: now,
          )

          added = rest.with(slots: rest.slots.put(made.id, slot), failure: ok(), retry_at_ms: 0)
          booted(core, park(core, added, made.id, now))
      end
  end
end

# An `init` that failed. During the start the start fails with its error and the pool ends; later the callers that
# time out get it as the cause, and `init` waits INIT_RETRY_MS before the next try.
def failed[A, W](core: Core[A, W], state: State[W], failure: Result[Void]) -> State[W]
  if state.booting
    _ = core.ready.send(failure, 0)
    return stop_timers(state).with(booting: false, closing: true, deadline_ms: Time.monotonic_ms())
  end

  state.with(failure: failure, retry_at_ms: Time.monotonic_ms() + INIT_RETRY_MS)
end

def booted[A, W](core: Core[A, W], state: State[W]) -> State[W]
  return state if not state.booting or state.slots.size < core.spec.size

  _ = core.ready.send(ok(), 0)
  state.with(booting: false)
end

def checkin[A, W](core: Core[A, W], state: State[W], back: Types.Back[W]) -> State[W]
  case state.slots.get(back.id)
    some(slot) if slot.seq == back.seq and lent?(slot) -> given(core, state, back.id, back.how)
    # The worker was ended meanwhile (its caller's task ended, or the drain of a close is over); a caller whose worker
    # `checkout` refused still waits.
    _ ->
      case back.how
        Types.Return.Again(ticket) -> serve(core, to_front(state, ticket))
        _ -> state
      end
  end
end

def given[A, W](core: Core[A, W], state: State[W], id: Int, how: Types.Return[W]) -> State[W]
  case how
    Types.Return.Keep -> park(core, state, id, Time.monotonic_ms())
    Types.Return.Drop -> serve(core, retire(state, id))
    Types.Return.Again(ticket) -> serve(core, to_front(retire(state, id), ticket))
  end
end

def lent?[W](slot: Slot[W]) -> Bool = slot.phase == Phase.Lent or slot.phase == Phase.Returning

def returning[W](state: State[W], held: Types.Held) -> State[W]
  case state.slots.get(held.id)
    some(slot) if slot.phase == Phase.Lent and slot.seq == held.seq ->
      state.with(slots: state.slots.put(held.id, slot.with(phase: Phase.Returning)))
    _ -> state
  end
end

def run[W](state: State[W], running: Types.Running) -> State[W]
  case state.slots.get(running.id)
    some(slot) if slot.phase == Phase.Lent and slot.seq == running.seq ->
      state.with(slots: state.slots.put(running.id, slot.with(runner: some(running.runner))))
    _ -> state
  end
end

# A worker that is free again: it goes to the idle ones and serves the line, unless it is too old (`max_age_ms`) or
# nobody can need it (a close with nobody in line, or an overflow worker with `overflow_idle_ms` 0).
def park[A, W](core: Core[A, W], state: State[W], id: Int, idle_since_ms: Int) -> State[W]
  slot = state.slots.get(id).unwrap!
  nobody_waits = state.head == state.tail
  if nobody_waits and (state.closing or (surplus?(core, state) and core.spec.overflow_idle_ms == 0))
    return serve(core, retire(state, id))
  end

  return serve(core, retire(state, id)) if core.spec.max_age_ms > 0 and aged?(core.spec, slot, Time.monotonic_ms())

  slot = slot.with(phase: Phase.Idle, holder: 0, reply: none, runner: none, idle_since_ms: idle_since_ms)
  parked = state.with(slots: state.slots.put(id, slot), idle: state.idle.push(id))
  serve(core, parked.with(check_at_ms: earliest(parked.check_at_ms, due_ms(core.spec, slot))))
end

# Ends a worker: its keeper sees its channel closed, runs `terminate` and ends.
def retire[W](state: State[W], id: Int) -> State[W]
  case state.slots.get(id)
    some(slot) ->
      slot.orders.close
      checking = state.checking
      if in_keeper?(slot)
        checking -= 1
      end

      state.with(slots: state.slots.delete(id), idle: state.idle.select { |other| other != id }, checking: checking)
    none -> state
  end
end

def in_keeper?[W](slot: Slot[W]) -> Bool = slot.phase == Phase.Pinging or slot.phase == Phase.Checking

def surplus?[A, W](core: Core[A, W], state: State[W]) -> Bool = kept(state) > core.spec.size

def aged?[A, W](spec: Types.Spec[A, W], slot: Slot[W], now: Int) -> Bool
  spec.max_age_ms > 0 and now - slot.born_ms >= spec.max_age_ms
end

# When an idle worker may be an overflow worker idle for `overflow_idle_ms` (0: never, in a pool without overflow).
def due_ms[A, W](spec: Types.Spec[A, W], slot: Slot[W]) -> Int
  return 0 if spec.max_overflow == 0

  slot.idle_since_ms + spec.overflow_idle_ms
end

# The earlier of two times, where 0 means none.
def earliest(a: Int, b: Int) -> Int
  return b if a == 0

  return a if b == 0

  return a if a < b

  b
end

# A ping or a `checkin` done in the keeper: for a lent worker (its caller asked the keeper itself) or one the owner
# sent there, of the same lease.
def checked[A, W](core: Core[A, W], state: State[W], checked: Types.Checked) -> State[W]
  case state.slots.get(checked.id)
    some(slot) if slot.seq == checked.seq and (in_keeper?(slot) or slot.phase == Phase.Lent) ->
      # Back from the keeper first, so that `retire` does not count it out a second time.
      checking = state.checking
      if in_keeper?(slot)
        checking -= 1
      end

      back = state.with(slots: state.slots.put(checked.id, slot.with(phase: Phase.Idle)), checking: checking)
      return serve(core, retire(back, checked.id)) if not checked.keep

      # A ping does not count as use: the worker stays idle since it was given back, for `idle_ms`.
      idle_since = Time.monotonic_ms()
      if slot.phase == Phase.Pinging
        idle_since = slot.idle_since_ms
      end

      park(core, back, checked.id, idle_since)
    _ -> state
  end
end

def down[A, W](core: Core[A, W], state: State[W], down: TaskDown) -> State[W]
  case state.keepers.get(down.task_id)
    some(keeping) -> keeper_down(core, state.with(keepers: state.keepers.delete(down.task_id)), keeping, down)
    none -> client_down(core, state, down)
  end
end

# A keeper ended. After `retire` that is the normal end; else it crashed: in `init` (a failed `init`), or in `ping`
# or `terminate`, and its worker is gone with it.
def keeper_down[A, W](core: Core[A, W], state: State[W], keeping: Keeping, down: TaskDown) -> State[W]
  if state.starting.key?(keeping.slot)
    crashed: Result[Void] = error("pool error: init crashed: #{down.message}", kind: "task.crashed")
    return serve(core, failed(core, state.with(starting: state.starting.delete(keeping.slot)), crashed))
  end

  # A keeper that ended after `retire` frees room for a replacement.
  serve(core, retire(state, keeping.slot))
end

# A caller's task ended while it held workers, and its tickets leave the line. `checkin` runs at most once for each
# lease, and only after a body that may have run: a worker whose grant the caller never read is idle again; one whose
# `checkin` the caller had started (`lease_ms` 0), or whose body had not started in its task (`lease_ms` above 0), is
# ended without it; for the others the keeper runs `checkin` with how the caller ended (a crash is `Crashed`, a cancel
# `TimedOut`, which always ends the worker). A runner cancelled with its caller may still be about to start, so a
# worker whose body did not start is ended, never lent again.
def client_down[A, W](core: Core[A, W], state: State[W], down: TaskDown) -> State[W]
  outcome = Types.Outcome.TimedOut
  if down.reason == TaskExit.Crashed
    outcome = Types.Outcome.Crashed
  end

  held = state.slots.keys.select { |id| holds?(state, id, down.task_id) }
  cleared = held.reduce(state.with(watched: state.watched.delete(down.task_id))) do |acc, id|
    let_go(core, acc, id, outcome)
  end

  serve(core, drop_tickets(cleared, down.task_id))
end

def let_go[A, W](core: Core[A, W], state: State[W], id: Int, outcome: Types.Outcome) -> State[W]
  slot = state.slots.get(id).unwrap!
  return retire(state, id) if slot.phase == Phase.Returning

  return park(core, state, id, slot.idle_since_ms) if unread?(slot)

  return retire(state, id) if core.spec.lease_ms > 0 and slot.runner.none?

  lost(state, id, outcome)
end

def unread?[W](slot: Slot[W]) -> Bool
  case slot.reply
    some(reply) -> not reply.empty?
    none -> false
  end
end

# The keeper runs `checkin`, and reports back like a ping.
def lost[W](state: State[W], id: Int, outcome: Types.Outcome) -> State[W]
  slot = state.slots.get(id).unwrap!
  _ = slot.orders.send(Types.Order.Checkin(Types.Turn(seq: slot.seq, outcome: outcome)), 0)
  checking = slot.with(phase: Phase.Checking, holder: 0, reply: none, runner: none)
  state.with(slots: state.slots.put(id, checking), checking: state.checking + 1)
end

def holds?[W](state: State[W], id: Int, task_id: Int) -> Bool
  case state.slots.get(id)
    some(slot) -> lent?(slot) and slot.holder == task_id
    none -> false
  end
end

def drop_tickets[W](state: State[W], task_id: Int) -> State[W]
  return state if (not tickets(state).any? { |ticket| ticket.client.id == task_id })

  renumber(state, tickets(state).select { |ticket| ticket.client.id != task_id })
end

def answer_failure[W](state: State[W], answer: Channel[Result[Void]]) -> State[W]
  _ = answer.send(state.failure, 0)
  state
end

def close[W](state: State[W], closing: Types.Closing) -> State[W]
  dones = state.dones.push(closing.done)
  return state.with(dones: dones) if state.closing

  stop_timers(state).with(closing: true, deadline_ms: Time.monotonic_ms() + closing.drain_ms, dones: dones)
end

# A pool that closes no longer pings, trims or makes workers after a failure.
def stop_timers[W](state: State[W]) -> State[W] = state.with(check_at_ms: 0, tick_ms: 0, retry_at_ms: 0)

# Runs after every message and every wait: the close, the health tick, the overflow workers that are due, and a
# retry of `init`.
def tick[A, W](core: Core[A, W], state: State[W], now: Int) -> State[W]
  return closing_tick(core, state, now) if state.closing

  current = state
  if current.tick_ms > 0 and now >= current.tick_ms
    current = health(core, current.with(tick_ms: now + core.spec.health_ms), now)
  end

  if current.check_at_ms > 0 and now >= current.check_at_ms
    current = trim(core, current, now)
  end

  return serve(core, current.with(retry_at_ms: 0)) if current.retry_at_ms > 0 and now >= current.retry_at_ms

  current
end

# The health tick: each idle worker that is too old (`max_age_ms`) or idle too long (`idle_ms`) is ended, and each
# other one idle for `health_ms` or more is pinged in its keeper, which reports back; it is not lent meanwhile. A
# worker given back since the last tick is in use and needs no ping, so a busy pool never waits for one.
def health[A, W](core: Core[A, W], state: State[W], now: Int) -> State[W]
  current = state
  for id in state.idle
    slot = current.slots.get(id).unwrap!
    if stale?(core.spec, slot, now)
      current = retire(current, id)
    elsif now - slot.idle_since_ms >= core.spec.health_ms
      current = ping(current, id, slot)
    end
  end

  serve(core, current)
end

def stale?[A, W](spec: Types.Spec[A, W], slot: Slot[W], now: Int) -> Bool
  aged?(spec, slot, now) or (spec.idle_ms > 0 and now - slot.idle_since_ms >= spec.idle_ms)
end

def ping[W](state: State[W], id: Int, slot: Slot[W]) -> State[W]
  _ = slot.orders.send(Types.Order.Ping(slot.seq), 0)
  pinging = slot.with(phase: Phase.Pinging)
  state.with(
    slots: state.slots.put(id, pinging),
    idle: state.idle.select { |other| other != id },
    checking: state.checking + 1,
  )
end

# Ends the overflow workers idle for `overflow_idle_ms`, the longest idle first, while the pool is over `size`; the
# overflow worker that serves a steady load is lent again before that and stays. This is the idle path of the
# workers, with the overflow time instead of the health tick.
def trim[A, W](core: Core[A, W], state: State[W], now: Int) -> State[W]
  current = state.with(check_at_ms: 0)
  for id in state.idle
    slot = current.slots.get(id).unwrap!
    if surplus?(core, current) and now - slot.idle_since_ms >= core.spec.overflow_idle_ms
      current = retire(current, id)
    elsif surplus?(core, current)
      current = current.with(check_at_ms: earliest(current.check_at_ms, due_ms(core.spec, slot)))
    end
  end

  serve(core, current)
end

# A close: the callers in line are still served until the end of the drain, and the workers nobody can need are ended
# at once. When the drain is over the callers left are refused, the bodies that still run in a task of their own are
# cancelled (their callers get `closed`), and every worker is ended, also the lent ones (a body that runs in its caller
# finds its worker ended). The pool ends when every keeper has ended, or CLOSE_GRACE_MS later.
def closing_tick[A, W](core: Core[A, W], state: State[W], now: Int) -> State[W]
  current = purge(state)
  if now >= current.deadline_ms
    tickets(current).each do |ticket| _ = ticket.reply.send(Types.Grant.Refused(Types.Refusal.Closed), 0) end
    current.slots.values.each do |slot| cancel_runner(slot) end
    current = current.with(waiters: {}, head: 0, tail: 0)
  end

  if current.head == current.tail
    current = end_free(current, now >= current.deadline_ms)
  end

  return current if not current.slots.empty? or not current.starting.empty?

  return finish(current) if current.keepers.empty?

  return current.with(grace_ms: now + CLOSE_GRACE_MS) if current.grace_ms == 0

  return current if now < current.grace_ms

  current.keepers.values.each do |keeping| Task.cancel(keeping.task) end
  finish(current.with(keepers: {}))
end

# Ends the workers that are idle, pinged or starting, and the lent ones too when `all`. A body that the close cut off
# in its task has `checkin` run by the keeper, as after a lease that timed out, then its worker is ended.
def end_free[W](state: State[W], all: Bool) -> State[W]
  state.starting.values.each do |orders| orders.close end
  state.slots.keys.reduce(state.with(starting: {})) do |acc, id| retire_free(acc, id, all) end
end

def cancel_runner[W](slot: Slot[W]) -> Void
  case slot.runner
    some(runner) -> Task.cancel(runner)
    none -> return
  end
end

def retire_free[W](state: State[W], id: Int, all: Bool) -> State[W]
  case state.slots.get(id)
    some(slot) if lent?(slot) and not all -> state
    some(slot) if slot.phase == Phase.Lent and slot.runner.some? -> lost(state, id, Types.Outcome.TimedOut)
    some(_) -> retire(state, id)
    none -> state
  end
end

def finish[W](state: State[W]) -> State[W]
  state.dones.each do |done| _ = done.send(true, 0) end
  state.with(done: true)
end

# Writes the counts that changed, for the readers of `Pool.counts`. The line holds the tickets of callers that gave up
# until they are dropped, so `waiting` may count them for a while.
def publish[A, W](core: Core[A, W], state: State[W]) -> State[W]
  waiting = state.tail - state.head
  alive = live(state)
  return state if waiting == state.shown_waiting and alive == state.shown_live

  core.counts.put(WAITING, waiting)
  core.counts.put(LIVE, alive)
  state.with(shown_waiting: waiting, shown_live: alive)
end

# Until the next deadline: an idle worker due, a retry of `init`, the end of the drain or of the grace.
def wait_ms[W](state: State[W]) -> Int
  now = Time.monotonic_ms()
  until = earliest(earliest(state.check_at_ms, state.retry_at_ms), state.tick_ms)
  if state.closing and now < state.deadline_ms
    until = earliest(until, state.deadline_ms)
  end

  if state.closing
    until = earliest(until, state.grace_ms)
  end

  return MAX_WAIT_MS if until == 0

  (until - now).clamp(1, MAX_WAIT_MS)
end
