# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- Add `password`, moved from Campfire: `Password.hash` and `Password.verify` over scrypt with a digest `scrypt$N$r$p$salt$key` that carries its cost, `Password.problem` for the limits of a new password, and `Password.verify_nobody` for the same work when a user does not exist. A digest that is not of that form is an `error` of `verify`. Needs Agentica 0.35.0.
