---
title: For agents
description: How an AI that writes Agentica should state laws, read a failure and report the result.
weight: 5
---

This page is for an AI that writes Agentica code, after the `AGENTS.md` of [josevalim/lynx](https://github.com/josevalim/lynx). State what a function must do as laws, and let the tests find where it does not.

1. State at least one law for each public function: a round trip, idempotence, an oracle (a slow, obviously right version), an invariant (`Prop.preserves`), or at least "does not crash" (`Prop.check` with a law that only calls the function and returns `ok()`). Put the laws in `test/`, apart from the code. The law is the specification, so it is not written from the code that it checks.
2. When a law fails, the message has the shrunk counterexample and the seed. Copy the counterexample into a plain `test_` function (it stays a test when the generator changes), then fix the code.
3. Never weaken the law, narrow the generator, raise `discards` or lower `runs` to make a test pass. If the law is wrong for some inputs, say which ones with `Prop.assume` and keep that in the report.
4. Report what was done, not what is proved: "tested with 100 cases, seed 1234, discards 0", or "all 15 cases up to size 3". Never write "proved", "verified" or "correct for all inputs".

A passing `check` returns a plain `ok()` with no seed. To report the seed, pin it with `Prop.Config(seed: some(1234))`. The seed of a failure is in its message. The number of discarded cases is not returned either: say 0 only when the law has no `Prop.assume`.
