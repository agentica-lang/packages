Feature: Outcomes
  The body of a job runs in a task of the pool and checkin gets its outcome: Done, Crashed or TimedOut. The fake
  checkin keeps the cell after Done and ends it after the other two, unless the pool says keep_dirty. A cell that is
  ended is replaced by a new one, so the pool keeps its size.

  Scenario Outline: A body that crashes gives an error and checkin decides on the cell (keep_dirty <keep_dirty>)
    Given a pool with:
      | setting    | value        |
      | size       | 1            |
      | keep_dirty | <keep_dirty> |
    When job "A" crashes
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error task crashed"
    And job "B" succeeds
    And the count "checkin_crashed" is 1
    And the count "made" is <made>
    And the count "terminated" reaches <terminated> within 2000 ms

    Examples:
      | keep_dirty | made | terminated |
      | false      | 2    | 1          |
      | true       | 1    | 0          |

  Scenario: A body that returns an error is a normal outcome
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" returns an error
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error the body failed"
    And job "B" succeeds
    And the count "checkin_done" is 2
    And the count "made" is 1

  Scenario: A body that runs longer than lease_ms is cancelled and its cell is replaced even if checkin keeps it
    Given a pool with:
      | setting    | value |
      | size       | 1     |
      | lease_ms   | 150   |
      | keep_dirty | true  |
    When job "A" never returns
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" gets "error pool error: lease timed out after 150 ms"
    And job "A" fails with a pool timeout
    And job "B" succeeds
    And the count "checkin_timed_out" is 1
    And the count "made" is 2
    And the count "terminated" reaches 1 within 2000 ms

  Scenario: A pool whose init fails does not start and ends the resources it made
    Then starting a pool with these settings fails with "init failed for resource 2":
      | setting         | value |
      | size            | 2     |
      | init_fails_from | 2     |
    And the count "terminated" reaches 1 within 2000 ms

  Scenario Outline: A setting out of range is refused (<setting>)
    Then starting a pool with these settings fails with "<error>":
      | setting   | value   |
      | <setting> | <value> |

    Examples:
      | setting      | value   | error                                                   |
      | size         | 0       | pool error: size must be at least 1                     |
      | checkout_ms  | 0       | pool error: checkout_ms must be at least 1, and lease_ms 0 or more |
      | lease_ms     | -1      | pool error: checkout_ms must be at least 1, and lease_ms 0 or more |
      | max_overflow | -1      | pool error: max_overflow, overflow_idle_ms              |
      | max_age_ms   | 100     | pool error: max_age_ms and idle_ms need health_ms       |
      | idle_ms      | 100     | pool error: max_age_ms and idle_ms need health_ms       |
      | size         | 1048577 | pool error: size + max_overflow cannot be more than     |

  Scenario: A pool that could not make a resource says so to the callers that wait, and asks init only now and then
    Given a pool with:
      | setting         | value |
      | size            | 1     |
      | checkout_ms     | 300   |
      | init_fails_from | 2     |
    When job "A" crashes
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "error pool error: checkout timed out after 300 ms (the last init failed: init failed"
    And job "B" fails with a pool timeout
    And the count "made" is 2

  Scenario: An init that crashes counts as a failed init, and the pool makes the resource on a later try
    Given a pool with:
      | setting         | value |
      | size            | 1     |
      | lease_ms        | 200   |
      | init_crashes_at | 2     |
    When job "A" never returns
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "ok 3"
    And job "A" gets "error pool error: lease timed out"
    When job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "C" gets "ok 3"

  Scenario: An idle_ms on a pool that is not lazy is refused
    Then starting a pool with these settings fails with "pool error: idle_ms needs a lazy pool":
      | setting   | value |
      | idle_ms   | 100   |
      | health_ms | 50    |

  Scenario: A caller gets its checkout timeout on time while the owner is busy in a slow init
    Given a pool with:
      | setting      | value |
      | size         | 2     |
      | lazy         | true  |
      | checkout_ms  | 200   |
      | lease_ms     | 5000  |
      | slow_init_at | 2     |
      | slow_init_ms | 1500  |
    When job "A" holds a resource for 1800 ms
    And job "B" holds a resource for 10 ms
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" fails with a pool timeout
    And job "C" fails with a pool timeout
    And job "A" succeeds
    And the count "body_ran" is 1

  Scenario: A resource that checkin refuses after a clean body is ended and replaced
    Given a pool with:
      | setting    | value |
      | size       | 1     |
      | dirty_done | true  |
    When job "A" holds a resource for 10 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" succeeds
    And job "B" succeeds
    And the count "double_lease" is 0
    And the count "made" reaches 3 within 2000 ms
    And the count "terminated" reaches 2 within 2000 ms

  # The owner task ends with the task that started the pool. B, in line for 3 seconds, hears of it at once.
  Scenario: A pool whose owner task ended fails the callers that wait and the ones that come after
    Given a pool started in a task of its own, with:
      | setting     | value |
      | size        | 1     |
      | checkout_ms | 3000  |
    When job "A" holds a resource for 1000 ms
    And job "B" holds a resource for 10 ms
    And the task that started the pool ends
    And I wait for the jobs
    Then job "B" gets "error pool error: owner task ended"
    And job "B" fails with the kind "pool.closed"
    And the jobs ended in this order: "B,A"
    When job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then job "C" gets "error pool error: owner task ended"
