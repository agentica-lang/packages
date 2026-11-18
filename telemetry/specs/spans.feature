Feature: Spans
  A span runs a body and says how it went: a start event, then a stop event with the duration, or an error event with
  the duration and the kind of the error. The three events share one span_id. The body's result is the span's result.

  Scenario: A body that works emits start and stop, and its result passes through
    Given the hub is started
    When I attach "h" to "mail"
    And I run a span "mail.send"
    Then the reply is "ok 42"
    When I flush
    Then the handler "h" got the events "mail.send.start, mail.send.stop"

  Scenario: The stop event has the duration, and the start event has none
    Given the hub is started
    When I attach "h" to "mail"
    And I run a span "mail.send" that sleeps 20 ms
    And I flush
    Then the handler "h" got events with one span_id
    And the last event of "h" has a duration of at least 15 ms
    And the first event of "h" has no duration

  Scenario: A body that returns an error emits start and error, and the error passes through
    Given the hub is started
    When I attach "h" to "mail"
    And I run a span "mail.send" whose body returns an error
    Then the reply is "error span.bad"
    When I flush
    Then the handler "h" got the events "mail.send.start, mail.send.error"
    And the last event of "h" includes:
      """
      "error_kind": "span.bad"
      """
    And the handler "h" got events with one span_id
    And the last event of "h" has a duration of at least 0 ms

  Scenario: The metadata of the call is on every event, with the span_id
    Given the hub is started
    When I attach "h" to "mail"
    And I run a span "mail.send" with:
      | kind | key   | value   |
      | meta | queue | welcome |
    And I flush
    Then the handler "h" got the events "mail.send.start, mail.send.stop"
    And the last event of "h" includes:
      """
      {"queue": "welcome", "span_id": "1"}
      """
    And the first event of "h" includes:
      """
      {"queue": "welcome", "span_id": "1"}
      """

  Scenario: Each span has an id of its own
    Given the hub is started
    When I attach "h" to "mail"
    And I run a span "mail.send"
    And I run a span "mail.send"
    And I flush
    Then the handler "h" got 2 span_ids

  Scenario: A body that crashes emits its start and no stop or error, and the run does not fail
    Given the hub is started
    When I attach "h" to "mail"
    And I run a span "mail.send" whose body crashes
    And I flush
    Then the handler "h" got the events "mail.send.start"
    When I close stdin
    Then the program exits with code 0 within 5000 milliseconds

  Scenario: A handler that hears only the stop events gets them
    Given the hub is started
    When I attach "h" to "mail.send.stop"
    And I run a span "mail.send"
    And I flush
    Then the handler "h" got the events "mail.send.stop"

  Scenario: With no handler attached the body runs and nothing is emitted
    Given the hub is started
    When I run a span "mail.send"
    Then the reply is "ok 42"

  Scenario: With no hub started the body runs
    When I run a span "mail.send"
    Then the reply is "ok 42"
