import Dial from "../src/dial"
import HTTP from "std/http"
import Link from "../src/link"
import Pool from "pkg/pool/pool"

private

def crash() -> Result[Void]
  empty: List[Int] = []
  puts(empty[1])
  ok()
end

def no_address(_host: String) -> Result[List[String]] = ok([])

def crashed_link() -> Link.Link
  inbox: Channel[Link.Order] = Channel.new(1)
  task = Task.spawn do Link.guard(inbox, &crash) end
  _ = Task.await(task, 5_000)
  Link.Link(inbox: inbox, task: task)
end

def test_a_link_whose_task_crashed_fails_at_once_and_its_pool_replaces_it() -> Result[Void]
  link = crashed_link()
  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(own: false, resolver: &no_address, cache: cache, cache_ms: 0, public_only: false)
  origin = Link.Origin(url: "http://127.0.0.1:9", options: HTTP.ClientOptions(), dialer: dialer)
  spec = Link.spec(origin, 1, 100, 1_000, 1_000)
  began = Time.monotonic_ms()
  try Test.eq(Link.take(link).some?, false)
  try Test.error?(Link.connect(link, 10_000))
  try Test.eq(Time.monotonic_ms() - began < 1_000, true)
  try Test.error?(spec.ping.call(link))
  Test.error?(spec.checkin.call(link, Pool.Outcome.Done))
end
