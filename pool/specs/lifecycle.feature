Feature: Lifecycle
  A pool makes its resources at the start (or when needed, when lazy), checks the idle ones on a health tick
  (ping, max_age_ms, idle_ms) and ends them all when it is closed.

  Scenario: A lazy pool makes a resource only when a caller needs one
    Given a pool with:
      | setting | value |
      | size    | 3     |
      | lazy    | true  |
    Then the count "made" is 0
    When job "A" holds a resource for 200 ms
    And job "B" holds a resource for 200 ms
    And I wait for the jobs
    And job "C" holds a resource for 10 ms
    And I wait for the jobs
    Then the count "made" is 2
    And job "C" succeeds

  Scenario: The health tick replaces an idle resource that does not answer a ping
    Given a pool with:
      | setting     | value |
      | size        | 2     |
      | health_ms   | 100   |
      | bad_ping_id | 1     |
    Then the count "terminated" reaches 1 within 3000 ms
    And the count "made" reaches 3 within 3000 ms

  Scenario: The health tick replaces a resource older than max_age_ms
    Given a pool with:
      | setting    | value |
      | size       | 1     |
      | health_ms  | 50    |
      | max_age_ms | 150   |
    Then the count "terminated" reaches 1 within 3000 ms
    And the count "made" reaches 2 within 3000 ms

  Scenario: The health tick ends a resource that was idle for idle_ms and a lazy pool does not replace it
    Given a pool with:
      | setting   | value |
      | size      | 2     |
      | lazy      | true  |
      | health_ms | 50    |
      | idle_ms   | 150   |
    When job "A" holds a resource for 10 ms
    And I wait for the jobs
    Then the count "terminated" reaches 1 within 3000 ms
    And the count "made" is 1

  Scenario: Closing lets the running job finish, ends every resource and refuses new jobs
    Given a pool with:
      | setting | value |
      | size    | 2     |
    When job "A" holds a resource for 300 ms
    And I close the pool, giving the jobs 3000 ms to finish
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "A" succeeds
    And job "B" gets "error pool error: closed"
    And the count "terminated" is 2

  Scenario: Closing fails the jobs that outlast the drain
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 5000 ms
    And I close the pool, giving the jobs 100 ms to finish
    And I wait for the jobs
    Then job "A" gets "error pool error: closed"
    And the count "terminated" is 1

  Scenario: Closing with no time to drain fails the running job and the ones in line
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 5000 ms
    And job "B" holds a resource for 10 ms
    And I close the pool, giving the jobs 0 ms to finish
    And I wait for the jobs
    Then job "A" gets "error pool error: closed"
    And job "B" gets "error pool error: closed"
    And the count "terminated" is 1

  # The overflow resource waits for its trim (5000 ms) when the close starts; the drain waits for job "C" and the trim
  # never runs, since closing ends every resource.
  Scenario: Closing with a trim pending lets the running job finish and ends every resource
    Given a pool with:
      | setting          | value |
      | size             | 1     |
      | max_overflow     | 1     |
      | overflow_idle_ms | 5000  |
    When job "A" holds a resource for 300 ms
    And job "B" holds a resource for 300 ms
    And I wait for the jobs
    And job "C" holds a resource for 400 ms
    And I close the pool, giving the jobs 3000 ms to finish
    And I wait for the jobs
    Then job "C" succeeds
    And the count "terminated" is 2

  Scenario: Closing with enough drain lets the callers in line finish
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 200 ms
    And job "B" holds a resource for 10 ms
    And I close the pool, giving the jobs 3000 ms to finish
    And I wait for the jobs
    Then job "A" succeeds
    And job "B" succeeds
    And the count "terminated" is 1

  Scenario: A body cut off by the close does not make the pool make or end a resource again
    Given a pool with:
      | setting | value |
      | size    | 1     |
    When job "A" holds a resource for 400 ms
    And I close the pool, giving the jobs 100 ms to finish
    And I wait for the jobs
    And I wait 800 ms
    Then job "A" gets "error pool error: closed"
    And the count "made" is 1
    And the count "terminated" is 1

  # The caller gives its resource back every 5 ms, so it is never idle for health_ms, and the tick pings only the two
  # resources that wait. No overflow resource is made for a ping.
  Scenario: The health tick pings only the resources idle for health_ms, so a busy caller never waits for one
    Given a pool with:
      | setting      | value |
      | size         | 3     |
      | max_overflow | 3     |
      | health_ms    | 100   |
      | slow_ping_ms | 300   |
    When job "A" keeps taking a resource for 1000 ms
    And I wait for the jobs
    Then the count "made" is 3
    And the count "terminated" is 0
    And the count "loop_failed" is 0

  Scenario: A resource that is ended is replaced only once its terminate is over
    Given a pool with:
      | setting           | value |
      | size              | 1     |
      | dirty_done        | true  |
      | slow_terminate_ms | 300   |
    When job "A" holds a resource for 10 ms
    And job "B" holds a resource for 10 ms
    And I wait for the jobs
    Then job "B" gets "ok 2"
    And the count "alive_peak" is 1

  # The ping takes 3 seconds, less than the 5 that a keeper gives it: the close waits for it, then ends the resource.
  Scenario: Closing during a slow ping still ends the resource
    Given a pool with:
      | setting      | value |
      | size         | 1     |
      | health_ms    | 100   |
      | slow_ping_ms | 3000  |
    Then the count "pings" reaches 1 within 1000 ms
    When I close the pool, giving the jobs 0 ms to finish
    Then the count "terminated" is 1

  Scenario: The pool counts the callers in line and the resources alive, and both are 0 once it is closed
    Given a pool with:
      | setting | value |
      | size    | 2     |
    When job "A" holds a resource for 400 ms
    And job "B" holds a resource for 400 ms
    And job "C" holds a resource for 10 ms
    And job "D" holds a resource for 10 ms
    Then the pool counts 2 "waiting" within 200 ms
    And the pool counts 2 "live" within 0 ms
    When I wait for the jobs
    Then the pool counts 0 "waiting" within 200 ms
    When I close the pool, giving the jobs 100 ms to finish
    Then the pool counts 0 "waiting" within 0 ms
    And the pool counts 0 "live" within 0 ms
