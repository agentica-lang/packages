Feature: The conformance suite
  The suite is the contract that every backend must pass. It makes a fresh backend for each case and moves a manual
  clock, so no case sleeps. A backend package runs the same suite with its own maker.

  Scenario: The memory backend passes every contract case
    When the suite runs on the memory backend
    Then the suite has 27 cases
    And no case failed
    And the case "ack removes the job, and a second ack fails" passed
    And the case "eight tasks fetch 200 jobs at once and each job is delivered once" passed

  Scenario: The suite fails a backend whose ack never fails
    When the suite runs on a memory backend whose ack never fails
    Then the case "ack removes the job, and a second ack fails" failed
    And the case "a leased job is not fetched again, and comes back when its lease expires" failed
    And the case "a fetch of an empty queue gives no jobs" passed

  Scenario: The suite fails a backend that ignores the wait of a fetch
    When the suite runs on a memory backend that ignores the wait of a fetch
    Then the case "a fetch that waits gets a job that is enqueued meanwhile" failed
    And the case "a fetch that waits gives no jobs when its time is up" failed
    And the case "a fetch that waits for a scheduled job gets it when it is due" failed
    And the case "a fetch of an empty queue gives no jobs" passed

  Scenario: The suite fails a backend whose nack and extend work after close
    When the suite runs on a memory backend whose nack and extend work after close
    Then the case "after close, calls fail with jobs.closed, and a second close does nothing" failed
    And the case "ack removes the job, and a second ack fails" passed

  Scenario Outline: A backend that does not follow an injected clock runs the cases on time on the real clock
    Then the case "<case>" passes on a memory backend that reads the real clock

    Examples:
      | case                                                                              |
      | a fetch that waits gives no jobs when its time is up                              |
      | a fetch that waits for a scheduled job gets it when it is due                     |
      | a leased job is not fetched again, and comes back when its lease expires          |
      | a late ack, nack or extend of an older delivery changes nothing                   |
      | an ack, nack or extend after the lease ran out fails, before any other fetch      |
      | a retry hides the job until its time                                              |
      | a dead job is never delivered again, and is counted                               |
      | the expiry of the last attempt makes the job dead                                 |
      | extend moves the end of the lease, and the job comes back at the new end          |
      | a job is not delivered before its time                                            |
      | a unique key stays held through a retry, a release and an expired lease           |
