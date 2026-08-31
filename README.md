# qubes

Qubes OS Salt formulas and tooling, built to be read before they enter dom0.

Every project in this repository is a self-contained directory. You adopt
one project, or several, or just the ingest tool — never the whole
repository as a unit. Nothing here asks you to trust a maintainer's key or
a package server: the trust anchors stay Debian and the Qubes OS project,
and the security control for everything that crosses into dom0 is that
**you read the diff before it lands**.

## Projects

| Project | What it is | Status |
|---|---|---|
| [`wgq/`](wgq/) | Leak-tight WireGuard proxy qubes: one VPN qube per identity zone, endpoint allowlist enforced outside the qube it constrains | never run on hardware; design under review |

Each project carries its own README, threat model, and status banner. A
project's warnings are its own: one being well-tested says nothing about
another.

## The rules every project follows

- **Self-contained.** A project's subtree holds everything it installs:
  its Salt states, template files, and tools. No project depends on
  another project, or on anything outside its directory, at install time.
  (Build-time helpers live in [`tools/`](tools/) and are needed only where
  you build, never in dom0.)
- **Read before dom0.** Everything that enters dom0 is text you can read,
  or an artifact whose build is deterministic so you can rebuild and
  compare instead of trust.
- **Fail loudly.** Nothing partly correct gets written. A check that
  cannot fail is treated as a bug.
- **No new trust anchors.** No third-party package repos, no maintainer
  keys, no binaries you cannot verify against source.

## Taking just one project

git clones whole repositories, but you do not have to download or keep
more than the project you want:

```sh
git clone --filter=blob:none --sparse <this repo> qubes
cd qubes && git sparse-checkout set wgq tools
```

That materialises only `wgq/` (plus the shared build helper) while still
verifying against the same history. And regardless of how much you clone,
only the one project's subtree ever enters dom0.

## Getting a project into dom0

dom0 has no network, on purpose. Files get in by dom0 *pulling* them from
a qube that holds this repository — never the other way around.

**Manual, per project** (works today, no tooling):

```sh
# in dom0 — pulls ONLY the wgq subtree
qvm-run --pass-io <qube> 'tar -C /path/to/qubes -c wgq' | sudo tar -C /srv/salt -x
```

Then read every file it landed, as that project's README instructs.

**With the ingest tool** (`dom0/ingest`): the same pull, but staged,
scanned, and **diffed against what is currently installed** before
anything reaches `/srv/salt` — so updates are as auditable as first
installs, and approving a change means you just read exactly that change.
See the header of [`dom0/ingest`](dom0/ingest) for its threat model and
the one-time bootstrap.

## Layout

```
qubes/
├── dom0/ingest          the airlock: pull, scan, diff, approve, install
├── tools/               shared build helpers (deterministic zipapp)
├── test/                tests for the shared tooling
├── wgq/                 project: WireGuard proxy qubes
└── Makefile             `make check` fans out to every project
```

## Checks

```sh
make check     # every project's own checks, plus the shared tooling's
make verify    # every project's artifact verification (determinism etc.)
```

CI runs both on every push and pull request, and nothing merges without
them.

## License

GPL-2.0 (see [LICENSE](LICENSE)), for the whole repository.
