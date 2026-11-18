Feature: Handlers that fail
  A handler never hurts the code that emits, or the other handlers. One that returns an error or crashes is detached
  at once, with one warning that names the id and the kind, and never the event. A handler whose queue is full loses
  the newest events, which are counted.

  Scenario: A handler that returns an error is detached and the others are not affected
    Given the hub is started
    When I attach "bad" to "jobs" and it fails
    And I attach "good" to "jobs"
    And I emit "jobs.a" with:
      | kind | key    | value   |
      | meta | secret | hunter2 |
    And I flush
    And I emit "jobs.b"
    And I flush
    And I ask for the handlers
    Then the reply is "ok good"
    And the handler "good" got the events "jobs.a, jobs.b"

  Scenario: The warning has the id and the kind, and nothing of the event or the message
    Given the hub is started
    When I attach "bad" to "jobs" and it fails
    And I emit "jobs.a" with:
      | kind | key    | value   |
      | meta | secret | hunter2 |
    And I flush
    And I emit "jobs.b"
    And I flush
    Then the Logger got:
      """
      telemetry handler detached {"id": "bad", "kind": "handler.bad"}
      """
    And no warning includes "hunter2"

  Scenario: A handler that crashes is detached, the others are not affected and the program does not fail
    Given the hub is started
    When I attach "bad" to "jobs" and it crashes
    And I attach "good" to "jobs"
    And I emit "jobs.a"
    And I flush
    And I emit "jobs.b"
    And I flush
    And I ask for the handlers
    Then the reply is "ok good"
    And the handler "good" got the events "jobs.a, jobs.b"
    And the Logger got:
      """
      telemetry handler detached {"id": "bad", "kind": "RUNTIME-INDEX-OUT-OF-RANGE"}
      """
    When I close stdin
    Then the program exits with code 0 within 5000 milliseconds

  Scenario: The id of a detached handler can be used again
    Given the hub is started
    When I attach "h" to "jobs" and it fails
    And I emit "jobs.a"
    And I flush
    And I attach "h" to "jobs"
    And I emit "jobs.b"
    And I flush
    Then the reply is "ok"
    And the handler "h" got the events "jobs.b"

  Scenario: A handler that is blocked drops the newest events, and emitting never waits
    Given the hub is started
    When I attach "slow" to "tick" and it blocks, with a queue of 2
    And I attach "fast" to "tick"
    And I emit 100 events "tick.n"
    Then the handler "slow" dropped between 97 and 98 events
    When I release "slow"
    And I flush
    Then the handler "slow" got and dropped 100 events in all
    And the handler "fast" got and dropped 100 events in all

  Scenario: The events of a blocked handler that were queued are handled when it goes on
    Given the hub is started
    When I attach "slow" to "tick" and it blocks, with a queue of 2
    And I emit 50 events "tick.n"
    And I release "slow"
    And I flush
    Then the handler "slow" got and dropped 50 events in all
    And the handler "slow" got between 2 and 3 events

  Scenario: The count of dropped events is zero for an id that is not attached
    Given the hub is started
    Then the handler "nobody" dropped between 0 and 0 events

  Scenario: A handler that failed on an earlier event is detached by the time flush returns
    Given the hub is started
    When 50 handlers fail one after the other, each on its first event
    Then the reply is "ok"
