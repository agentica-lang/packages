# smtp

An SMTP client for Agentica: plain, STARTTLS and implicit TLS connections, AUTH PLAIN and LOGIN, and the message itself (RFC 5322 headers and addresses, encoded words, text and HTML bodies, quoted-printable). It is written in Agentica over the `TCP` and `TLS` builtins.

Add it in a project with an `agentica.toml`:

```sh
agentica add smtp https://github.com/agentica-lang/packages --tag smtp-0.2.0 --subdir smtp
```

The docs, with examples and the API: <https://www.agentica-lang.com/packages/smtp/>.
