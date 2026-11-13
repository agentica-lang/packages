## The hub: one task that owns the map of topics to subscribers, so that no lock is needed whatever the number of
## schedulers. Everything else talks to it over its inbox, in FIFO order, through the functions of this module (the
## messages are private). A connection is a `Channel[Event]`.

import Actor from "std/actor"
import HTTP from "std/http"
import Protocol from "protocol"
import {HubOptions, Stats} from "types"

CONNECTIONS = "connections"
SUBSCRIPTIONS = "subscriptions"

## What a connection task receives: a frame to write, a message of the client (from the pump), a WebSocket ping to
## write, and `Away` (`reconnect`): the connection ends on purpose, with the `disconnect` frame that says whether the
## client may come back.
enum Event
  Frame(String)
  Client(HTTP.Message)
  Ping
  Away(Bool)
end

## The hub is a value: its inbox, its task (that `main` awaits), its ticker and the counters that `stats` reads.
struct Hub
  inbox: Channel[HubMessage]
  task: Task[Result[Void]]
  ticker: Task[Result[Void]]
  counters: ATS[String, Int]
  options: HubOptions
end

## Starts the hub task and its ticker; an `error` for options that cannot work (`beat_ms` under 1 would divide the
## ping interval by zero, a negative `broadcast_wait_ms` is no wait). The inbox belongs to the hub task, so when the
## hub ends or crashes every send fails at once with "closed" instead of waiting for room.
def start(options: HubOptions) -> Result[Hub]
  return error("beat_ms must be 1 or more, it is #{options.beat_ms}") if options.beat_ms < 1

  if options.broadcast_wait_ms < 0
    return error("broadcast_wait_ms must be 0 or more, it is #{options.broadcast_wait_ms}")
  end

  counters: ATS[String, Int] = ATS.new()
  handler = handling do |state, message| handle(state, message, counters) end
  actor = Actor.start(Actor.Behaviour(init: &empty_state, handle: handler), Actor.Options(capacity: HUB_INBOX))
  # The hub and its ticker send through the channel itself, not `Actor.cast`, so a send keeps its "closed" and
  # "timed out" errors.
  ticker = Task.spawn(&ticking, Ticker(inbox: actor.inbox, counters: counters, beat_ms: options.beat_ms))
  ok(Hub(inbox: actor.inbox, task: actor.task, ticker: ticker, counters: counters, options: options))
end

## Asks the hub to end; its task returns and later sends fail. The ticker is cancelled with it, and `stop` waits for it
## to end, so that no task is left sleeping for a beat (a program or a test that waits for its tasks does not wait for
## one more). A `Stop` that could not be queued (the inbox stayed full) leaves the hub running, with its ticker.
def stop(hub: Hub) -> Result[Void]
  sent = send(hub, HubMessage.Stop)
  if sent.ok? or gone?(hub)
    # A cancel only marks the task; the await returns once its sleep or send has ended, with "task: cancelled", which
    # is the expected end.
    Task.cancel(hub.ticker)
    _ = Task.await(hub.ticker)
  end

  sent
end

## True once the hub has ended or crashed: its inbox is closed, so nothing sent to it is ever heard.
def gone?(hub: Hub) -> Bool = hub.inbox.closed?

## Queues a broadcast of an encoded payload; a failure is counted as lost.
def broadcast(hub: Hub, topic: String, payload: String) -> Result[Void]
  sent = send(hub, HubMessage.Broadcast(Cast(topic: topic, payload: payload)))
  if not sent.ok?
    _ = hub.counters.add(LOST, 1)
  end

  sent
end

## A connection of the person `identity` (`Identity.id`) joins: it gets the pings on `inbox`, the broadcasts on
## `outgoing` (its WebSocket queue), and a WebSocket ping every `every` beats.
def register(
  hub: Hub,
  connection: Int,
  identity: String,
  inbox: Channel[Event],
  outgoing: Channel[HTTP.Message],
  every: Int,
) -> Result[Void]
  registration = Registration(
    connection: connection,
    identity: identity,
    inbox: inbox,
    outgoing: outgoing,
    every: every,
  )

  send(hub, HubMessage.Register(registration))
end

## The broadcasts of `topics` reach the subscription `identifier` of the connection. Waits until the hub has written
## `confirm` to the WebSocket; an `error` means the hub does not route to it.
def attach(hub: Hub, connection: Int, identifier: String, topics: List[String], confirm: String) -> Result[Void]
  done: Channel[Bool] = Channel.new(1)
  attach = Attach(
    connection: connection,
    identifier: identifier,
    topics: topics,
    confirm: HTTP.prepare(HTTP.Message.Text(confirm)),
    done: done,
  )

  try send(hub, HubMessage.Subscribe(attach))
  answered(hub, done)
end

## The subscription `identifier` of the connection hears no more broadcasts. A failure is a hub that keeps routing to
## it until the connection ends (which `disconnect` settles).
def detach(hub: Hub, connection: Int, identifier: String) -> Result[Void]
  send(hub, HubMessage.Unsubscribe(Detach(connection: connection, identifier: identifier)))
end

## The connection ends: the hub forgets all its subscriptions at once.
def disconnect(hub: Hub, connection: Int) -> Result[Void] = send(hub, HubMessage.Disconnect(connection))

## Ends every connection whose identity is `identity`: each is sent `Event.Away(reconnect)`, and the hub stops routing
## to it at once, so a broadcast queued after this call is not delivered to it. A connection whose inbox is full has it
## closed instead, and finds the reason with `away_reason`. A connection that registers after this message was handled
## is not ended (the hub processes its inbox in order: a `Register` queued before it is). A failure is a hub that did
## not take the message (full for `broadcast_wait_ms`, or gone).
def remove(hub: Hub, identity: String, reconnect: Bool) -> Result[Void]
  send(hub, HubMessage.Remove(Removal(identity: identity, reconnect: reconnect)))
end

## What `remove` asked of the connection: `some(reconnect)` once it did, `none` before. A connection whose inbox is
## closed reads it, to tell a connection that was ended on purpose from one that was dropped.
def away_reason(hub: Hub, connection: Int) -> Optional[Bool]
  asked = hub.counters.get(away_key(connection))
  return none if not asked.ok?

  some(asked.unwrap! == 1)
end

## Adds `delta` to a counter of `stats` (the connections do their own counting).
def count(hub: Hub, name: String, delta: Int) -> Void
  _ = hub.counters.add(name, delta)
end

## A number for a new connection.
def next_connection(hub: Hub) -> Int = hub.counters.add(NEXT_CONNECTION, 1)

def stats(hub: Hub) -> Stats
  Stats(
    connections: counted(hub, CONNECTIONS),
    subscriptions: counted(hub, SUBSCRIPTIONS),
    drops: counted(hub, DROPS),
    lost: counted(hub, LOST),
  )
end

private

DROPS = "drops"
LOST = "lost"
NEXT_CONNECTION = "next_connection"
# 1 while a `Beat` is queued and the hub has not taken it: the ticker sends one only when none is pending.
BEAT_PENDING = "beat_pending"
# `away:CONNECTION` holds 1 or 0 while `Channels.disconnect` ended that connection: the `reconnect` it asked for, for a
# connection whose inbox was too full to take the `Away` event.
AWAY_PREFIX = "away:"
HUB_INBOX = 4_096
ATTACH_WAIT_MS = 5_000
ATTACH_SLICE_MS = 100

# A connection that joins the hub; it gets a WebSocket ping every `every` beats.
struct Registration
  connection: Int
  identity: String
  inbox: Channel[Event]
  outgoing: Channel[HTTP.Message]
  every: Int
end

# Every connection of the person `identity` ends.
struct Removal
  identity: String
  reconnect: Bool
end

# The topics whose broadcasts a subscription of a connection receives.
struct Attach
  connection: Int
  identifier: String
  topics: List[String]
  confirm: HTTP.Message
  done: Channel[Bool]
end

struct Detach
  connection: Int
  identifier: String
end

# `payload` is the JSON text of the payload, made once by the sender.
struct Cast
  topic: String
  payload: String
end

enum HubMessage
  Register(Registration)
  Subscribe(Attach)
  Unsubscribe(Detach)
  Disconnect(Int)
  Remove(Removal)
  Broadcast(Cast)
  Beat
  Stop
end

# The subscribers of one identifier on a topic. The frame of a broadcast differs from one route to the next only in
# the identifier, so it is made once per route and shared by every member. `fan` caches `members.values`; `settled`
# rebuilds it on the next broadcast after a change (`ready` false).
struct Route
  identifier: String
  members: Map[Int, Member]
  fan: List[Member]
  ready: Bool
end

struct Member
  connection: Int
  inbox: Channel[Event]
  outgoing: Channel[HTTP.Message]
end

struct Topic
  routes: Map[String, Route]
  fan: List[Route]
  ready: Bool
end

struct Key
  topic: String
  identifier: String
end

struct Entry
  identity: String
  inbox: Channel[Event]
  outgoing: Channel[HTTP.Message]
  every: Int
  keys: List[Key]
end

# topics: topic -> identifier -> Route (its members: connection -> Member). A broadcast encodes its frame once per
# identifier.
struct State
  entries: Map[Int, Entry]
  topics: Map[String, Topic]
  beats: Int
end

struct Ticker
  inbox: Channel[HubMessage]
  counters: ATS[String, Int]
  beat_ms: Int
end

# Every send of a caller waits as long as a broadcast does: a hub inbox that is full is the normal back-pressure, and
# a message that is lost (an unsubscribe, a disconnect) leaves the hub routing to a connection that is gone.
def send(hub: Hub, message: HubMessage) -> Result[Void] = hub.inbox.send(message, hub.options.broadcast_wait_ms)

def answered(hub: Hub, done: Channel[Bool]) -> Result[Void]
  waited = 0
  while waited < ATTACH_WAIT_MS and not gone?(hub)
    got = done.recv(ATTACH_SLICE_MS)
    return attached_or_not(got.unwrap!) if got.ok?

    waited = waited + ATTACH_SLICE_MS
  end

  # A closed `done` makes the hub skip the attach; an answer sent before the close still counts.
  done.close
  case done.recv(0)
    ok(attached) -> attached_or_not(attached)
    error(_) -> error("the hub did not attach the subscription")
  end
end

def attached_or_not(attached: Bool) -> Result[Void]
  return ok() if attached

  error("the hub did not attach the subscription")
end

def away_key(connection: Int) -> String = "#{AWAY_PREFIX}#{connection}"

def counted(hub: Hub, name: String) -> Int = hub.counters.get(name).unwrap_or(0)

# A beat in the inbox keeps its place among the broadcasts, and a receive timeout would never fire while the inbox
# stays busy: the Rails client calls a connection stale after 6 s without a ping. Only a closed inbox (the hub is
# gone) ends the ticker: a send that times out on a full inbox is a busy hub, and the next beat must still come. A
# beat that is already queued is not sent again, so a hub that was busy does not find a burst of them when it
# catches up.
def ticking(ticker: Ticker) -> Result[Void]
  while true
    Task.sleep(ticker.beat_ms)
    return ok() if ticker.inbox.closed?

    if ticker.counters.get(BEAT_PENDING).unwrap_or(0) == 0
      ticker.counters.put(BEAT_PENDING, 1)
      sent = ticker.inbox.send(HubMessage.Beat, ticker.beat_ms)
      if not sent.ok?
        ticker.counters.put(BEAT_PENDING, 0)
      end
    end
  end

  ok()
end

def empty_state() -> State
  empty_entries: Map[Int, Entry] = {}
  empty_topics: Map[String, Topic] = {}
  State(entries: empty_entries, topics: empty_topics, beats: 0)
end

# A block can only follow a call, so this turns the block that holds the counters into the `Fn` of the behaviour.
def handling(f: Fn[State, HubMessage, Actor.Step[State]]) -> Fn[State, HubMessage, Actor.Step[State]] = f

# `Stop` ends the actor at once: the messages still queued behind it are dropped, as before.
def handle(state: State, message: HubMessage, counters: ATS[String, Int]) -> Actor.Step[State]
  case message
    HubMessage.Stop -> Actor.done(state)
    _ -> Actor.continue(step(state, message, counters))
  end
end

def step(state: State, message: HubMessage, counters: ATS[String, Int]) -> State
  case message
    HubMessage.Register(registration) -> admit(state, registration)
    HubMessage.Subscribe(attach) -> subscribe(state, attach, counters)
    HubMessage.Unsubscribe(detach) -> unsubscribe(state, detach.connection, detach.identifier)
    HubMessage.Disconnect(connection) ->
      counters.delete(away_key(connection))
      remove_connection(state, connection)
    HubMessage.Remove(removal) -> remove_identity(state, removal, counters)
    HubMessage.Broadcast(cast) -> fan_out(state, cast, counters)
    HubMessage.Beat -> beat(state, counters)
    HubMessage.Stop -> state
  end
end

def admit(state: State, registration: Registration) -> State
  keys: List[Key] = []
  entry = Entry(
    identity: registration.identity,
    inbox: registration.inbox,
    outgoing: registration.outgoing,
    every: registration.every,
    keys: keys,
  )

  state.with(entries: state.entries.put(registration.connection, entry))
end

# The hub writes the confirmation itself, so no broadcast can reach the socket before it.
def subscribe(state: State, attach: Attach, counters: ATS[String, Int]) -> State
  case state.entries.get(attach.connection)
    none ->
      _ = attach.done.send(false, 0)
      state
    some(entry) ->
      return state if attach.done.closed?

      member = Member(connection: attach.connection, inbox: entry.inbox, outgoing: entry.outgoing)
      topics = state.topics
      keys = entry.keys
      for topic in attach.topics
        topics = with_member(topics, topic, attach.identifier, member)
        keys = keys.push(Key(topic: topic, identifier: attach.identifier))
      end

      entries = state.entries.put(attach.connection, entry.with(keys: keys))
      joined = state.with(entries: entries, topics: topics)
      if not entry.outgoing.send(attach.confirm, 0).ok?
        _ = attach.done.send(false, 0)
        lose(counters, member)
        return remove_connection(joined, attach.connection)
      end

      return joined if attach.done.send(true, 0).ok?

      # The caller gave up while the hub was busy and rejects the subscription.
      unsubscribe(joined, attach.connection, attach.identifier)
  end
end

def unsubscribe(state: State, connection: Int, identifier: String) -> State
  case state.entries.get(connection)
    none -> state
    some(entry) ->
      topics = state.topics
      leaving = entry.keys.select do |key| key.identifier == identifier end
      for key in leaving
        topics = without_member(topics, key.topic, identifier, connection)
      end

      kept = entry.keys.select do |key| key.identifier != identifier end
      entries = state.entries.put(connection, entry.with(keys: kept))
      state.with(entries: entries, topics: topics)
  end
end

def remove_connection(state: State, connection: Int) -> State
  case state.entries.get(connection)
    none -> state
    some(entry) ->
      topics = state.topics
      for key in entry.keys
        topics = without_member(topics, key.topic, key.identifier, connection)
      end

      state.with(entries: state.entries.delete(connection), topics: topics)
  end
end

# The connection is told and forgotten here, not when its loop ends: the loop writes `Away` and stops, and a frame
# queued before it still goes out, but none queued after. The reason is also left in a slot of the counters, before
# the event is sent: a connection whose inbox is full cannot take `Away`, so the hub closes the inbox (no drop is
# counted: nothing was too slow) and the loop, which finds it closed, reads the slot and says what was asked. The slot
# goes with the `Disconnect` that the connection sends when it ends.
def remove_identity(state: State, removal: Removal, counters: ATS[String, Int]) -> State
  gone: List[Int] = []
  asked = 0
  if removal.reconnect
    asked = 1
  end

  for connection in state.entries.keys
    entry = state.entries[connection]
    if entry.identity == removal.identity
      counters.put(away_key(connection), asked)
      sent = entry.inbox.send(Event.Away(removal.reconnect), 0)
      if not sent.ok? and not entry.inbox.closed?
        entry.inbox.close
      end

      gone = gone.push(connection)
    end
  end

  forget(state, gone)
end

def with_member(topics: Map[String, Topic], topic: String, identifier: String, member: Member) -> Map[String, Topic]
  current = topics.get(topic, no_topic())
  route = current.routes.get(identifier, no_route(identifier))
  joined = route.with(members: route.members.put(member.connection, member), ready: false)
  topics.put(topic, current.with(routes: current.routes.put(identifier, joined), ready: false))
end

def no_topic() -> Topic
  routes: Map[String, Route] = {}
  fan: List[Route] = []
  Topic(routes: routes, fan: fan, ready: false)
end

def no_route(identifier: String) -> Route
  members: Map[Int, Member] = {}
  fan: List[Member] = []
  Route(identifier: identifier, members: members, fan: fan, ready: false)
end

# A topic or an identifier with no member left leaves the map, so a long run does not keep every name it ever saw.
def without_member(
  topics: Map[String, Topic],
  topic: String,
  identifier: String,
  connection: Int,
) -> Map[String, Topic]
  current = topics.get(topic, no_topic())
  routes = current.routes
  route = routes.get(identifier, no_route(identifier))
  members = route.members.delete(connection)
  if members.empty?
    routes = routes.delete(identifier)
  else
    routes = routes.put(identifier, route.with(members: members, ready: false))
  end

  return topics.delete(topic) if routes.empty?

  topics.put(topic, current.with(routes: routes, ready: false))
end

# Sends without waiting. True when the connection must leave the hub: its inbox is closed already, or it is full
# (a client too slow for the traffic) and is closed now, so that its task drains what is queued and says goodbye.
def leaves?(counters: ATS[String, Int], inbox: Channel[Event], event: Event) -> Bool
  return false if inbox.send(event, 0).ok?

  cut_off(counters, inbox)
  true
end

# A full WebSocket queue cuts the client off; a closed one is a connection already over (no drop).
def lose(counters: ATS[String, Int], member: Member) -> Void
  if not member.outgoing.closed?
    cut_off(counters, member.inbox)
  end
end

# A failed send is a closed inbox (nothing to do) or a full one (a drop).
def cut_off(counters: ATS[String, Int], inbox: Channel[Event]) -> Void
  if not inbox.closed?
    inbox.close
    _ = counters.add(DROPS, 1)
  end
end

def fan_out(state: State, cast: Cast, counters: ATS[String, Int]) -> State
  case state.topics.get(cast.topic)
    none -> state
    some(found) ->
      topic = settled(found)
      known = state
      if not found.ready
        known = state.with(topics: state.topics.put(cast.topic, topic))
      end

      forget(known, deliver(topic, cast, counters))
  end
end

def deliver(topic: Topic, cast: Cast, counters: ATS[String, Int]) -> List[Int]
  gone: List[Int] = []
  for route in topic.fan
    framed = HTTP.prepare(HTTP.Message.Text(Protocol.message(route.identifier, cast.payload)))
    for member in route.fan
      if not member.outgoing.send(framed, 0).ok?
        lose(counters, member)
        gone = gone.push(member.connection)
      end
    end
  end

  gone
end

def settled(topic: Topic) -> Topic
  return topic if topic.ready

  routes = topic.routes
  for route in topic.routes.values
    if not route.ready
      routes = routes.put(route.identifier, route.with(fan: route.members.values, ready: true))
    end
  end

  topic.with(routes: routes, fan: routes.values, ready: true)
end

# The Action Cable ping goes to every connection, and the WebSocket ping to those whose turn it is.
def beat(state: State, counters: ATS[String, Int]) -> State
  counters.put(BEAT_PENDING, 0)
  beats = state.beats + 1
  ping = Event.Frame(Protocol.ping(Time.now_ms() / 1000))
  gone: List[Int] = []
  for connection in state.entries.keys
    entry = state.entries[connection]
    if leaves?(counters, entry.inbox, ping)
      gone = gone.push(connection)
    elsif beats % entry.every == 0 and leaves?(counters, entry.inbox, Event.Ping)
      gone = gone.push(connection)
    end
  end

  forget(state.with(beats: beats), gone)
end

def forget(state: State, gone: List[Int]) -> State
  result = state
  for connection in gone
    result = remove_connection(result, connection)
  end

  result
end
