import Connection from "../src/http2/connection"
import Session from "../src/http2/session"

def test_expired_open_and_data_do_not_reach_a_blocked_writer() -> Result[Void]
  out: Channel[Connection.Write] = Channel.new(8)
  inbox: Channel[Session.Msg] = Channel.new(8)
  writes: Channel[Bytes] = Channel.new(8)
  gate: Channel[Bool] = Channel.new(1)
  writer = Task.spawn do Session.write_loop(out, inbox, ->(bytes) { write(bytes, writes, gate) }) end
  result = queued(out, inbox, writes, gate)
  out.close
  Task.cancel(writer)
  _ = Task.await(writer)
  result
end

private

def queued(
  out: Channel[Connection.Write],
  inbox: Channel[Session.Msg],
  writes: Channel[Bytes],
  gate: Channel[Bool],
) -> Result[Void]
  try out.send(Connection.Write(bytes: "first".bytes), 100)
  try Test.eq(try writes.recv(1_000), "first".bytes)
  until = Time.monotonic_ms() + 20
  try out.send(Connection.Write(bytes: "expired headers".bytes, stream: 1, deadline: some(until), opening: true), 100)
  try out.send(Connection.Write(bytes: "expired data".bytes, stream: 1, deadline: some(until), credit: 7), 100)
  try out.send(Connection.Write(bytes: "invalid reset".bytes, stream: 1, reset: true), 100)
  try out.send(Connection.Write(bytes: "other stream".bytes, stream: 3), 100)
  Task.sleep(30)
  try gate.send(true, 100)
  try Test.eq(try writes.recv(1_000), "other stream".bytes)
  _ = try inbox.recv(1_000)
  try skipped(inbox, 0)
  skipped(inbox, 7)
end

def write(bytes: Bytes, writes: Channel[Bytes], gate: Channel[Bool]) -> Result[Void]
  try writes.send(bytes, 100)
  if bytes == "first".bytes
    _ = try gate.recv(1_000)
  end

  ok()
end

def skipped(inbox: Channel[Session.Msg], credit: Int) -> Result[Void]
  case try inbox.recv(1_000)
    Session.Msg.Skipped(item) -> Test.eq(item.credit, credit)
    _ -> error("the expired write was not reported")
  end
end
