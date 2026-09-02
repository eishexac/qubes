# qubes

Qubes OS Salt formulas and tooling, built to be read before they enter dom0.

Every project in this repository is a self-contained directory. You adopt
one project, or several, or just the airlock — never the whole
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

**Disposable install (recommended).** Open a terminal in a networked
DispVM, then:

```sh
git clone https://github.com/eishexac/qubes.git ~/qubes
cd ~/qubes && sh bootstrap.sh          # or: sh bootstrap.sh <project>
```

It checks dependencies, runs the project's tests, proves the build
reproduces, and prints the exact dom0 commands — with the disposable's
real name and path filled in — to bootstrap the airlock (first time
only), pull, and apply. Close the DispVM afterwards; nothing about the
fetch or build persists. The dom0 lines stay typed by hand and reviewed:
that is the security model, not friction left in by accident.

**The airlock** (`dom0/airlock`) is the airlock those commands go
through: `pull` stages the subtree, scans it (plain files, portable names,
no undeclared binaries), and **diffs it against what is currently
installed** before anything reaches `/srv/salt` — updates are as auditable
as first installs, and approving a change means you just read exactly that
change. `apply` then walks the project's declared install plan — a fixed
verb set interpreted by the reviewed script, never shell from the payload
— one confirmed step at a time, refusing any tree that drifted from its
approval receipt. See the script's header for the full threat model.

**Manual, per project** (no tooling at all):

```sh
# in dom0 — pulls ONLY the wgq subtree
qvm-run --pass-io <qube> 'tar -C /path/to/qubes -c wgq' | sudo tar -C /srv/salt -x
```

Then read every file it landed and follow that project's README by hand.

## Layout

```
qubes/
├── bootstrap.sh         qube side: clone → checks → printed dom0 steps
├── dom0/airlock          the airlock: pull, scan, diff, approve, apply
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

## Releases

Per project: tags are `<project>-vX.Y.Z`, signed by the maintainer's key —
fingerprint and the full verification ritual in
[SECURITY.md](SECURITY.md), key served from
[existin.space](https://existin.space/keys/openpgp/eishexac.asc) and by WKD. A
release never fires for a project whose code did not change, and attached
artifacts are deterministic-build conveniences: verify the tag, rebuild,
compare — do not trust downloads.

## License

GPL-2.0 (see [LICENSE](LICENSE)), for the whole repository.
