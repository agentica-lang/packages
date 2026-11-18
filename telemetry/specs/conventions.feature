Feature: The conventions
  `Conformance.check` is for the tests of a library: it accepts the events that follow the conventions of the docs and
  gives the first problem, with a kind, for one that does not.

  Scenario Outline: The starter events are accepted
    When I check the event "<name>" with:
      | kind  | key         | value |
      | int   | <int>       | 1     |
      | float | ratio       | 0.5   |
      | meta  | queue       | mail  |
      | meta  | error_kind  | none  |
    Then the reply is "ok"

    Examples:
      | name                | int         |
      | jobs.job.stop       | duration_ns |
      | jobs.job.error      | duration_ns |
      | jobs.enqueue        | count       |
      | pool.size           | size        |
      | http_client.request | size_bytes  |
      | vm.gc               | pauses_total |

  Scenario: An event with no measurements and no metadata is accepted
    When I check the event "jobs.fetch"
    Then the reply is "ok"

  Scenario Outline: A bad name is refused
    When I check the event "<name>"
    Then the reply is "error conformance.name"

    Examples:
      | name       |
      | Jobs.stop  |
      | jobs..stop |
      | jobs.      |
      | 9jobs      |
      | jobs-queue |
      | a.b.c.d.e  |
      | jobs stop  |
      | .jobs      |

  Scenario Outline: A measurement with no unit, or a key in the wrong place, is refused
    When I check the event "jobs.job.stop" with:
      | kind   | key   | value |
      | <kind> | <key> | 1     |
    Then the reply is "error conformance.measurement"

    Examples:
      | kind  | key         |
      | int   | duration    |
      | int   | waiting     |
      | int   | Size_Bytes  |
      | int   | duration_ms |
      | float | duration_ns |
      | float | fraction    |
      | float | size_bytes  |

  Scenario: A key in both maps is refused
    When I check the event "jobs.job.stop" with:
      | kind  | key   | value |
      | int   | count | 1     |
      | float | count | 1.5   |
    Then the reply is "error conformance.measurement"

  Scenario Outline: A duration is for the events that end
    When I check the event "<name>" with:
      | kind | key         | value |
      | int  | duration_ns | 5     |
    Then the reply is "<reply>"

    Examples:
      | name           | reply                          |
      | jobs.job.stop  | ok                             |
      | jobs.job.error | ok                             |
      | jobs.job.start | error conformance.measurement  |
      | jobs.enqueue   | error conformance.measurement  |

  Scenario Outline: A metadata key that is not snake_case is refused
    When I check the event "jobs.job.stop" with:
      | kind | key   | value |
      | meta | <key> | x     |
    Then the reply is "error conformance.metadata"

    Examples:
      | key       |
      | Queue     |
      | job-id    |
      | 1st       |
      | queue.name |
