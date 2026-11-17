Feature: The conformance suite
  The suite is the contract that every backend must pass. It makes a fresh backend for each case and moves a manual
  clock, so no case sleeps. A backend package runs the same suite with its own maker.

  Scenario: The memory backend passes every contract case
    When the suite runs on the memory backend
    Then the suite has 20 cases
    And no case failed
    And the case "ack removes the job, and a second ack fails" passed
    And the case "eight tasks fetch 200 jobs at once and each job is delivered once" passed

  Scenario: The suite fails a backend whose ack never fails
    When the suite runs on a memory backend whose ack never fails
    Then the case "ack removes the job, and a second ack fails" failed
    And the case "a leased job is not fetched again, and comes back when its lease expires" failed
    And the case "a fetch of an empty queue gives no jobs" passed

  Scenario: The suite skips the cases that need a clock when the backend has none
    When the suite runs on a memory backend that says it has no clock
    Then the case "a retry hides the job until its time" was skipped
    And the case "ack removes the job, and a second ack fails" passed
    And no case failed
