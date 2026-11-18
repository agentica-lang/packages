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

  Scenario: Once detach has returned no route to the handler is left
    Given the hub is started
    When 50 handlers are attached and detached one after the other
    Then the reply is "ok"

  Scenario: A claim that a cancelled start left behind does not stop the next start
    Given a start that was cancelled left its claim behind
    When the hub is started
    Then the reply is "ok"
    When I attach "h" to "jobs"
    Then the reply is "ok"

  Scenario: A hub that is too busy to answer is alive: start says so, and keeps it
    Given a hub that does not answer is registered and the hub is started
    Then the reply is "ok"

  Scenario: The end of an old hub does not clear a newer hub
    Given the end of an old hub is reported while a newer one is registered
    Then the reply is "ok"

  Scenario: A claim that ran out and was taken over is not deleted by its first holder
    Given claims are taken, run out and are given back
    Then the reply is "ok"

  Scenario: The end of a hub is not reported to the tables while a start holds the claim
    Given the end of a hub is reported while a start holds the claim
    Then the reply is "ok"

  Scenario: Flush keeps to its time when the hub and a handler do not answer
    Given a flush of 300 ms meets a hub and a handler that do not answer
    Then the reply is "ok"

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

  Scenario: A queue above the limit is refused, and the hub goes on
    Given the hub is started
    When I attach "h" to "jobs" with a queue of 1048577
    Then the reply is "error argument"
    When I attach "h" to "jobs" with a queue of 1000
    Then the reply is "ok"
    When I emit "jobs.a"
    And I flush
    Then the handler "h" got the events "jobs.a"

  Scenario: Stopping waits for a slow handler to handle everything that was queued
    Given the hub is started
    When I attach "h" to "tick" and it is slow
    And I emit 10 events "tick.n"
    And I stop the hub
    Then the reply is "ok"
    And the handler "h" got between 10 and 10 events

  Scenario: What a handler that was cancelled tells the hub late does not touch the handler that replaced it
    Given the hub is started
    When I attach "h" to "churn" 100 times, cancel it at once each time, and attach it again
    And I emit "churn.go"
    And I flush
    Then the handler "h" got the events "churn.go"
    And the Logger got nothing

  Scenario: The count of dropped events stays after the handler is detached, until the id is attached again
    Given the hub is started
    When I attach "slow" to "tick" and it blocks, with a queue of 2
    And I emit 10 events "tick.n"
    And I detach "slow"
    Then the handler "slow" dropped between 7 and 8 events
    When I attach "slow" to "tick"
    Then the handler "slow" dropped between 0 and 0 events

  Scenario: A handler that calls flush is told that it would wait for itself
    Given the hub is started
    When I attach "h" to "jobs" and it flushes
    And I emit "jobs.a"
    And I flush
    Then the handler "h" got:
      """
      error telemetry.in_handler
      """

  Scenario: A hub that ended with the task that started it leaves no routes behind
    Given the hub is started by a task of its own
    When I attach "h" to "jobs"
    And that task is cancelled
    And I wait for the tasks of the hub to end
    And I flush
    Then the reply is "ok"
    When I ask for the handlers
    Then the reply is "ok"
    When I ask whether "jobs.a" is enabled
    Then the reply is "ok false"
    When I measure the steps of emitting "jobs.a"
    Then the reply is a number up to 25

  Scenario: Attach, detach and stop on a hub that ended give not_started and clear its routes
    Given the hub is started by a task of its own
    When I attach "h" to "jobs"
    And that task is cancelled
    And I wait for the tasks of the hub to end
    And I attach "other" to "pool"
    Then the reply is "error telemetry.not_started"
    When I ask for the handlers
    Then the reply is "ok"

  Scenario: Stop on a hub that ended gives not_started and clears its routes
    Given the hub is started by a task of its own
    When I attach "h" to "jobs"
    And that task is cancelled
    And I wait for the tasks of the hub to end
    And I stop the hub
    Then the reply is "error telemetry.not_started"
    When I ask for the handlers
    Then the reply is "ok"

  Scenario: A hub that ended with its starter is replaced by the next start
    Given the hub is started by a task of its own
    When I attach "h" to "jobs"
    And that task is cancelled
    And I wait for the tasks of the hub to end
    And the hub is started
    Then the reply is "ok"
    When I attach "h" to "jobs"
    And I emit "jobs.a"
    And I flush
    Then the handler "h" got the events "jobs.a"

  Scenario: A failure that an older handler of the same id reported does not detach the handler that replaced it
    Given the hub is started
    When I attach "h" to "jobs"
    And the hub is told that an older handler "h" failed
    And I flush
    And I emit "jobs.a"
    And I flush
    Then the handler "h" got the events "jobs.a"
    And the Logger got nothing

  Scenario: A handler whose task returned without telling the hub is detached, with the kind ended
    Given the hub is started
    When I attach "h" to "jobs" and it tells its task
    And I emit "jobs.a"
    And I flush
    And the hub is told that the task of "h" returned
    And I flush
    And I ask for the handlers
    Then the reply is "ok"
    And the Logger got:
      """
      telemetry handler detached {"id": "h", "kind": "ended"}
      """
