Feature: The testing helper
  `Testing.capture` keeps the events that match, and `Testing.events` flushes and gives what came since the last read,
  so a test never sleeps. `Testing.session` does it all in one call that leaves no task running, which a BDD step needs.

  Scenario: A capture gives the events that match, in order, and nothing twice
    Given the hub is started
    When I capture "jobs" as "c"
    And I emit "jobs.a"
    And I emit "pool.x"
    And I emit "jobs.b"
    And I read the events of the capture "c"
    Then the reply is "ok jobs.a, jobs.b"
    When I emit "jobs.c"
    And I read the events of the capture "c"
    Then the reply is "ok jobs.c"
    When I read the events of the capture "c"
    Then the reply is "ok"

  Scenario: Two captures each get their own events
    Given the hub is started
    When I capture "jobs" as "a"
    And I capture "pool" as "b"
    And I emit "jobs.x"
    And I emit "pool.y"
    And I read the events of the capture "a"
    Then the reply is "ok jobs.x"
    When I read the events of the capture "b"
    Then the reply is "ok pool.y"

  Scenario: Stopping a capture detaches it, and later events are not kept
    Given the hub is started
    When I capture "jobs" as "c"
    And I emit "jobs.a"
    And I read the events of the capture "c"
    And I stop the capture "c"
    And I ask for the handlers
    Then the reply is "ok"
    When I emit "jobs.b"
    And I read the events of the capture "c"
    Then the reply is "ok"

  Scenario: Stopping a capture twice fails
    Given the hub is started
    When I capture "jobs" as "c"
    And I stop the capture "c"
    And I stop the capture "c"
    Then the reply is "error telemetry.unknown"

  Scenario: Events that do not fit are an error, not a silent loss
    Given the hub is started
    When I capture "jobs" as "c" with room for 2 events
    And I emit 10 events "jobs.n"
    And I read the events of the capture "c"
    Then the reply is "error telemetry.lost"

  Scenario: A capture needs a hub
    When I capture "jobs" as "c"
    Then the reply is "error telemetry.not_started"

  Scenario: 16 tasks emit 50 events each into a capture, and all arrive, each task's in order
    Given the hub is started
    When 16 tasks emit 50 events each, into a capture
    Then the reply is "ok"

  Scenario: A session in a step starts the hub, captures, and leaves no task running
    When a session in this step captures "jobs" and emits "jobs.a"
    Then the reply is "ok jobs.a"

  Scenario: A session in the driver uses the hub that runs, and leaves it running with no handler of its own
    Given the hub is started
    When the driver runs a session that captures "jobs" and emits "jobs.a"
    Then the reply is "ok jobs.a"
    When I attach "h" to "jobs"
    Then the reply is "ok"
