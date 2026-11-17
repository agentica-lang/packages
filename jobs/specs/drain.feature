Feature: Jobs.drain
  An app test enqueues jobs, drains the queue in the test itself, and checks what the handlers did. The handler of these
  scenarios acts on the payload: "ok" acks, "fail" returns an error, "discard" discards the job and "fail once" fails
  its first attempt only.

  Scenario: Every ready job runs once and is acked
    Given a memory backend on a manual clock
    When I enqueue "ok" into "q"
    And I enqueue "ok" into "q"
    And I drain "q"
    Then the reply is "done 2 retried 0 dead 0"

  Scenario: A job that fails is retried later, not at once
    Given a memory backend on a manual clock
    When I enqueue "fail" into "q"
    And I drain "q"
    Then the reply is "done 0 retried 1 dead 0"
    When I ask for the counts of "q"
    Then the reply is "ready 0 scheduled 1 leased 0 dead 0"

  Scenario: A discarded job is dead at once
    Given a memory backend on a manual clock
    When I enqueue "discard" into "q"
    And I drain "q"
    Then the reply is "done 0 retried 0 dead 1"

  Scenario: Draining the jobs that wait for a time runs the retries too
    Given a memory backend on a manual clock
    When I enqueue "fail once" into "q"
    And I enqueue "fail" into "q" with:
      | setting      | value |
      | max_attempts | 3     |
    And I drain "q", with the jobs that wait for a time
    Then the reply is "done 1 retried 3 dead 1"

  Scenario: A drain stops after max_runs jobs
    Given a memory backend on a manual clock
    When I enqueue "ok" into "q"
    And I enqueue "ok" into "q"
    And I drain "q", at most 1 jobs
    Then the reply is "done 1 retried 0 dead 0"
    When I ask for the counts of "q"
    Then the reply is "ready 1 scheduled 0 leased 0 dead 0"

  Scenario: Draining the jobs that wait for a time needs the clock that the backend follows
    Given a memory backend on a manual clock
    When I enqueue "ok" into "q"
    And I drain "q", with the jobs that wait for a time, and no clock
    Then the reply is "error argument"

  Scenario: A job that fails logs a warning with its queue, id and attempt, and not its payload
    Given a memory backend on a manual clock
    When I enqueue "fail" into "mail"
    And I drain "mail"
    And the drain logged
    Then the reply is "warning job failed, it will run again attempt=1 id=1 queue=mail"

  Scenario: A discarded job logs an error with the reason discarded
    Given a memory backend on a manual clock
    When I enqueue "discard" into "mail"
    And I drain "mail"
    And the drain logged
    Then the reply is "err job dead attempt=1 id=1 queue=mail reason=discarded"

  Scenario: A job that fails on its last attempt logs an error with the reason attempts_exhausted
    Given a memory backend on a manual clock
    When I enqueue "fail" into "mail" with:
      | setting      | value |
      | max_attempts | 1     |
    And I drain "mail"
    And the drain logged
    Then the reply is "err job dead attempt=1 id=1 queue=mail reason=attempts_exhausted"

  Scenario: The log of a job of a group has the group
    Given a memory backend on a manual clock
    When I enqueue "fail" into "mail" with:
      | setting | value |
      | group   | bot   |
    And I drain "mail"
    And the drain logged
    Then the reply is "warning job failed, it will run again attempt=1 group=bot id=1 queue=mail"

  Scenario: A job that is not due is left alone
    Given a memory backend on a manual clock
    When I enqueue "ok" into "q" with:
      | setting   | value |
      | run_in_ms | 60000 |
    And I drain "q"
    Then the reply is "done 0 retried 0 dead 0"
    When I ask for the counts of "q"
    Then the reply is "ready 0 scheduled 1 leased 0 dead 0"
