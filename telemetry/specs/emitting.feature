Feature: Emitting events
  An event has a dotted name. A handler is attached to patterns, and hears the events whose name is a pattern or starts
  with it at a dot. Delivery is async: the steps flush before they read what a handler got.

  Scenario: A handler hears the exact name it was attached to
    Given the hub is started
    When I attach "h" to "jobs.job.stop"
    And I emit "jobs.job.stop"
    And I emit "jobs.job.start"
    And I flush
    Then the handler "h" got the events "jobs.job.stop"

  Scenario: A prefix hears the names below it, at a dot
    Given the hub is started
    When I attach "h" to "jobs"
    And I emit "jobs"
    And I emit "jobs.job.stop"
    And I emit "jobs_extra.stop"
    And I emit "job"
    And I emit "pool.checkout"
    And I flush
    Then the handler "h" got the events "jobs, jobs.job.stop"

  Scenario: A pattern is a whole word, not the start of one
    Given the hub is started
    When I attach "h" to "jobs.jo"
    And I emit "jobs.job"
    And I flush
    Then the handler "h" got the events ""

  Scenario: The star hears everything
    Given the hub is started
    When I attach "h" to "*"
    And I emit "a"
    And I emit "b.c.d"
    And I flush
    Then the handler "h" got the events "a, b.c.d"

  Scenario: A handler with several patterns hears an event once, however many patterns match
    Given the hub is started
    When I attach "h" to "jobs,jobs.job,jobs.job.stop,*"
    And I emit "jobs.job.stop"
    And I flush
    Then the handler "h" got the events "jobs.job.stop"

  Scenario: Every handler that matches gets the event
    Given the hub is started
    When I attach "a" to "jobs"
    And I attach "b" to "jobs.job"
    And I attach "c" to "pool"
    And I emit "jobs.job.stop"
    And I flush
    Then the handler "a" got the events "jobs.job.stop"
    And the handler "b" got the events "jobs.job.stop"
    And the handler "c" got the events ""

  Scenario: The measurements and the metadata arrive as they were sent
    Given the hub is started
    When I attach "h" to "pool"
    And I emit "pool.checkout.stop" with:
      | kind  | key         | value  |
      | int   | duration_ns | 1200   |
      | int   | waiting     | 3      |
      | float | ratio       | 0.25   |
      | meta  | pool        | main   |
    And I flush
    Then the handler "h" got:
      """
      pool.checkout.stop {"duration_ns": 1200, "waiting": 3} {"ratio": 0.25} {"pool": "main"}
      """

  Scenario: Events of one emitter reach a handler in the order they were emitted
    Given the hub is started
    When I attach "h" to "tick"
    And I emit "tick.a"
    And I emit "tick.b"
    And I emit "tick.c"
    And I flush
    Then the handler "h" got the events "tick.a, tick.b, tick.c"

  Scenario: With no handler an event does nothing, and nothing is enabled
    Given the hub is started
    When I emit "jobs.job.stop"
    And I ask whether "jobs.job.stop" is enabled
    Then the reply is "ok false"

  Scenario: Enabled follows the patterns that are attached
    Given the hub is started
    When I attach "h" to "jobs.job"
    And I ask whether "jobs.job.stop" is enabled
    Then the reply is "ok true"
    When I ask whether "jobs.enqueue" is enabled
    Then the reply is "ok false"

  Scenario: Events with no hub started are ignored
    When I emit "jobs.job.stop"
    And I flush
    Then the reply is "ok"

  Scenario Outline: A handler is refused for a name that is not a dotted name of lowercase words
    Given the hub is started
    When I attach "h" to "<pattern>"
    Then the reply is "error argument"

    Examples:
      | pattern     |
      | Jobs        |
      | jobs..stop  |
      | .jobs       |
      | jobs.       |
      | 9jobs       |
      | jobs-queue  |
      | a.b.c.d.e   |
      | **          |
