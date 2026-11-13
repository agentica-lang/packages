Feature: Callers
  The body of a job runs in a task of its own when lease_ms is above 0, and in the caller when it is 0. A caller that
  ends while it holds a resource (a crash, a cancel) does not keep it: its keeper checks it in, as checkin decides
  after Crashed, and always ends it after TimedOut. Each error of the pool has a kind.

  Scenario: The errors of the pool have kinds under pool, and the timeouts under pool.timeout
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | checkout_ms | 100   |
      | lease_ms    | 300   |
      | max_waiting | 1     |
    When job "A" never returns
    And job "B" holds a resource for 10 ms
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" fails with the kind "pool.timeout.lease"
    And job "B" fails with the kind "pool.timeout.checkout"
    And job "C" fails with the kind "pool.full"
    When I close the pool, giving the jobs 100 ms to finish
    And job "D" holds a resource for 10 ms
    And I wait for the jobs
    Then job "D" fails with the kind "pool.closed"

  Scenario Outline: A body that crashes in its caller (lease_ms 0) crashes it, and checkin decides (<keep_dirty>)
    Given a pool with:
      | setting    | value        |
      | size       | 1            |
      | lease_ms   | 0            |
      | keep_dirty | <keep_dirty> |
    When job "A" crashes
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error task crashed"
    And job "A" fails with the kind "task.crashed"
    And job "B" succeeds
    And the count "checkin_crashed" is 1
    And the count "made" is <made>
    And the count "terminated" reaches <terminated> within 2000 ms

    Examples:
      | keep_dirty | made | terminated |
      | false      | 2    | 1          |
      | true       | 1    | 0          |

  Scenario: A caller cancelled while its body runs in it (lease_ms 0) gives up its resource, which is replaced
    Given a pool with:
      | setting  | value |
      | size     | 1     |
      | lease_ms | 0     |
    When job "A" holds a resource for 3000 ms
    And the caller of job "A" is cancelled
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "ok 2"
    And the count "checkin_timed_out" is 1
    And the count "terminated" reaches 1 within 2000 ms
    And the count "double_lease" is 0

  Scenario: A caller cancelled while it waits leaves the line, and the next one is served
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 300 ms
    And job "B" holds a resource for 10 ms
    And the caller of job "B" is cancelled
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "C" gets "ok 1"
    And the count "body_ran" is 2
    And the count "made" is 1

  Scenario: A resource that checkout refuses is ended, and the caller gets the next one before the callers after it
    Given a pool with:
      | setting         | value |
      | size            | 1     |
      | bad_checkout_id | 1     |
    When job "A" holds a resource for 100 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "ok 2"
    And the jobs ended in this order: "A,B"
    And the count "made" is 2
    And the count "terminated" reaches 1 within 2000 ms

  # `checkout` runs in the task of the body (the caller's with lease_ms 0), so a check costs no task of its own.
  Scenario Outline: The checkout runs in the task of the body (lease_ms <lease>)
    Given a pool with:
      | setting  | value   |
      | size     | 1       |
      | lease_ms | <lease> |
    When job "A" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" succeeds
    And the checkout and the body ran in one task

    Examples:
      | lease |
      | 30000 |
      | 0     |

  # A checkout that crashes or hangs (for HOOK_MS, 5 s) does not reach the caller, and the resource is not lost: it is
  # ended, and the caller gets the next one. The wait for a hang counts in checkout_ms.
  Scenario Outline: A checkout that <bad> ends its resource, and the caller gets the next one (lease_ms above 0)
    Given a pool with:
      | setting         | value  |
      | size            | 1      |
      | checkout_ms     | 20000  |
      | bad_checkout_id | 1      |
      | checkout_fault  | <bad>  |
    When job "A" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "ok 2"
    And the count "made" is 2
    And the count "terminated" reaches 1 within 2000 ms

    Examples:
      | bad     |
      | crashes |
      | hangs   |

  # The resource comes back about when the deadline of B falls: B gets it or a timeout, and either way it is not lost.
  Scenario Outline: A caller whose deadline falls as a resource comes back gets it or a timeout (<hold> ms)
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | checkout_ms | 120   |
    When job "A" holds a resource for <hold> ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" succeeds or fails with a pool timeout
    And job "C" gets "ok 1"
    And the count "made" is 1
    And the count "double_lease" is 0

    Examples:
      | hold |
      | 150  |
      | 160  |
      | 170  |

  # The first tick that finds the resource idle for health_ms is the one at about 200 ms; B comes during its ping.
  Scenario: A caller that comes while the only resource is pinged waits, and gets a new one when the ping ends it
    Given a pool with:
      | setting      | value |
      | size         | 1     |
      | health_ms    | 100   |
      | slow_ping_ms | 400   |
      | bad_ping_id  | 1     |
    When I wait 250 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "ok 2"
    And the count "double_lease" is 0

  Scenario Outline: 1000 callers taking a resource 20 times share 4, one body at a time each (lease_ms <lease>)
    Given a pool with:
      | setting     | value   |
      | size        | 4       |
      | lease_ms    | <lease> |
      | checkout_ms | 60000   |
    When 1000 callers each take a resource 20 times
    And I wait for the jobs
    Then the count "body_ran" is 20000
    And the count "flood_failed" is 0
    And the count "double_lease" is 0
    And the count "peak" is 4
    And the count "made" is 4

    Examples:
      | lease |
      | 0     |
      | 30000 |

  Scenario: A checkout inside a body on a full pool times out on its own wait, and the outer body finishes
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | checkout_ms | 200   |
    When job "A" checks out again inside its body
    And I wait for the jobs
    Then job "A" gets "ok -1"
    And the count "made" is 1

  # Job "A" still runs after the drain, in its caller: its resource is ended under it, and its checkin after the close
  # changes nothing.
  Scenario: A close ends the resource of a body that runs in its caller (lease_ms 0) and lets the body finish
    Given a pool with:
      | setting  | value |
      | size     | 1     |
      | lease_ms | 0     |
    When job "A" holds a resource for 600 ms
    And job "B" holds a resource for 10 ms
    And I close the pool, giving the jobs 0 ms to finish
    Then the count "terminated" is 1
    When I wait for the jobs
    Then job "A" succeeds
    And job "B" gets "error pool error: closed"
    And the count "made" is 1
    And the count "terminated" is 1

  # A's body ends at once and its checkin takes 300 ms; the cancel comes during that checkin (lease_ms 0) or after the
  # caller got its result (above 0). The checkin that was cut off is not run again, and its resource is ended.
  Scenario Outline: A caller cancelled after its body has checkin run once (lease_ms <lease>)
    Given a pool with:
      | setting         | value   |
      | size            | 1       |
      | lease_ms        | <lease> |
      | slow_checkin_ms | 300     |
    When job "A" holds a resource for 1 ms
    And the caller of job "A" is cancelled
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "ok <b>"
    And the count "checkin_done" reaches 2 within 2000 ms
    And the count "checkin_timed_out" is 0
    And the count "checkin_crashed" is 0

    Examples:
      | lease | b |
      | 0     | 2 |
      | 30000 | 1 |

  # A is cancelled during its 300 ms checkout, before its body starts: no checkin runs, and the resource is ended.
  Scenario: A caller cancelled before its body starts has no checkin, and its resource is replaced
    Given a pool with:
      | setting          | value |
      | size             | 1     |
      | slow_checkout_ms | 300   |
    When job "A" holds a resource for 10 ms
    And the caller of job "A" is cancelled
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "ok 2"
    And the count "body_ran" is 1
    And the count "checkin_timed_out" is 0
    And the count "terminated" reaches 1 within 2000 ms

  # The checkin of a body that ran in a task of the pool runs in a task of its own, after the caller has its result, and
  # for at most 5 seconds: one that crashes or hangs ends its resource, never the caller.
  Scenario Outline: A checkin that <bad> does not reach the caller, and its resource is replaced (lease_ms above 0)
    Given a pool with:
      | setting     | value |
      | size        | 1     |
      | bad_checkin | <bad> |
      | checkout_ms | 8000  |
    When job "A" holds a resource for 10 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "ok 1"
    And job "B" gets "ok 2"
    And the jobs ended in this order: "A,B"
    And the count "terminated" reaches 1 within 2000 ms

    Examples:
      | bad     |
      | crashes |
      | hangs   |

  # A's resource 1 is refused after 100 ms of checkout; meanwhile B fills the line (max_waiting 1) and C is refused. A
  # keeps its place at the front for resource 2, which takes 200 ms to make, and B gets it after A.
  Scenario: A caller whose resource checkout refuses keeps its place even when the line is full
    Given a pool with:
      | setting          | value |
      | size             | 1     |
      | max_waiting      | 1     |
      | bad_checkout_id  | 1     |
      | slow_checkout_ms | 100   |
      | slow_init_at     | 2     |
      | slow_init_ms     | 200   |
    When job "A" holds a resource for 10 ms
    And job "B" holds a resource for 10 ms
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "ok 2"
    And job "B" gets "ok 2"
    And job "C" gets "error pool error: queue full (max_waiting 1)"
    And the jobs ended in this order: "C,A,B"
