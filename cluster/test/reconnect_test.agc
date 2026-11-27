import Cluster from "../cluster"

private

COOKIE = "the-cookie-of-the-cluster"
RETRY_MS = 50
OBSERVE_MS = 1500
WAIT_MS = 2000
POLL_MS = 10

def node(name: String, cookie: String, peers: List[String]) -> Cluster.Node
  options = Cluster.Options(
    name: name,
    cookie: cookie,
    peers: peers,
    reconnect_ms: RETRY_MS,
    reconnect_max_ms: 4 * RETRY_MS,
  )

  Cluster.start(options).unwrap!
end

# A peer with another cookie refuses every handshake, and the node keeps trying with a wait that grows: with waits of
# 50, 100, 200 and then 200 ms (and a fifth more) it makes about 8 attempts in 1.5 s, where a fixed wait of 50 ms
# would make about 30.
def wrong_cookie_backs_off() -> Result[Void]
  beta = node("beta", "another-cookie-of-the-cluster", [])
  alpha = node("alpha", COOKIE, ["beta@127.0.0.1:#{Cluster.port(beta)}"])
  Task.sleep(OBSERVE_MS)
  attempts = Cluster.refused(alpha)
  try Cluster.stop(alpha, 1000)
  try Cluster.stop(beta, 1000)
  try Test.assert(attempts >= 3, "the node tried #{attempts} times, and it should keep trying")
  Test.assert(attempts <= 15, "the node tried #{attempts} times in #{OBSERVE_MS} ms, and the wait did not grow")
end

# The node stops while it waits to dial a peer that is down: nothing is left running.
def stop_during_a_wait() -> Result[Void]
  before = Task.pending_count()
  beta = node("beta", COOKIE, [])
  port = Cluster.port(beta)
  try Cluster.stop(beta, 1000)
  alpha = node("alpha", COOKIE, ["beta@127.0.0.1:#{port}"])
  Task.sleep(2 * RETRY_MS)
  try Cluster.stop(alpha, 1000)
  deadline = Time.monotonic_ms() + WAIT_MS
  while Task.pending_count() > before and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  Test.eq(Task.pending_count(), before)
end

def test_a_peer_that_refuses_every_handshake_is_tried_again_with_a_wait_that_grows() -> Result[Void]
  wrong_cookie_backs_off()
end

def test_stopping_a_node_during_a_wait_leaves_no_task() -> Result[Void] = stop_during_a_wait()
