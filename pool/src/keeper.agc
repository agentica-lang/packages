## The keeper of one worker: a task that makes the worker, so that it owns the worker's handles, then waits for the
## owner's orders, and ends the worker when the owner closes its channel. A handle can be handed only to a new task,
## never back to the owner, so each worker keeps the task that made it; callers use the worker directly, not through
## this task.

import Types from "types"

## An order of the owner: ping the idle worker, or run `checkin` for a caller whose task ended while it held the
## worker, with how its body ended.
enum Order
  Ping
  Lost(Types.Outcome)
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

private

# The keeper waits for a long time between two looks, since a closed channel wakes it at once.
WAIT_MS = 60_000
# The owner's inbox is never full in practice (see owner.agc); a send that cannot get in means the owner is gone.
SEND_MS = 5_000
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
    Order.Lost(outcome) ->
      kept = settled?(Task.spawn do spec.checkin.call(worker, outcome) end)
      kept and outcome != Types.Outcome.TimedOut
  end
end

# True when the hook gives `ok` within HOOK_MS. It runs in a task of its own, so that one that hangs is cancelled and
# its worker ended, instead of holding the worker in the keeper for ever.
def settled?(task: Task[Result[Void]]) -> Bool
  case Task.await(task, HOOK_MS)
    Await.Done(result) -> result.ok?
    Await.TimedOut ->
      Task.cancel(task)
      false
  end
end

def tell[A, W](keeper: Keeper[A, W], msg: Types.Msg[W]) -> Void
  _ = keeper.inbox.send(msg, SEND_MS)
end
