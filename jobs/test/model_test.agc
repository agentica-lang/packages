import Model from "../specs/model"
import {Request} from "../specs/protocol"

private

def start(max_jobs: Int) -> Request = Request(op: "start", table: [["setting", "value"], ["max_jobs", "#{max_jobs}"]])

def enqueue(queue: String, text: String, rows: List[List[String]]) -> Request
  Request(op: "enqueue", queue: queue, text: text, table: [["setting", "value"]] + rows)
end

def fetch(name: String, ms: Int) -> Request = Request(op: "fetch", queue: "q", name: name, number: ms)

def main() -> Void
  Test.run([
    Test.test("the model follows the contract: leases, attempts, expiry, the unique key and the last attempt") do
      calls = [
        start(8),
        enqueue("q", "a", [["max_attempts", "2"], ["unique_key", "k"]]),
        enqueue("q", "b", [["unique_key", "k"]]),
        fetch("w", 1_000),
        Request(op: "counts", queue: "q"),
        Request(op: "advance", number: 1_000),
        Request(op: "ack", name: "w"),
        fetch("w", 1_000),
        Request(op: "advance", number: 1_000),
        Request(op: "counts", queue: "q"),
        Request(op: "advance", number: 1),
        Request(op: "counts", queue: "q"),
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
        Request(op: "retry", name: "w", number: 2_000),
        fetch("w", 5_000),
        Request(op: "advance", number: 2_000),
        fetch("w", 5_000),
        Request(op: "release", name: "w"),
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
    Test.test("a seed gives the same script, and the script answers with its own replies") do
      first = Model.script(7, 200)
      try Test.eq(first.map(->(call) { call.reply }), Model.script(7, 200).map(->(call) { call.reply }))
      try Test.eq(first.size, 201)
      return Test.eq(Model.replies(first.map(->(call) { call.req })), first.map(->(call) { call.reply }))
    end,
  ])
end
