Feature: The memory backend
  The memory backend keeps its jobs in one actor, so its limits and its clock are its own rules. The contract that every
  backend shares is in conformance.feature. The clock is manual: a step moves it, and no step sleeps.

  Scenario: A job is delivered, acked and gone
    Given a memory backend on a manual clock
    When I enqueue "hello" into "mail"
    And I fetch a job of "mail" as "a"
    Then the reply is "ok hello attempt 1"
    When I ack "a"
    And I ask for the counts of "mail"
    Then the reply is "ready 0 scheduled 0 leased 0 dead 0"

  Scenario: An enqueue past max_jobs fails, and a duplicate does not count
    Given a memory backend on a manual clock with:
      | setting  | value |
      | max_jobs | 2     |
    When I enqueue "a" into "q" with:
      | setting    | value |
      | unique_key | k     |
    And I enqueue "b" into "q"
    And I enqueue "c" into "q"
    Then the reply is "error jobs.full"
    When I enqueue "a" into "q" with:
      | setting    | value |
      | unique_key | k     |
    Then the reply is "ok 1 duplicate"

  Scenario: A finished job frees its place
    Given a memory backend on a manual clock with:
      | setting  | value |
      | max_jobs | 1     |
    When I enqueue "a" into "q"
    And I fetch a job of "q" as "a"
    And I ack "a"
    And I enqueue "b" into "q"
    Then the reply is "ok 2"

  Scenario: Only max_dead dead jobs are kept, and the oldest goes first
    Given a memory backend on a manual clock with:
      | setting  | value |
      | max_dead | 2     |
    When I enqueue "a" into "q"
    And I enqueue "b" into "q"
    And I enqueue "c" into "q"
    And I fetch a job of "q" as "a"
    And I kill "a"
    And I fetch a job of "q" as "b"
    And I kill "b"
    And I fetch a job of "q" as "c"
    And I kill "c"
    And I ask for the counts of "q"
    Then the reply is "ready 0 scheduled 0 leased 0 dead 2"

  Scenario: A job of an invalid value is refused
    Given a memory backend on a manual clock
    When I enqueue "a" into "q" with:
      | setting      | value |
      | max_attempts | 0     |
    Then the reply is "error argument"

  Scenario: A job that waits for its time is ready when the clock reaches it
    Given a memory backend on a manual clock
    When I enqueue "later" into "q" with:
      | setting   | value |
      | run_in_ms | 60000 |
    And I ask for the counts of "q"
    Then the reply is "ready 0 scheduled 1 leased 0 dead 0"
    When the clock moves 60000 ms
    And I ask for the counts of "q"
    Then the reply is "ready 1 scheduled 0 leased 0 dead 0"

  Scenario: A fetch that waits is served when its time comes
    Given a memory backend on a manual clock
    When I enqueue "later" into "q" with:
      | setting   | value |
      | run_in_ms | 60000 |
    And a fetch of "q" starts to wait as "w"
    And the clock moves 60000 ms at a time until the fetch "w" ends
    Then the reply is "ok later attempt 1"

  Scenario: A fetch that waits ends with no jobs when its time is up
    Given a memory backend on a manual clock
    When a fetch of "q" starts to wait as "w"
    And the clock moves 3600000 ms at a time until the fetch "w" ends
    Then the reply is "ok none"

  Scenario: The wall clock runs the jobs that are due now
    Given a memory backend on the wall clock
    When I enqueue "now" into "q"
    And I fetch a job of "q" as "a"
    Then the reply is "ok now attempt 1"

  Scenario: Close refuses the calls and ends a fetch that waits
    Given a memory backend on a manual clock
    When a fetch of "q" starts to wait as "w"
    And I close the backend
    And the clock moves 1 ms at a time until the fetch "w" ends
    Then the reply is "error jobs.closed"
    When I enqueue "a" into "q"
    Then the reply is "error jobs.closed"

  Scenario Outline: The memory backend answers like an independent model, on random calls
    Given a memory backend on a manual clock
    Then the memory backend answers like the model on 300 random calls from seed <seed>

    Examples:
      | seed |
      | 1    |
      | 2    |
      | 3    |
      | 4    |
      | 5    |
