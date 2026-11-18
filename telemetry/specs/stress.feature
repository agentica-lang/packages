Feature: Many tasks at once
  Tasks attach, detach and emit together while one handler hears everything. The handler that stays gets each event
  once, no handler gets an event twice, one attach of an id that many tasks tried wins, and the hub is alive at the
  end.

  Scenario: 16 tasks attach, emit 50 events each and detach
    Given the hub is started
    When 16 tasks attach, emit 50 events each and detach, while one handler hears everything
    Then the reply is "ok"

  Scenario: One task does the same
    Given the hub is started
    When 1 tasks attach, emit 50 events each and detach, while one handler hears everything
    Then the reply is "ok"
