Feature: The memory backend
  The memory backend keeps its jobs in one actor: its limits, its clock and the fetches that wait are its own rules. The
  clock is manual unless a scenario says it is the wall clock: a step moves it, and no step sleeps.

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

  Scenario: A batch that does not fit adds none of its jobs
    Given a memory backend on a manual clock with:
      | setting  | value |
      | max_jobs | 3     |
    When I enqueue "a" into "q"
    And I enqueue the jobs "b,c,d" into "q" in one batch
    Then the reply is "error jobs.full"
    When I ask for the counts of "q"
    Then the reply is "ready 1 scheduled 0 leased 0 dead 0"
    When I enqueue the jobs "b,c" into "q" in one batch
    Then the reply is "ok 2,3"

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

  Scenario: Fetches that wait are served oldest first, and the one behind a served fetch is served next
    Given a memory backend on a manual clock
    When a fetch of "q" starts to wait as "first"
    And a fetch of "q" starts to wait as "second"
    And I enqueue "one" into "q"
    And the fetch "first" ends
    Then the reply is "ok one attempt 1"
    When I enqueue "two" into "q"
    And the fetch "second" ends
    Then the reply is "ok two attempt 1"

  Scenario: Fetches that wait end in the order of their deadlines, each at its own time
    Given a memory backend on a manual clock
    When a fetch of "q" starts to wait as "late" for 300000 ms
    And a fetch of "q" starts to wait as "soon" for 100000 ms
    And a fetch of "q" starts to wait as "middle" for 200000 ms
    And the clock moves 100000 ms
    And the fetch "soon" ends
    Then the reply is "ok none"
    When I enqueue "x" into "q"
    And the fetch "late" ends
    Then the reply is "ok x attempt 1"
    When I ack "late"
    And the clock moves 100000 ms
    And the fetch "middle" ends
    Then the reply is "ok none"

  Scenario: A fetch that waits ends at its wait_ms of real time, on a clock that nobody moves
    Given a memory backend on a manual clock
    When a fetch of "q" starts to wait as "w" for 300 ms
    And the fetch "w" ends
    Then the reply is "ok none"

  Scenario: A fetch that waits on the wall clock gets a job that comes before its time
    Given a memory backend on the wall clock
    When a fetch of "q" starts to wait as "w" for 5000 ms
    And I enqueue "in time" into "q"
    And the fetch "w" ends
    Then the reply is "ok in time attempt 1"

  Scenario: A job that a caller that gave up would have got stays in the queue, and its attempt is not counted
    Given a memory backend on a manual clock with:
      | setting          | value |
      | fetch_timeout_ms | 200   |
    When a fetch of "q" starts to wait as "w"
    And the fetch "w" ends
    Then the reply is "error jobs.timeout"
    When I enqueue "x" into "q"
    And I ask for the counts of "q"
    Then the reply is "ready 1 scheduled 0 leased 0 dead 0"
    When I fetch a job of "q" as "a"
    Then the reply is "ok x attempt 1"

  Scenario: A retry gives its error to the next delivery
    Given a memory backend on a manual clock
    When I enqueue "a" into "q"
    And I fetch a job of "q" as "a"
    And I retry "a" in 0 ms, with the error "boom"
    And I fetch a job of "q" as "b"
    Then the reply is "ok a attempt 2 last_error boom"

  Scenario: A fetch can take several jobs, and each has its own lease
    Given a memory backend on a manual clock
    When I enqueue the jobs "a,b,c" into "q" in one batch
    And I fetch 2 jobs of "q" as "x"
    Then the reply is "ok a attempt 1, b attempt 1"
    When I ack "x/2"
    And I ask for the counts of "q"
    Then the reply is "ready 1 scheduled 0 leased 1 dead 0"

  Scenario Outline: A memory backend with an option that cannot work is refused
    Given a memory backend on a manual clock with:
      | setting   | value   |
      | <setting> | <value> |
    Then the reply is "error argument"

    Examples:
      | setting  | value |
      | max_jobs | 0     |
      | max_dead | -1    |

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
      | 6    |
      | 7    |
      | 8    |
      | 9    |
      | 10   |
      | 11   |
      | 12   |
      | 13   |
      | 14   |
      | 15   |
      | 16   |
      | 17   |
      | 18   |
      | 19   |
      | 20   |
