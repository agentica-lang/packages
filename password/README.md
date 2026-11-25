# password

Password hashing with scrypt for Agentica: a digest `scrypt$N$r$p$salt$key` that carries its cost, a constant-time check, the limits of a new password, and the same work for a user that does not exist. It is written in Agentica over the `OpenSSL.KDF.scrypt` builtin.

Add it in a project with an `agentica.toml`:

```sh
agentica add password https://github.com/agentica-lang/packages --tag password-0.1.0 --subdir password
```

The docs, with examples and the API: <https://www.agentica-lang.com/packages/password/>.
