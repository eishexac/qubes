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

## Verifying releases

Release tags (`<project>-vX.Y.Z`) are signed with this key, and only this
key:

```
eishexac <hexac@existin.space>
B387 26F0 61C1 AE22 E287  5F90 57ED 9D12 966B 397C
```

Fetch it from more than one channel and compare the fingerprint — the
channels are independent on purpose:

```sh
# the maintainer's site
curl -sS https://existin.space/keys/gpg/eishexac.asc | gpg --import
# or via WKD
gpg --locate-keys hexac@existin.space
# or the copy in this repository (weakest alone; cross-check it)
gpg --import KEY.asc

gpg --fingerprint hexac@existin.space   # must match the block above, and
                                        # the key on github.com/eishexac
```

Then:

```sh
git verify-tag wgq-v0.1.0
```

Artifacts attached to a release are conveniences. The builds are
deterministic, so rebuild from the verified tag and compare instead of
trusting a download: `make -C <project> && sha256sum <project>/dist/*`
must equal the release's `SHA256SUMS`.

## Status

Nothing in this repository has been audited, and each project's README
states how much real-world use it has seen. Published so the reasoning can
be checked.
