# Security

## Reporting

Use GitHub's private vulnerability reporting on this repository
(**Security → Report a vulnerability**). That keeps the report private
until there is a fix.

Please do not open a public issue for anything that would let someone's
traffic or data leak before it is fixed.

There is no bounty, no SLA, and one maintainer. You will get an honest
answer, which may be "yes, and I do not know when I will fix it".

## Scope

Scope is defined per project: each project's README states its threat
model — what it defends against, and what is deliberately outside its
design. Read it before deciding whether a behaviour is a vulnerability or
a documented limit. For `wgq`, see [`wgq/SECURITY.md`](wgq/SECURITY.md).

Two things are in scope for the repository as a whole:

- **The ingest path.** Anything that lets content reach `/srv/salt`
  without having been shown in the review diff — a file the scan misses, a
  path that escapes the staging directory, an install that differs from
  what was displayed.
- **Anything that moves key material or credentials** into a log, an error
  message, a Salt state, or a qube that should never hold it.

## Status

Nothing in this repository has been audited, and each project's README
states how much real-world use it has seen. Published so the reasoning can
be checked.
