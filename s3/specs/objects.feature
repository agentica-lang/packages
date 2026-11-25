Feature: Objects
  The peer is `fixtures/s3_stub.py`, an S3 server on Python's standard library that checks the Signature Version 4 of
  every request with code of its own, so a request that it serves is one that S3 would accept. It listens on 127.0.0.1
  and a free port, with the bucket `photos`.

  Background:
    Given an S3 server

  Scenario: An object is stored, read, described and deleted
    When I put "docs/a b/ñ report+1.txt" with the text "hello s3" as "text/plain"
    Then the object "docs/a b/ñ report+1.txt" reads as "hello s3"
    And the object "docs/a b/ñ report+1.txt" is 8 bytes of "text/plain"
    When I delete "docs/a b/ñ report+1.txt"
    Then the object "docs/a b/ñ report+1.txt" is missing

  Scenario: A range reads part of an object
    When I put "digits" with the text "0123456789"
    Then the range 2 to 5 of "digits" reads as "2345"
    And the range 7 to the end of "digits" reads as "789"

  Scenario: A file goes up and comes down in pieces, as a whole and as a stream
    Given a file "big.bin" of 3000000 bytes
    When I put the file "big.bin" as "files/big.bin"
    And I get "files/big.bin" into the file "down.bin"
    And I stream "files/big.bin" into the file "streamed.bin"
    Then the files "big.bin" and "down.bin" have the same bytes
    And the files "big.bin" and "streamed.bin" have the same bytes

  Scenario: A download that fails leaves the file where it was
    Given a file "keep.txt" that holds "the old text"
    Then downloading "not/there" into the file "keep.txt" fails with "s3.no_such_key" and status 404
    And the file "keep.txt" still holds "the old text"
    And the folder holds only the files "keep.txt"

  Scenario: A bucket reached as a virtual host
    Given the client addresses the bucket as a virtual host
    When I put "vh/k" with the text "by host"
    Then the object "vh/k" reads as "by host"
