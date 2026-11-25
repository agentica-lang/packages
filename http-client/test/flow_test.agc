import Connection from "../src/http2/connection"
import Frame from "../src/http2/frame"
import Hpack from "pkg/hpack/hpack"

private

def session(writes: Channel[Connection.Write]) -> Result[Connection.Session]
  listener = try TCP.listen("127.0.0.1", 0)
  socket = try TCP.connect("127.0.0.1", TCP.local_port(listener), 5_000)
  TCP.close_listener(listener)
  incoming: Channel[Bytes] = Channel.new(1)
  reader = Task.spawn do ok() end
  ok(
    Connection.Session(
      socket: socket,
      incoming: incoming,
      reader: reader,
      decoder: Hpack.decoder(),
      writer: some(writes),
    ),
  )
end

def test_a_piece_queued_after_the_reader_took_the_last_returns_its_credit_once() -> Result[Void]
  writes: Channel[Connection.Write] = Channel.new(4)
  opened = try session(writes)
  next_piece = Connection.Piece(body: "b".bytes, credit: 70)
  stream = Connection.Stream(
    id: 1,
    send_credit: 0,
    pending: [next_piece, Connection.Piece(body: "c".bytes, credit: 80)],
    inflight_credit: 50,
  )

  handed = try Connection.handed(Connection.Progress(session: opened, stream: stream), next_piece, 0)
  try Test.eq(handed.stream.inflight_credit, 70)
  try Test.eq(handed.stream.pending.size, 1)
  try Test.eq(handed.stream.receive_credit, 65_535 + 50)
  update = try writes.recv(0)
  try Test.eq(update.bytes, Frame.encode(8, 0, 1, Frame.word(50)))
  try Test.eq(writes.empty?, true)
  TCP.close(opened.socket)
  _ = Task.await(opened.reader, 1_000)
  ok()
end
