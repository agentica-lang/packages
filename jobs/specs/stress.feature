Feature: Many consumers on one queue
  Producers add jobs while consumers fetch from the same queue, and some consumers drop a job without an ack, as a
  consumer that died would. The clock moves past the leases of the dropped jobs between rounds. No job is lost, none
  runs twice at the same time, and every job is acked in the end. This is the race that a queue of shared counters
  lost jobs in (agentica-campfire#187).

  Scenario: 16 consumers work off 400 jobs and none is lost or run twice at once
    Given a memory backend on a manual clock
    When 16 consumers work off 400 jobs of one queue while producers add them
    Then the reply is "ok"

  Scenario: A single consumer works off the same jobs
    Given a memory backend on a manual clock
    When 1 consumers work off 400 jobs of one queue while producers add them
    Then the reply is "ok"
