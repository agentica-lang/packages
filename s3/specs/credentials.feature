Feature: Credentials
  A request is signed with the access key, the secret key, the region and, for temporary credentials, the session token.
  The peer is `fixtures/s3_stub.py`, which checks every signature with code of its own.

  Scenario Outline: A request that S3 refuses is an error whose kind is the code of S3
    Given an S3 server
    And the client uses the <setting> "<value>"
    Then putting "k" fails with "<kind>" and status <status>

    Examples:
      | setting    | value           | kind                         | status |
      | secret key | not the secret  | s3.signature_does_not_match  | 403    |
      | access key | AKIDNOBODY      | s3.invalid_access_key_id     | 403    |
      | bucket     | elsewhere       | s3.no_such_bucket            | 404    |


  Scenario: A server that needs a session token
    Given an S3 server that needs the session token "temporary/token"
    When I put "k" with the text "signed with a token"
    Then the object "k" reads as "signed with a token"
    When the client uses the session token "wrong"
    Then reading "k" fails with "s3.invalid_token" and status 403
