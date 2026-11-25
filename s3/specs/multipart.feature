Feature: Multipart uploads
  A file bigger than one request goes in parts, which S3 joins when the upload completes. Every part but the last must be
  5 MiB or more. The peer is `fixtures/s3_stub.py`, which keeps the parts and checks every signature.

  Background:
    Given an S3 server

  Scenario: Parts are uploaded, listed and completed into one object
    Given a file "first" of 5242880 bytes
    And a file "second" of 1000000 bytes
    When I start a multipart upload of "multi/two.bin"
    And I upload part 1 from the file "first"
    And I upload part 2 from the file "second"
    Then the parts of the upload are "1:5242880,2:1000000"
    When I complete the upload of "multi/two.bin"
    Then the etag of "multi/two.bin" ends with "-2\""

  Scenario: An aborted upload is gone
    Given a file "part" of 5242880 bytes
    When I start a multipart upload of "multi/gone.bin"
    And I upload part 1 from the file "part"
    And I abort the upload of "multi/gone.bin"
    Then the parts of the upload of "multi/gone.bin" fail with "s3.no_such_upload" and status 404

  Scenario: A part under 5 MiB that is not the last one is refused when the upload completes
    Given a file "small" of 1000000 bytes
    When I start a multipart upload of "multi/small.bin"
    And I upload part 1 from the file "small"
    And I upload part 2 from the file "small"
    Then completing the upload of "multi/small.bin" fails with "s3.entity_too_small" and status 400

  Scenario: A file is cut into parts, and a small one is not
    Given a file "twelve" of 12000000 bytes
    And a file "tiny" of 100000 bytes
    When I upload the file "twelve" as "multi/twelve.bin" in parts of 5242880 bytes
    And I upload the file "tiny" as "multi/tiny.bin" in parts of 5242880 bytes
    Then the object "multi/twelve.bin" has the bytes of the file "twelve"
    And the etag of "multi/twelve.bin" ends with "-3\""
    And the object "multi/tiny.bin" has the bytes of the file "tiny"

  Scenario: A browser uploads the parts with presigned URLs
    Given a file "first" of 5242880 bytes
    And a file "last" of 700000 bytes
    When I start a multipart upload of "multi/browser.bin"
    And I upload part 1 through a presigned URL from the file "first"
    And I upload part 2 through a presigned URL from the file "last"
    And I complete the upload of "multi/browser.bin"
    Then the etag of "multi/browser.bin" ends with "-2\""
