## The keeper of one worker: a task that makes the worker, so that it owns the worker's handles, then waits for the
## owner's orders, and ends the worker when the owner closes its channel. A handle can be handed only to a new task,
## never back to the owner, so each worker keeps the task that made it; callers use the worker directly, not through
## this task.

import Types from "types"

## What a keeper needs: the spec, the id of its worker, the owner's inbox, and its own channel of orders, which the
## owner closes to end the worker.
struct Keeper[A, W]
  spec: Types.Spec[A, W]
  id: Int
  inbox: Channel[Types.Msg[W]]
  orders: Channel[Types.Order]
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

# `checked` is the last lease checked in: a second order for it is dropped.
def serve[A, W](keeper: Keeper[A, W], worker: W) -> Void
  checked = 0
  while not (keeper.orders.closed? and keeper.orders.empty?)
    case keeper.orders.recv(WAIT_MS)
      ok(Types.Order.Ping(seq)) -> report(keeper, seq, settled?(Task.spawn do keeper.spec.ping.call(worker) end))
      ok(Types.Order.Checkin(turn)) if turn.seq > checked ->
        checked = turn.seq
        report(keeper, turn.seq, checked_in?(keeper.spec, worker, turn.outcome))
      _ -> next
    end
  end

  keeper.spec.terminate.call(worker)
end

# A worker whose body was cut off is never kept, whatever `checkin` says.
def checked_in?[A, W](spec: Types.Spec[A, W], worker: W, outcome: Types.Outcome) -> Bool
  kept = settled?(Task.spawn do spec.checkin.call(worker, outcome) end)
  kept and outcome != Types.Outcome.TimedOut
end

def report[A, W](keeper: Keeper[A, W], seq: Int, keep: Bool) -> Void
  tell(keeper, Types.Msg.Check(Types.Checked(id: keeper.id, seq: seq, keep: keep)))
end

def tell[A, W](keeper: Keeper[A, W], msg: Types.Msg[W]) -> Void
  _ = keeper.inbox.send(msg, SEND_MS)
end
