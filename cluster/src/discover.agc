## The task that finds the nodes of a cluster by a name: it resolves the name, with all its A and AAAA records, and
## tells the node the addresses, again and again, since the records change as nodes come and go.

import Actor from "std/actor"
import Types from "types"

## What the task needs: where to tell, the name and port to resolve, and how often.
struct Find
  node: Address[Types.Msg]
  endpoint: Types.Endpoint
  every_ms: Int
  lookup_ms: Int
end

## Resolves the name every `every_ms`, and tells the node the addresses it got. A name that does not resolve is tried
## again the next time.
def find(args: Find) -> Void
  while true
    case DNS.lookup(args.endpoint.host, args.lookup_ms)
      ok(addresses) -> tell(args, addresses)
      error(_) -> nil
    end

    Task.sleep(args.every_ms)
  end
end

private

def tell(args: Find, addresses: List[String]) -> Void
  endpoints = addresses.map { |address| Types.Endpoint(host: address, port: args.endpoint.port) }
  _ = Actor.cast(args.node, Types.Msg.Found(endpoints))
end
