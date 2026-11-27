## The task that owns the listener of a node: it accepts connections and gives each to a task of its own, which runs
## the handshake.

import Types from "types"
import Link from "link"

## What the task needs, and the channel that gets the port that it listens on, or why it could not.
struct Accept
  config: Types.Config
  host: String
  port: Int
  ready: Channel[Result[Int]]
end

## Listens, tells the port, and accepts until the task is cancelled or the listener fails.
def run(args: Accept) -> Void
  case TCP.listen(args.host, args.port)
    error(e) -> _ = args.ready.send(error("cluster: cannot listen: #{e.message}", kind: Types.ARGUMENT), 0)
    ok(listener) ->
      _ = args.ready.send(ok(TCP.local_port(listener)), 0)
      accept_loop(listener, args.config)
  end
end

private

ACCEPT_MS = 1000
PAUSE_MS = 10

def accept_loop(listener: TCP.Listener, config: Types.Config) -> Void
  running = true
  while running
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) -> _ = Task.spawn_owning(&Link.serve, Link.Served(config: config, socket: socket))
      error(e) ->
        if e.message.include?("closed")
          running = false
        else
          Task.sleep(PAUSE_MS)
        end
    end
  end
end
