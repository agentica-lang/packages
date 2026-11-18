Feature: Attaching and detaching handlers
  The hub starts first, in main. A handler has an id that names it until it is detached.

  Scenario: Attach fails before the hub is started
    When I attach "h" to "jobs"
    Then the reply is "error telemetry.not_started"

  Scenario: Detach fails before the hub is started
    When I detach "h"
    Then the reply is "error telemetry.not_started"

  Scenario: Starting twice fails
    Given the hub is started
    When the hub is started
    Then the reply is "error telemetry.started"

  Scenario: The handlers are listed by id
    Given the hub is started
    When I attach "b" to "jobs"
    And I attach "a" to "pool"
    And I ask for the handlers
    Then the reply is "ok a,b"

  Scenario: An id in use is refused and its handler keeps working
    Given the hub is started
    When I attach "h" to "jobs"
    And I attach "h" to "pool"
    Then the reply is "error telemetry.duplicate"
    When I emit "jobs.job.stop"
    And I emit "pool.checkout"
    And I flush
    Then the handler "h" got the events "jobs.job.stop"

  Scenario: A detached handler hears no more events, and its id is free again
    Given the hub is started
    When I attach "h" to "jobs"
    And I emit "jobs.a"
    And I flush
    And I detach "h"
    And I emit "jobs.b"
    And I ask for the handlers
    Then the reply is "ok"
    When I attach "h" to "jobs"
    And I emit "jobs.c"
    And I flush
    Then the handler "h" got the events "jobs.a, jobs.c"

  Scenario: Detaching an unknown id fails
    Given the hub is started
    When I detach "nobody"
    Then the reply is "error telemetry.unknown"

  Scenario: A queue of less than one event is refused
    Given the hub is started
    When I attach "h" to "jobs" with a queue of -1
    Then the reply is "error argument"

  Scenario: Stopping detaches every handler, after they handled what was queued
    Given the hub is started
    When I attach "h" to "jobs"
    And I emit "jobs.a"
    And I emit "jobs.b"
    And I stop the hub
    Then the reply is "ok"
    When I ask for the handlers
    Then the reply is "ok"
    And the handler "h" got the events "jobs.a, jobs.b"

  Scenario: Stopping leaves no task of the package running
    Given the hub is started
    When I attach "a" to "jobs"
    And I attach "b" to "pool"
    And I stop the hub
    And I wait for the tasks of the hub to end
    Then the reply is "ok"

  Scenario: Stopping a hub that is not running fails, and the hub can start again after a stop
    Given the hub is started
    When I stop the hub
    And I stop the hub
    Then the reply is "error telemetry.not_started"
    When the hub is started
    And I attach "h" to "jobs"
    Then the reply is "ok"
