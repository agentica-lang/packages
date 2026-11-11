## The counters of a server: one ATS table that the supervisor and the writers of the clients update.

export OPEN = 0
export ACCEPTED = 1
export REFUSED = 2
export DROPPED = 3
export CRASHED = 4
# Not in the snapshot: the `on_close` callbacks that run now.
export HOOKS = 5

## A snapshot of the counters, read with `Dock.stats`.
export struct Stats
  ## Connections whose handler has not ended yet.
  open: Int
  ## Connections that got a handler (those over `max_connections` are not counted here).
  accepted: Int
  ## Connections closed at once because `max_connections` were open.
  refused: Int
  ## Clients closed because their queued bytes passed `max_outbox_bytes`.
  dropped: Int
  ## Handlers that crashed.
  crashed: Int
end

export def snapshot(table: ATS[Int, Int]) -> Stats
  Stats(
    open: table.add(OPEN, 0),
    accepted: table.add(ACCEPTED, 0),
    refused: table.add(REFUSED, 0),
    dropped: table.add(DROPPED, 0),
    crashed: table.add(CRASHED, 0),
  )
end
