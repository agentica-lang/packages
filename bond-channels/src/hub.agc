## The hub: one task that owns the map of topics to subscribers, so that no lock is needed whatever the number of
## schedulers. Everything else talks to it over its inbox, in FIFO order. A connection is a `Channel[Event]`.

import HTTP from "std/http"
import Protocol from "protocol"
import {Options, Stats} from "types"

export CONNECTIONS = "connections"
export SUBSCRIPTIONS = "subscriptions"
DROPS = "drops"
LOST = "lost"
NEXT_CONNECTION = "next_connection"
HUB_INBOX = 4_096
# The hub task wakes up at least this often only to look again at its inbox.
IDLE_MS = 60_000

## What a connection task receives: a frame to write, a message of the client (from the pump), a WebSocket ping to write.
export enum Event
  Frame(String)
  Client(HTTP.Message)
  Ping
end

## A connection that joins the hub; it gets a WebSocket ping every `every` beats.
export struct Registration
  connection: Int
  inbox: Channel[Event]
  every: Int
end

## The topics whose broadcasts a subscription of a connection receives.
export struct Attach
  connection: Int
  identifier: String
  topics: List[String]
end

export struct Detach
  connection: Int
  identifier: String
end

## `payload` is the JSON text of the payload, made once by the sender.
export struct Cast
  topic: String
  payload: String
end

export enum HubMessage
  Register(Registration)
  Subscribe(Attach)
  Unsubscribe(Detach)
  Disconnect(Int)
  Broadcast(Cast)
  Beat
  Stop
end

## The hub is a value: its inbox, its task (that `main` awaits) and the counters that `stats` reads.
export struct Hub
  inbox: Channel[HubMessage]
  task: Task[Result[Void]]
  counters: ATS[String, Int]
  options: Options
end

type Group = Map[Int, Channel[Event]]

type Topic = Map[String, Group]

struct Key
  topic: String
  identifier: String
end

struct Entry
  inbox: Channel[Event]
  every: Int
  keys: List[Key]
end

# topics: topic -> identifier -> connection -> inbox. A broadcast encodes its frame once per identifier.
struct State
  entries: Map[Int, Entry]
  topics: Map[String, Topic]
  beats: Int
end

struct Ticker
  inbox: Channel[HubMessage]
  beat_ms: Int
end

struct Launch
  inbox: Channel[HubMessage]
  counters: ATS[String, Int]
end

## Starts the hub task and its ticker. The inbox belongs to the hub task, so when the hub ends or crashes every send
## fails at once with "closed" instead of waiting for room.
export def start(options: Options) -> Hub
  inbox: Channel[HubMessage] = Channel.new(HUB_INBOX)
  counters: ATS[String, Int] = ATS.new()
  task = Task.spawn_owning(&run, Launch(inbox: inbox, counters: counters))
  _ = Task.spawn(&ticking, Ticker(inbox: inbox, beat_ms: options.beat_ms))
  return Hub(inbox: inbox, task: task, counters: counters, options: options)
end

## Asks the hub to end; its task returns and later sends fail.
export def stop(hub: Hub) -> Result[Void]
  return hub.inbox.send(HubMessage.Stop, hub.options.broadcast_wait_ms)
end

## Queues a broadcast of an encoded payload; a failure is counted as lost.
export def broadcast(hub: Hub, topic: String, payload: String) -> Result[Void]
  sent = hub.inbox.send(HubMessage.Broadcast(Cast(topic: topic, payload: payload)), hub.options.broadcast_wait_ms)
  if not sent.ok?
    _ = hub.counters.add(LOST, 1)
  end

  return sent
end

## Adds `delta` to a counter of `stats` (the connections do their own counting).
export def count(hub: Hub, name: String, delta: Int) -> Void
  _ = hub.counters.add(name, delta)
end

## A number for a new connection.
export def next_connection(hub: Hub) -> Int
  return hub.counters.add(NEXT_CONNECTION, 1)
end

export def stats(hub: Hub) -> Stats
  return Stats(
    connections: counted(hub, CONNECTIONS),
    subscriptions: counted(hub, SUBSCRIPTIONS),
    drops: counted(hub, DROPS),
    lost: counted(hub, LOST),
  )
end

def counted(hub: Hub, name: String) -> Int
  return hub.counters.get(name).unwrap_or(0)
end

# A tick in the inbox keeps its place among the broadcasts, and a receive timeout would never fire while the inbox
# stays busy: the Rails client calls a connection stale after 6 s without a ping.
def ticking(ticker: Ticker) -> Result[Void]
  while true
    Task.sleep(ticker.beat_ms)
    sent = ticker.inbox.send(HubMessage.Beat, ticker.beat_ms)
    if not sent.ok?
      return ok()
    end
  end

  return ok()
end

def run(launch: Launch) -> Result[Void]
  empty_entries: Map[Int, Entry] = {}
  empty_topics: Map[String, Topic] = {}
  # The state is only fed back to `step`: its effects are the sends to the connections.
  _state = State(entries: empty_entries, topics: empty_topics, beats: 0)
  while true
    received = launch.inbox.recv(IDLE_MS)
    if not received.ok?
      if launch.inbox.closed?
        return ok()
      end

      next
    end

    message = received.unwrap!
    if stop?(message)
      return ok()
    end

    _state = step(_state, message, launch.counters)
  end

  return ok()
end

def stop?(message: HubMessage) -> Bool
  case message
    HubMessage.Stop -> return true
    _ -> return false
  end
end

def step(state: State, message: HubMessage, counters: ATS[String, Int]) -> State
  case message
    HubMessage.Register(registration) -> return register(state, registration)
    HubMessage.Subscribe(attach) -> return subscribe(state, attach)
    HubMessage.Unsubscribe(detach) -> return unsubscribe(state, detach.connection, detach.identifier)
    HubMessage.Disconnect(connection) -> return remove_connection(state, connection)
    HubMessage.Broadcast(cast) -> return fan_out(state, cast, counters)
    HubMessage.Beat -> return beat(state, counters)
    HubMessage.Stop -> return state
  end
end

def register(state: State, registration: Registration) -> State
  keys: List[Key] = []
  entry = Entry(inbox: registration.inbox, every: registration.every, keys: keys)
  return state.with(entries: state.entries.put(registration.connection, entry))
end

def subscribe(state: State, attach: Attach) -> State
  case state.entries.get(attach.connection)
    none -> return state
    some(entry) ->
      topics = state.topics
      keys = entry.keys
      for topic in attach.topics
        topics = with_member(topics, topic, attach.identifier, attach.connection, entry.inbox)
        keys = keys.push(Key(topic: topic, identifier: attach.identifier))
      end

      entries = state.entries.put(attach.connection, entry.with(keys: keys))
      return state.with(entries: entries, topics: topics)
  end
end

def unsubscribe(state: State, connection: Int, identifier: String) -> State
  case state.entries.get(connection)
    none -> return state
    some(entry) ->
      topics = state.topics
      leaving = entry.keys.select do |key| key.identifier == identifier end
      for key in leaving
        topics = without_member(topics, key.topic, identifier, connection)
      end

      kept = entry.keys.select do |key| key.identifier != identifier end
      entries = state.entries.put(connection, entry.with(keys: kept))
      return state.with(entries: entries, topics: topics)
  end
end

def remove_connection(state: State, connection: Int) -> State
  case state.entries.get(connection)
    none -> return state
    some(entry) ->
      topics = state.topics
      for key in entry.keys
        topics = without_member(topics, key.topic, key.identifier, connection)
      end

      return state.with(entries: state.entries.delete(connection), topics: topics)
  end
end

def with_member(
  topics: Map[String, Topic],
  topic: String,
  identifier: String,
  connection: Int,
  inbox: Channel[Event],
) -> Map[String, Topic]
  empty_topic: Topic = {}
  empty_group: Group = {}
  groups = topics.get(topic, empty_topic)
  members = groups.get(identifier, empty_group)
  return topics.put(topic, groups.put(identifier, members.put(connection, inbox)))
end

# A topic or an identifier with no member left leaves the map, so a long run does not keep every name it ever saw.
def without_member(
  topics: Map[String, Topic],
  topic: String,
  identifier: String,
  connection: Int,
) -> Map[String, Topic]
  empty_topic: Topic = {}
  empty_group: Group = {}
  groups = topics.get(topic, empty_topic)
  members = groups.get(identifier, empty_group).delete(connection)
  if members.empty?
    groups = groups.delete(identifier)
  else
    groups = groups.put(identifier, members)
  end

  if groups.empty?
    return topics.delete(topic)
  end

  return topics.put(topic, groups)
end

# Sends without waiting. True when the connection must leave the hub: its inbox is closed already, or it is full
# (a client too slow for the traffic) and is closed now, so that its task drains what is queued and says goodbye.
def leaves?(counters: ATS[String, Int], inbox: Channel[Event], event: Event) -> Bool
  sent = inbox.send(event, 0)
  if sent.ok?
    return false
  end

  if not inbox.closed?
    inbox.close
    _ = counters.add(DROPS, 1)
  end

  return true
end

def fan_out(state: State, cast: Cast, counters: ATS[String, Int]) -> State
  empty_topic: Topic = {}
  groups = state.topics.get(cast.topic, empty_topic)
  gone: List[Int] = []
  for identifier in groups.keys
    frame = Event.Frame(Protocol.message(identifier, cast.payload))
    members = groups[identifier]
    for connection in members.keys
      if leaves?(counters, members[connection], frame)
        gone = gone.push(connection)
      end
    end
  end

  return forget(state, gone)
end

# The Action Cable ping goes to every connection, and the WebSocket ping to those whose turn it is.
def beat(state: State, counters: ATS[String, Int]) -> State
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

  return forget(state.with(beats: beats), gone)
end

def forget(state: State, gone: List[Int]) -> State
  result = state
  for connection in gone
    result = remove_connection(result, connection)
  end

  return result
end
