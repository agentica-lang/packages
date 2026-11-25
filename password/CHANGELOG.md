# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-25

- Add `password`, moved from Campfire: `Password.hash` and `Password.verify` over scrypt with a digest `scrypt$N$r$p$salt$key` that carries its cost, `Password.problem` for the limits of a new password, and `Password.verify_nobody` for the same work when a user does not exist. A digest that is not of that form, or out of the bounds of one that `hash` could make (at most 256 MiB of memory, and the sizes of the salt and the key), is an `error` of `verify`. Needs Agentica 0.35.0.
