## The outbox of one client: a queue of messages with a limit in bytes, and the writer task that empties it.
##
## Nobody waits for a client. `push` never blocks, and a client that does not read is dropped when its queued bytes
## pass the cap.

# The most that `cap` can be: its channel holds `cap / OVERHEAD + 2` messages, and a channel holds 1,048,576.
export MAX_CAP = 67_108_864
# Counted for each queued message besides its bytes, so a flood of tiny messages is bounded too.
OVERHEAD = 64
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

export enum Out
  Data(Bytes)
  Close
end

export struct Outbox
  queue: Channel[Out]
  pending: ATS[Int, Int]
  cap: Int
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

## An outbox that holds `cap` bytes. The channel has room for as many messages as the cap allows, so the cap, not
## a full channel, is what drops a client.
export def build(cap: Int) -> Outbox
  queue: Channel[Out] = Channel.new(cap / OVERHEAD + 2)
  pending: ATS[Int, Int] = ATS.new()
  return Outbox(queue: queue, pending: pending, cap: cap)
end

## Whether a message of `size` counted bytes must be refused when the pending bytes are `total` with it. A message
## with nothing pending before it is never refused, so one bigger than the cap still goes through.
export def refused?(total: Int, size: Int, cap: Int) -> Bool
  return total > size and total > cap
end

## Queues `bytes`; the error says the client is gone or was dropped (its socket is closed then).
export def push(outbox: Outbox, socket: Socket, bytes: Bytes) -> Result[Void]
  if outbox.queue.closed? or outbox.pending.has_key?(CLOSING_KEY)
    return error("dock: the connection is closed")
  end

  if bytes.empty?
    return ok()
  end

  size = bytes.size + OVERHEAD
  total = outbox.pending.add(BYTES_KEY, size)
  if refused?(total, size, outbox.cap)
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

## Closes the connection after what is queued is written.
export def finish(outbox: Outbox) -> Void
  outbox.pending.put(CLOSING_KEY, 1)
  _ = outbox.queue.send(Out.Close, 0)
end

## Runs as a task of the client. It ends when the queue is closed and empty, at a `Close`, or when a send fails; then
## it closes the socket, which also ends the receive of the handler.
export def run(pipe: Pipe) -> Void
  queue = pipe.outbox.queue
  while true
    case queue.recv(POLL_MS)
      ok(first) ->
        batch = collect(queue, first)
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

# A dropped client: the closed queue refuses later pushes, the closed socket wakes the writer and the handler.
def drop(outbox: Outbox, socket: Socket) -> Void
  outbox.queue.close
  TCP.close(socket)
end

# Takes the waiting messages (not more than BATCH or about MAX_SEND bytes) so one send carries many replies.
def collect(queue: Channel[Out], first: Out) -> Batch
  batch = add(Batch(pieces: [], counted: 0, closing: false), first)
  taken = 1
  while taken < BATCH and batch.counted < MAX_SEND and not batch.closing
    case queue.recv(0)
      error(_) -> break
      ok(next) -> batch = add(batch, next)
    end

    taken += 1
  end

  return batch
end

def add(batch: Batch, out: Out) -> Batch
  case out
    Out.Data(bytes) ->
      return batch.with(pieces: batch.pieces.push(bytes), counted: batch.counted + bytes.size + OVERHEAD)
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
