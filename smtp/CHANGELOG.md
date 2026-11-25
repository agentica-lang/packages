# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- Add `smtp`: an SMTP client moved from Campfire. `Smtp.send` sends one message and `Smtp.connect`, `send_message` and `quit` send several on one connection, over a plain connection to this machine, STARTTLS or implicit TLS, with AUTH PLAIN or LOGIN. `open`, `ehlo`, `starttls` and `login` are the steps of `connect`. The message (`Smtp.Message`, `Smtp.Field`, `Smtp.Envelope`) has RFC 5322 headers and addresses, RFC 2047 encoded words, folded headers, text, HTML or `multipart/alternative` bodies, quoted-printable and a Message-ID. An error from a server has its reply code (`error_code`), and `error_summary` keeps what is safe for a log. Needs Agentica 0.35.0.
