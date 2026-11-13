## The keeper of one worker: a task that makes the worker, so that it owns the worker's handles, then waits for the
## owner's orders, and ends the worker when the owner closes its channel. A handle can be handed only to a new task,
## never back to the owner, so each worker keeps the task that made it; callers use the worker directly, not through
## this task.

import Types from "types"

## An order of the owner: ping the idle worker, or run `checkin` with how the body ended, for a body that ran in a task
## of the pool (`lease_ms` above 0) or a caller whose task ended while it held the worker.
enum Order
  Ping
  Checkin(Types.Outcome)
end

## What a keeper needs: the spec, the id of its worker, the owner's inbox, and its own channel of orders, which the
## owner closes to end the worker.
struct Keeper[A, W]
  spec: Types.Spec[A, W]
  id: Int
  inbox: Channel[Types.Msg[W]]
  orders: Channel[Order]
end

## Makes the worker, tells the owner, then serves the orders until its channel closes, and ends the worker.
def keep[A, W](keeper: Keeper[A, W]) -> Void
  made = keeper.spec.init.call(keeper.spec.config)
  tell(keeper, Types.Msg.Ready(Types.Made(id: keeper.id, worker: made)))
  case made
    ok(worker) -> serve(keeper, worker)
    error(_) -> return
  end
end

## True when a function of the spec, which runs in the task given, gives `ok` within HOOK_MS. A task that crashes is
## false; one that hangs is cancelled and false, so that it ends its worker instead of holding it for ever.
def settled?(task: Task[Result[Void]]) -> Bool
  case Task.await(task, HOOK_MS)
    Await.Done(result) -> result.ok?
    Await.TimedOut ->
      Task.cancel(task)
      false
  end
end

private

# The keeper waits for a long time between two looks, since a closed channel wakes it at once.
WAIT_MS = 60_000
# The owner's inbox is never full in practice (see owner.agc); a send that cannot get in means the owner is gone.
SEND_MS = 5_000
# How long a function of the spec may run in a task of its own: a ping, a `checkin`, a `checkout`.
HOOK_MS = 5_000

def serve[A, W](keeper: Keeper[A, W], worker: W) -> Void
  while not (keeper.orders.closed? and keeper.orders.empty?)
    case keeper.orders.recv(WAIT_MS)
      ok(order) -> tell(keeper, Types.Msg.Check(Types.Checked(id: keeper.id, keep: obey(keeper.spec, worker, order))))
      error(_) -> next
    end
  end

  keeper.spec.terminate.call(worker)
end

# A worker whose body was cut off is never kept, whatever `checkin` says.
def obey[A, W](spec: Types.Spec[A, W], worker: W, order: Order) -> Bool
  case order
    Order.Ping -> settled?(Task.spawn do spec.ping.call(worker) end)
    Order.Checkin(outcome) ->
      kept = settled?(Task.spawn do spec.checkin.call(worker, outcome) end)
      kept and outcome != Types.Outcome.TimedOut
  end
end

def tell[A, W](keeper: Keeper[A, W], msg: Types.Msg[W]) -> Void
  _ = keeper.inbox.send(msg, SEND_MS)
end
