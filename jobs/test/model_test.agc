import Model from "../specs/model"
import {Add, Backoff, Batch, Extension, Request, Settings, Take} from "../specs/protocol"

private

def start(max_jobs: Int) -> Request = Request.Start(Settings(max_jobs: max_jobs))

def enqueue(queue: String, text: String, rows: List[List[String]]) -> Request
  Request.Enqueue(Add(queue: queue, text: text, table: [["setting", "value"]] + rows))
end

def fetch(name: String, ms: Int) -> Request = Request.Fetch(Take(queue: "q", name: name, lease_ms: ms))

def main() -> Void
  Test.run([
    Test.test("the model follows the contract: leases, attempts, expiry, the unique key and the last attempt") do
      calls = [
        start(8),
        enqueue("q", "a", [["max_attempts", "2"], ["unique_key", "k"]]),
        enqueue("q", "b", [["unique_key", "k"]]),
        fetch("w", 1_000),
        Request.Counts("q"),
        Request.Advance(1_000),
        Request.Ack("w"),
        fetch("w", 1_000),
        Request.Advance(1_000),
        Request.Counts("q"),
        Request.Advance(1),
        Request.Counts("q"),
      ]

      return Test.eq(
        Model.replies(calls),
        [
          "ok",
          "ok 1",
          "ok 1 duplicate",
          "ok a attempt 1",
          "ready 0 scheduled 0 leased 1 dead 0",
          "ok",
          "error jobs.lease_lost",
          "ok a attempt 2",
          "ok",
          "ready 0 scheduled 0 leased 0 dead 1",
          "ok",
          "ready 0 scheduled 0 leased 0 dead 1",
        ],
      )
    end,
    Test.test("the model keeps a retry for later, releases without the attempt, and refuses past max_jobs") do
      calls = [
        start(1),
        enqueue("q", "a", []),
        enqueue("q", "b", []),
        fetch("w", 5_000),
        Request.Retry(Backoff(name: "w", ms: 2_000)),
        fetch("w", 5_000),
        Request.Advance(2_000),
        fetch("w", 5_000),
        Request.Release("w"),
        fetch("w", 5_000),
      ]

      return Test.eq(
        Model.replies(calls),
        [
          "ok",
          "ok 1",
          "error jobs.full",
          "ok a attempt 1",
          "ok",
          "ok none",
          "ok",
          "ok a attempt 2",
          "ok",
          "ok a attempt 2",
        ],
      )
    end,
    Test.test(
      "the model takes a batch whole or not at all, several jobs in a fetch, and keeps the error of a retry",
    ) do
      calls = [
        start(4),
        Request.EnqueueAll(Batch(queue: "q", text: "a,b,c")),
        Request.EnqueueAll(Batch(queue: "q", text: "d,e")),
        Request.Fetch(Take(queue: "q", name: "w", lease_ms: 5_000, max: 2)),
        Request.Retry(Backoff(name: "w/2", ms: 0, why: "boom")),
        Request.Fetch(Take(queue: "q", name: "x", lease_ms: 5_000, max: 3)),
        Request.Ack("x/2"),
        Request.Retry(Backoff(name: "x", ms: 0)),
        Request.Fetch(Take(queue: "q", name: "y", lease_ms: 5_000)),
      ]

      return Test.eq(
        Model.replies(calls),
        [
          "ok",
          "ok 1,2,3",
          "error jobs.full",
          "ok a attempt 1, b attempt 1",
          "ok",
          "ok b attempt 2 last_error boom, c attempt 1",
          "ok",
          "ok",
          "ok b attempt 3 last_error boom",
        ],
      )
    end,
    Test.test("the model passes over a full group, and counts the leases of one fetch") do
      calls = [
        start(8),
        enqueue("q", "a", [["group", "g"]]),
        enqueue("q", "b", [["group", "g"]]),
        enqueue("q", "c", []),
        Request.Fetch(Take(queue: "q", name: "w", lease_ms: 5_000, max: 3, limit: 1)),
        Request.Fetch(Take(queue: "q", name: "x", lease_ms: 5_000, max: 3, limit: 1)),
        Request.Ack("w"),
        Request.Fetch(Take(queue: "q", name: "y", lease_ms: 5_000, max: 3, limit: 1)),
        Request.Enqueue(Add(queue: "r", text: "d", table: [["setting", "value"], ["group", "g"]])),
        Request.Fetch(Take(queue: "r", name: "z", lease_ms: 5_000, limit: 1)),
      ]

      return Test.eq(
        Model.replies(calls),
        [
          "ok",
          "ok 1",
          "ok 2",
          "ok 3",
          "ok a attempt 1 group g, c attempt 1",
          "ok none",
          "ok",
          "ok b attempt 1 group g",
          "ok 4",
          "ok d attempt 1 group g",
        ],
      )
    end,
    Test.test("a seed gives the same script, and the script answers with its own replies") do
      first = Model.script(7, 200)
      try Test.eq(first.map(->(call) { call.reply }), Model.script(7, 200).map(->(call) { call.reply }))
      try Test.eq(first.size, 201)
      return Test.eq(Model.replies(first.map(->(call) { call.req })), first.map(->(call) { call.reply }))
    end,
  ])
end
