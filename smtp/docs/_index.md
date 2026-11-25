---
title: smtp
description: An SMTP client that sends email. STARTTLS, implicit TLS, AUTH PLAIN and LOGIN, text and HTML bodies, encoded headers, and errors that carry the reply code.
category: Networking
keywords: [email, mail, smtp, starttls, mime]
---

`smtp` sends email from an Agentica program. It connects to an SMTP server (plain on this machine, STARTTLS, or TLS from the first byte), logs in with AUTH PLAIN or LOGIN, and sends messages with `MAIL FROM`, `RCPT TO` and `DATA`. It also writes the message: the RFC 5322 headers and addresses, RFC 2047 encoded words for a subject or a name that is not ASCII, folded headers, a text body, an HTML body or both as `multipart/alternative`, quoted-printable where the text needs it, and a Message-ID. It is written in Agentica over the `TCP` and `TLS` builtins, with no C.

It sends. It keeps no queue and does not retry: an app that must not lose mail puts the call behind its own queue (for example [jobs](https://www.agentica-lang.com/packages/jobs/)).

## Install

The released version needs Agentica 0.35.0. Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`:

```sh
agentica add smtp agentica-lang/packages --tag smtp-0.1.0 --subdir smtp
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
smtp = { git = "https://github.com/agentica-lang/packages", tag = "smtp-0.1.0", subdir = "smtp" }
```

## Example

`Smtp.send` connects, sends one message and quits. The options say where to connect and as whom. `local_hostname` is the name that EHLO gives, the name of the machine that sends:

```agentica {mode="check"}
import Smtp from "pkg/smtp/smtp"

def main() -> Void
  options = Smtp.Options(
    host: "smtp.example.com",
    local_hostname: "app.example.com",
    username: "ana@example.com",
    password: "fake-password",
  )

  message = Smtp.Message(
    from: "Ana <ana@example.com>",
    to: ["bob@example.com"],
    subject: "Hello",
    text: "Hi Bob.",
  )

  sent = Smtp.send(message, options)
  if not sent.ok?
    puts(sent.message)
  end
end
```

The default security is STARTTLS on port 587. The client says EHLO, upgrades the connection, says EHLO again and only then logs in, so a password never goes in the clear. For TLS from the first byte, set `security: Smtp.Security.Implicit` and `port: 465`: the port does not follow the security.

Every function gives a `Result`. An error from a server that answered has its reply code in the message, and `error_code` reads it back:

```agentica
import Smtp from "pkg/smtp/smtp"

def main() -> Void
  message = "smtp 550: a recipient was refused: mailbox unavailable (ana@example.com)"
  puts(Smtp.error_code(message).unwrap!)
  puts(Smtp.error_summary(message))
end
```

```output
550
smtp 550: a recipient was refused
```

## Security

- STARTTLS is required. A server that does not offer it gets no message and no password, unless the options say `Smtp.Security.Plain`, which is only allowed for a host on this machine (`localhost`, `127.0.0.0/8`, `::1`).
- The certificate of the server is checked against the system's authorities, or against `ca_file`, and the host name must match.
- The password is sent only over an encrypted connection (or to this machine). A `Client` that `connect` gives no longer holds it.
- A message with a line break or another control character in a header, in an address or in a name is refused before any connection, so a value that comes from a user cannot add a header or a recipient. A custom header must be ASCII.
- The text of the server that goes into an error is cut to 200 characters and loses its control characters, including the C1 and bidirectional ones, so an error is safe to print. The errors of the login hold no text of the server at all, so a server that echoes what it was sent cannot put the password in an error. `error_summary` keeps only what is safe for a log read by many people.
- `Options` holds the password: never print or log one. The password is never part of an error.

## Types

### `Smtp.Message`

```signature
Smtp.Message(from: String, to: List[String], subject: String, text: String = "", html: String = "", cc: List[String] = [], bcc: List[String] = [], reply_to: String = "", date: String = "", message_id: String = "", headers: List[Smtp.Field] = [])
```

What to send. An address is `ana@example.com` or `Ana <ana@example.com>`, and a name may be any text. `text` or `html` (or both: the reader's client picks one) must have something in it. `bcc` addresses get the message but are not in its headers. An empty `date` and `message_id` are made when the message is sent (the time of now, and a random id at the domain of the sender); a text in them is written as it is.

### `Smtp.Field`

```signature
Smtp.Field(name: String, value: String)
```

A header that is not one of the fields of a `Message`, such as `List-Unsubscribe`. The name must be a header name, it may not be one of the headers that the fields write (`From`, `Subject`, `Content-Type`, ...), and the value must be ASCII.

### `Smtp.Envelope`

```signature
Smtp.Envelope(sender: String, recipients: List[String])
```

The addresses of the dialogue, `MAIL FROM` and one `RCPT TO` each, apart from the names in the headers. The recipients are those of `to`, `cc` and `bcc`, without repeats.

### `Smtp.Options`

```signature
Smtp.Options(host: String, local_hostname: String, port: Int = 587, security: Smtp.Security = Smtp.Security.Starttls, username: String = "", password: String = "", ca_file: String = "", timeout_ms: Int = 60000, data_timeout_ms: Int = 600000)
```

Where to connect and as whom. `username` and `password` log in when the username is not empty. `local_hostname` has no default: EHLO needs the name of the machine that sends, as other servers can look it up. `port` defaults to 587, the port of STARTTLS, so `Security.Implicit` needs `port: 465`. A `timeout_ms` or a `data_timeout_ms` of 0 or less is an error. `ca_file` is a PEM file of certificate authorities that replaces the system's. `timeout_ms` is the time for each connection, each reply and each write, and `data_timeout_ms` the time for the reply after the message, which a server may take long to give (RFC 5321 allows 10 minutes). The constants `Smtp.STARTTLS_PORT` (587), `Smtp.IMPLICIT_TLS_PORT` (465), `Smtp.DEFAULT_TIMEOUT_MS` and `Smtp.DEFAULT_DATA_TIMEOUT_MS` hold the defaults.

### `Smtp.Security`

`Smtp.Security.Starttls` starts in plain text and upgrades with STARTTLS, which the server must offer (port 587). `Smtp.Security.Implicit` is TLS from the first byte (port 465: set `port`, since the default is 587). `Smtp.Security.Plain` never uses TLS and is only for a host on this machine, such as a mail catcher in development: any other host is an error.

### `Smtp.Client`

An open connection to a server. It belongs to the task that opened it, as every socket does.

## API

### `Smtp.send(message, options) -> Result[Void]`

Sends one message: connects, logs in when the options have a username, sends and quits. The connection is closed in every case. The message is checked first, so a bad message never opens a connection. A server that answers QUIT badly does not undo a message that was delivered.

### `Smtp.connect(options) -> Result[Smtp.Client]`

Opens the connection, reads the greeting, says EHLO, upgrades with STARTTLS (for `Security.Starttls`) and logs in (when `username` is not empty). On an `error` nothing stays open. The `Client` that it gives no longer holds the password. Use it to send several messages on one connection:

```agentica {mode="check"}
import Smtp from "pkg/smtp/smtp"

def send_all(messages: List[Smtp.Message], options: Smtp.Options) -> Result[Void]
  client = try Smtp.connect(options)
  for message in messages
    sent = Smtp.send_message(client, message)
    if not sent.ok?
      Smtp.close(client)
      return sent
    end
  end

  Smtp.quit(client)
end
```

### `Smtp.send_message(client, message) -> Result[Void]`

Sends a message on the connection: `MAIL FROM`, `RCPT TO` for each recipient, then the message. If the server refuses the sender, a recipient or the message, nothing is delivered, the connection is reset (`RSET`) for the next message and the `error` has the code of the refusal. An error with no code that comes from the dialogue (a timeout, a line that is not a reply) closes the connection, and so does a 421. A bad message leaves it as it is.

### `Smtp.quit(client) -> Result[Void]`

Says QUIT and closes the connection, even when the server does not answer.

### `Smtp.close(client) -> Void`

Closes the connection without saying QUIT.

### `Smtp.error_code(message) -> Optional[Int]`

The code of the reply that an `error` of this package tells, or `none` for an error that has no reply (a timeout, a broken connection, a bad message).

### `Smtp.error_summary(message) -> String`

What of an `error` is safe for a log that many people read: the code and the label of a refusal (`smtp 550: a recipient was refused`), or the first words of an error without a code (`smtp: timed out waiting for the reply to RCPT TO`). It has no server text, no recipient address and no system message. The host of the options may appear in the two errors that name it (a plain connection to a host that is not this machine, and a bad `local_hostname`). A message that is not valid, whose error names what is wrong with it (such as an address), is summarized as `the message was not valid`.

## Errors

An `error` is a message, not a kind. One from a server that answered starts `smtp NNN:` with the reply code, then what was refused, then the text of the server: `smtp 550: a recipient was refused: mailbox unavailable (ana@example.com)`. One without a code starts `smtp: ` (a timeout, a connection that broke, a refused setting). One for a message that is not valid names what is wrong with it. Test the code with `error_code`, never with the text of the server.

## Tests

The package is checked against `specs/fixtures/smtp_peer.agc`, an SMTP server written in Agentica apart from the code under test, which listens on 127.0.0.1 and a free port and writes the dialogue it saw. It reads the bytes itself, so a line that does not end in CRLF shows in the transcript. The features compare that transcript with the one they expect, for the plain, STARTTLS and implicit TLS connections, both logins, dot-stuffing, refusals, replies of every shape (many lines, long lines, control characters), timeouts and a certificate for another host. The certificates in `specs/fixtures/tls/` are test data made by `make-certs.sh`, and the login of the peer is `ana` with `secret`. The messages are also checked in `test/message_test.agc`.
