Feature: Presigned URLs
  A URL signed for the host of the endpoint lets a client that has no credentials (a browser, `curl`) read or write one
  key for a while. The peer is `fixtures/s3_stub.py`, which checks the query signature with code of its own.

  Background:
    Given an S3 server

  Scenario: A presigned GET gives the object with the download name that the URL asks for
    Given I put "reports/q3 ñ.pdf" with the text "the report"
    Then fetching a presigned URL for "reports/q3 ñ.pdf" gives "the report" and the disposition "attachment; filename=\"q3.pdf\""

  Scenario: A presigned PUT takes a file from curl
    Given a file "upload.bin" of 500000 bytes
    When curl puts the file "upload.bin" to a presigned URL for "uploads/curl.bin"
    Then the object "uploads/curl.bin" has the bytes of the file "upload.bin"

  Scenario: A URL that has expired or was changed is refused
    Given I put "a" with the text "A"
    Then a presigned URL for "a" made 120 seconds ago for 60 seconds answers 403 with "AccessDenied"
    And a presigned URL for "a" that is changed to "b" answers 403 with "SignatureDoesNotMatch"
