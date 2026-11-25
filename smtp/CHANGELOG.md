# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-11-25

### Added

- `Smtp.loopback?`, the rule `send` uses for a plain connection.

## [0.1.0] - 2026-11-25

- Add `smtp`, an SMTP client moved from Campfire: `send`, `connect`, `send_message` and `quit`, over a plain connection to this machine, STARTTLS or implicit TLS, with AUTH PLAIN or LOGIN; the message (`Message`, `Field`, `Envelope`) with RFC 5322 headers, encoded words and text or HTML bodies; errors with the reply code (`error_code`, `error_summary`). Needs Agentica 0.35.0.
