Feature: The events of jobs
  Every call of the facade says what happened to a telemetry handler, and `Jobs.drain` also runs each job in the span
  `jobs.job`. The steps read the events that the driver captured, after the conventions of `telemetry` checked each one.
  A line is the name, the queue, the numbers (`count`, `duplicate_count`) and the words (`attempt`, `how`, `verdict`,
  `error_kind`) that the event has.

  Scenario: Enqueue, fetch and ack say so, with the queue and the attempt
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "ok" into "mail"
    And I fetch a job of "mail" as "a"
    And I ack "a"
    Then the events are:
      | event                                |
      | jobs.enqueue mail count=1 duplicate_count=0 |
      | jobs.fetch mail count=1              |
      | jobs.ack mail count=1 attempt=1      |

  Scenario: A batch is one event for each queue, and a duplicate of a unique key is counted apart from the jobs added
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "ok" into "mail" with:
      | setting    | value |
      | unique_key | k     |
    And I enqueue "ok" into "mail" with:
      | setting    | value |
      | unique_key | k     |
    And I enqueue the jobs "a,b,c" into "push" in one batch
    Then the events are:
      | event                                         |
      | jobs.enqueue mail count=1 duplicate_count=0   |
      | jobs.enqueue mail count=0 duplicate_count=1   |
      | jobs.enqueue push count=3 duplicate_count=0   |

  Scenario: A fetch that leased some jobs counts them, and an empty fetch says nothing
    Given a memory backend on a manual clock
    And I watch the events
    When I fetch a job of "mail" as "a"
    And I enqueue the jobs "a,b,c" into "mail" in one batch
    And I fetch 2 jobs of "mail" as "b"
    Then the events are:
      | event                                       |
      | jobs.enqueue mail count=3 duplicate_count=0 |
      | jobs.fetch mail count=2                     |

  Scenario: A nack says how the job went back
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue the jobs "a,b,c" into "mail" in one batch
    And I fetch 3 jobs of "mail" as "x"
    And I retry "x" in 1000 ms
    And I release "x/2"
    And I kill "x/3"
    Then the events are:
      | event                                       |
      | jobs.enqueue mail count=3 duplicate_count=0 |
      | jobs.fetch mail count=3                     |
      | jobs.nack mail count=1 attempt=1 how=retry  |
      | jobs.nack mail count=1 attempt=1 how=release |
      | jobs.nack mail count=1 attempt=1 how=dead   |

  Scenario: A call that failed says nothing
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "ok" into "mail"
    And I fetch a job of "mail" as "a"
    And I ack "a"
    And I read the events
    And I ack "a"
    Then the reply is "error jobs.lease_lost"
    When I read the events
    Then the reply is "ok"

  Scenario: A drained job that succeeds is a span, an ack and a settle
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "ok" into "mail"
    And I drain "mail"
    Then the events are:
      | event                                       |
      | jobs.enqueue mail count=1 duplicate_count=0 |
      | jobs.fetch mail count=1                     |
      | jobs.job.start mail attempt=1               |
      | jobs.job.stop mail attempt=1                |
      | jobs.ack mail count=1 attempt=1             |
      | jobs.job.settle mail count=1 attempt=1 verdict=ack |

  Scenario: A drained job that fails is an error event, a retry and a settle
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "fail" into "mail"
    And I drain "mail"
    Then the events are:
      | event                                        |
      | jobs.enqueue mail count=1 duplicate_count=0  |
      | jobs.fetch mail count=1                      |
      | jobs.job.start mail attempt=1                |
      | jobs.job.error mail attempt=1 error_kind=error |
      | jobs.nack mail count=1 attempt=1 how=retry   |
      | jobs.job.settle mail count=1 attempt=1 verdict=retry |

  Scenario: A discarded job is an error event with the kind jobs.discard, and a dead settle
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "discard" into "mail"
    And I drain "mail"
    Then the events are:
      | event                                                  |
      | jobs.enqueue mail count=1 duplicate_count=0            |
      | jobs.fetch mail count=1                                |
      | jobs.job.start mail attempt=1                          |
      | jobs.job.error mail attempt=1 error_kind=jobs.discard  |
      | jobs.nack mail count=1 attempt=1 how=dead              |
      | jobs.job.settle mail count=1 attempt=1 verdict=dead    |

  Scenario: A job that fails on its last attempt settles as dead
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "fail" into "mail" with:
      | setting      | value |
      | max_attempts | 1     |
    And I drain "mail"
    Then the events are:
      | event                                                |
      | jobs.enqueue mail count=1 duplicate_count=0          |
      | jobs.fetch mail count=1                              |
      | jobs.job.start mail attempt=1                        |
      | jobs.job.error mail attempt=1 error_kind=error       |
      | jobs.nack mail count=1 attempt=1 how=dead            |
      | jobs.job.settle mail count=1 attempt=1 verdict=dead  |

  Scenario: A retry that runs again has the next attempt in its events
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "fail once" into "mail"
    And I drain "mail", with the jobs that wait for a time
    Then the events are:
      | event                                                 |
      | jobs.enqueue mail count=1 duplicate_count=0           |
      | jobs.fetch mail count=1                               |
      | jobs.job.start mail attempt=1                         |
      | jobs.job.error mail attempt=1 error_kind=error        |
      | jobs.nack mail count=1 attempt=1 how=retry            |
      | jobs.job.settle mail count=1 attempt=1 verdict=retry  |
      | jobs.fetch mail count=1                               |
      | jobs.job.start mail attempt=2                         |
      | jobs.job.stop mail attempt=2                          |
      | jobs.ack mail count=1 attempt=2                       |
      | jobs.job.settle mail count=1 attempt=2 verdict=ack    |

  Scenario: The log lines stay, with or without the events
    Given a memory backend on a manual clock
    And I watch the events
    When I enqueue "fail" into "mail"
    And I drain "mail"
    And the drain logged
    Then the reply is "warning job failed, it will run again attempt=1 id=1 queue=mail"

  Scenario Outline: A handler gets the events that its pattern names, and no others
    Given a memory backend on a manual clock
    And I watch the events of "<pattern>"
    When I enqueue "ok" into "mail"
    And I enqueue "discard" into "mail"
    And I drain "mail"
    Then the event names are "<names>"

    Examples:
      | pattern          | names |
      | jobs.enqueue     | jobs.enqueue; jobs.enqueue |
      | jobs.fetch       | jobs.fetch; jobs.fetch |
      | jobs.ack         | jobs.ack |
      | jobs.nack        | jobs.nack |
      | jobs.job.stop    | jobs.job.stop |
      | jobs.job.error   | jobs.job.error |
      | jobs.job.settle  | jobs.job.settle; jobs.job.settle |
      | jobs.job         | jobs.job.start; jobs.job.stop; jobs.job.settle; jobs.job.start; jobs.job.error; jobs.job.settle |
      | *                | jobs.enqueue; jobs.enqueue; jobs.fetch; jobs.job.start; jobs.job.stop; jobs.ack; jobs.job.settle; jobs.fetch; jobs.job.start; jobs.job.error; jobs.nack; jobs.job.settle |
      | pool             | |
