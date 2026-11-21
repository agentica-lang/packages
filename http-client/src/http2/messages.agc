import Connection from "connection"

struct Call
  request: Connection.Request
  connect_ms: Int
  caller: TaskRef
  reply: Channel[Result[Connection.Response]]
  admission_deadline: Int
  retried: Bool = false
end

enum Origin
  Submit(Call)
  CallerDown(Int)
  Capacity(Int, Int, Bool)
  Complete(Int, Int, Result[Connection.Response])
  SessionDown(Int)
  Close(Int)
end
