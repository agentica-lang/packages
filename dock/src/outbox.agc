## The outbox of one client: a queue of messages with a limit in bytes, and the writer task that empties it.
##
## Nobody waits for a client. `push` never blocks, and a client that does not read is dropped when its queued bytes
## pass the cap.

import Counters from "stats"

# Counted for each queued message besides its bytes, so a flood of tiny messages is bounded too.
OVERHEAD = 64
# What a message of one byte is charged: no message (an empty one is not queued) is charged less.
export MIN_CAP = 65
# A channel holds at most this many messages.
CHANNEL_SLOTS = 1_048_576
# The most that `cap` can be: the channel of `build` (`slots` below) must fit CHANNEL_SLOTS.
export MAX_CAP = (CHANNEL_SLOTS - 2) * MIN_CAP
# TCP.send_bytes takes at most 1 MiB.
MAX_SEND = 1_048_576
# The most messages the writer joins into one send.
BATCH = 256
POLL_MS = 1000
# A client that takes nothing for this long is gone.
WRITE_MS = 5000
# The pending bytes live in an ATS table under these keys: the bytes queued and not yet written (the writer
# subtracts after each send, so it covers the send in progress too), and whether `finish` was called.
BYTES_KEY = 0
CLOSING_KEY = 1
# Set when the client was counted as dropped, so two tasks that both see the cap passed count it once.
export DROPPED_KEY = 2

export enum Out
  Data(Bytes)
  Close
end

export struct Outbox
  queue: Channel[Out]
  pending: ATS[Int, Int]
  cap: Int
  # The counters of the server, where a drop at the cap is counted.
  stats: ATS[Int, Int]
end

export struct Pipe
  socket: Socket
  outbox: Outbox
end

struct Batch
  pieces: List[Bytes]
  counted: Int
  closing: Bool
end

## An outbox that holds `cap` bytes, from MIN_CAP to MAX_CAP.
##
## The channel has room for every message the rule of `refused?` lets in, so the cap, not a full channel, is what
## drops a client. Proof: a message is let in when the charges before it are at most `cap`, and every charge is at
## least MIN_CAP, so at most `cap / MIN_CAP + 1` messages wait (the ones before the last add up to `cap` at most),
## and the `Close` marker is one more.
export def build(cap: Int, stats: ATS[Int, Int]) -> Outbox
  queue: Channel[Out] = Channel.new(slots(cap))
  pending: ATS[Int, Int] = ATS.new()
  return Outbox(queue: queue, pending: pending, cap: cap, stats: stats)
end

## What a message of `size` bytes is charged: its bytes and OVERHEAD, but never more than `cap`, so a message bigger
## than the cap does not block the small ones after it for ever.
export def charge(size: Int, cap: Int) -> Int
  if size + OVERHEAD > cap
    return cap
  end

  return size + OVERHEAD
end

## Whether a message charged `size`, which made the pending charges `total` with it, must be refused: when the
## charges waiting before it pass `cap`. So at most `cap` (or one message bigger than it) plus the message being
## queued is in memory, and a client that reads is not dropped for one big reply followed by a short one.
export def refused?(total: Int, size: Int, cap: Int) -> Bool
  return total - size > cap
end

## Queues `bytes`; the error says the client is gone or was dropped (its socket is closed then).
export def push(outbox: Outbox, socket: Socket, bytes: Bytes) -> Result[Void]
  if outbox.queue.closed? or outbox.pending.has_key?(CLOSING_KEY)
    return error("dock: the connection is closed")
  end

  if bytes.empty?
    return ok()
  end

  size = charge(bytes.size, outbox.cap)
  total = outbox.pending.add(BYTES_KEY, size)
  if refused?(total, size, outbox.cap)
    if outbox.pending.add(DROPPED_KEY, 1) == 1
      _ = outbox.stats.add(Counters.DROPPED, 1)
    end

    drop(outbox, socket)
    return error("dock: the client does not read: dropped at the outbox cap of #{outbox.cap} bytes")
  end

  case outbox.queue.send(Out.Data(bytes), 0)
    ok(_) -> return ok()
    error(_) ->
      drop(outbox, socket)
      return error("dock: the connection is closed")
  end
end

## Closes the connection after what is queued is written. The channel has room for the marker (see `build`); if it
## is closed already, so is the socket, and any other failure closes it here, so the connection cannot stay open.
## A `push` of another task that checked the flag just before this ran may queue behind the marker and be lost.
export def finish(outbox: Outbox, socket: Socket) -> Void
  outbox.pending.put(CLOSING_KEY, 1)
  case outbox.queue.send(Out.Close, 0)
    ok(_) -> nil
    error(_) -> drop(outbox, socket)
  end
end

## Runs as a task of the client. It ends when the queue is closed and empty, at a `Close`, or when a send fails; then
## it closes the socket, which also ends the receive of the handler.
export def run(pipe: Pipe) -> Void
  queue = pipe.outbox.queue
  while true
    case queue.recv(POLL_MS)
      ok(first) ->
        batch = collect(pipe.outbox, first)
        sent = send_all(pipe.socket, Bytes.concat(batch.pieces))
        _ = pipe.outbox.pending.add(BYTES_KEY, -batch.counted)
        if not sent or batch.closing
          break
        end

      error(_) ->
        if queue.closed? and queue.empty?
          break
        end
    end
  end

  queue.close
  TCP.close(pipe.socket)
end

# The channel holds this many messages.
def slots(cap: Int) -> Int
  return cap / MIN_CAP + 2
end

# A dropped client: the closed queue refuses later pushes, the closed socket wakes the writer and the handler.
def drop(outbox: Outbox, socket: Socket) -> Void
  outbox.queue.close
  TCP.close(socket)
end

# Takes the waiting messages (not more than BATCH or about MAX_SEND bytes) so one send carries many replies.
def collect(outbox: Outbox, first: Out) -> Batch
  batch = add(Batch(pieces: [], counted: 0, closing: false), first, outbox.cap)
  taken = 1
  while taken < BATCH and batch.counted < MAX_SEND and not batch.closing
    case outbox.queue.recv(0)
      error(_) -> break
      ok(next) -> batch = add(batch, next, outbox.cap)
    end

    taken += 1
  end

  return batch
end

# `counted` is what `push` charged, so the writer subtracts exactly that.
def add(batch: Batch, out: Out, cap: Int) -> Batch
  case out
    Out.Data(bytes) ->
      return batch.with(pieces: batch.pieces.push(bytes), counted: batch.counted + charge(bytes.size, cap))
    Out.Close -> return batch.with(closing: true)
  end
end

def send_all(socket: Socket, bytes: Bytes) -> Bool
  rest = bytes
  while not rest.empty?
    case TCP.send_bytes(socket, rest.take(MAX_SEND), WRITE_MS)
      ok(_) -> rest = rest.drop(MAX_SEND)
      error(_) -> return false
    end
  end

  return true
end
