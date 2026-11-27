import Cluster from "../cluster"

private

COOKIE = "the-cookie-of-the-cluster"
CHANGES = 40
WAIT_MS = 5000
POLL_MS = 10

def node(name: String) -> Cluster.Node = Cluster.start(Cluster.Options(name: name, cookie: COOKIE)).unwrap!

def mailbox_names() -> List[String] = (1..CHANGES).map { |i| "mailbox-#{i}" }

def register_all(alpha: Cluster.Node, names: List[String]) -> Result[Void]
  inbox: Channel[Cluster.Delivery] = Channel.new(1)
  for name in names
    try Cluster.register(alpha, name, inbox.address, ->(delivery) { delivery })
  end

  ok()
end

def seen_by(node: Cluster.Node, group: String) -> List[String]
  nobody: List[Cluster.Member] = []
  Cluster.group_members(node, group).unwrap_or(nobody).map { |member| member.mailbox }
end

def same_as(alpha: Cluster.Node, beta: Cluster.Node) -> Bool
  deadline = Time.monotonic_ms() + WAIT_MS
  while seen_by(beta, "workers") != seen_by(alpha, "workers") and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  seen_by(beta, "workers") == seen_by(alpha, "workers")
end

# Many changes in a row: the peer ends with what the node has, whatever frames were left out on the way.
def many_changes_end_the_same() -> Result[Void]
  alpha = node("alpha")
  beta = node("beta")
  names = mailbox_names()
  try register_all(alpha, names)
  _ = try Cluster.connect(beta, "127.0.0.1:#{Cluster.port(alpha)}")
  for name in names
    try Cluster.group_join(alpha, "workers", name)
  end

  for name in names.take(CHANGES / 2)
    try Cluster.group_leave(alpha, "workers", name)
  end

  try Test.eq(seen_by(alpha, "workers").size, CHANGES / 2)
  try Test.assert(
    same_as(alpha, beta),
    "beta sees #{seen_by(beta, "workers").size} and alpha #{seen_by(alpha, "workers").size}",
  )

  try Cluster.stop(beta, 1000)
  Cluster.stop(alpha, 1000)
end

def test_a_peer_ends_with_the_members_of_the_node_after_many_changes() -> Result[Void]
  before = Task.pending_count()
  try many_changes_end_the_same()
  deadline = Time.monotonic_ms() + WAIT_MS
  while Task.pending_count() > before and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  Test.eq(Task.pending_count(), before)
end

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> ""
    error(e) -> e.kind
  end
end

def test_a_message_to_a_group_needs_a_valid_name_and_a_time() -> Result[Void]
  alpha = node("alpha")
  try Test.eq(kind_of(Cluster.group_send(alpha, "", "x".bytes)), Cluster.ARGUMENT)
  try Test.eq(kind_of(Cluster.group_send(alpha, "workers", "x".bytes, 0)), Cluster.ARGUMENT)
  try Test.eq(Cluster.group_send(alpha, "workers", "x".bytes), ok(0))
  Cluster.stop(alpha, 1000)
end
