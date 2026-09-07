# Changelog

Newest first. The top section is the pending version and grows as
changes merge; releasing stamps its date and signs the tag. Entries
record what changed for the person running the tool.

## [0.3.0] — unreleased

Breaking release in progress: named zones only, and the zone becomes a
positional. See docs/lifecycle.md as sections land.

### Added

- The zone is a positional on every zone verb: `wgq disconnect work`,
  `wgq connect work`, `wgq verify work`, `wgq set work dns <ip>`.
  `up`/`down` are aliases for connect/disconnect. With no zone named:
  on a terminal a picker opens — always, even with one zone (choosing
  from a one-item list is explicit; a guess is not) — and per-zone
  verbs multi-select; without a terminal the command refuses and lists
  the zones. Nothing is ever implied.
- `-z <zone>` is accepted anywhere on the line and keeps working
  everywhere; `--zone` after a management verb still belongs to that
  verb.
- Zone colours, in the console: `zone add <name> --color blue` picks
  from a 12-colour palette, omitting it auto-assigns the first free
  one, and no two zones share a colour. The colour paints the zone's
  name in `zone list` and the picker (never in pipes — NO_COLOR and
  non-tty stay escape-free), rides `zone list --json` as a field, is
  stored as a feature on the VPN qube, travels through `rename`, and
  is freed by `remove`. Icons and qube labels are deliberately
  untouched.
- `wgq route`: Qubes' system-level network consumers — dom0 updates,
  template updates, clock sync, new qubes' default netvm — routed
  through a zone of your choosing, one grammar, `route list` as the
  overview. Everything routed inherits fail-closed. The one policy
  write (template updates) prints its exact file first and installs on
  yes, sorted at 51 so Whonix templates keep updating over Tor; clock
  routing explains the cold-boot paradox and asks twice.
- `wgq restart [zone]`: the shutdown/start cycle that makes an update
  real, offered — the plan prints first, the clients that go dark are
  named, one confirmation, declining runs nothing. The install plan now
  ends with a note pointing at it (the plan can speak; the qubes belong
  to the wgq tool).

### Fixed

- Icons were blank in GTK tools (the Update GUI foremost) while fine in
  Qt ones: gdk-pixbuf recognizes an SVG by finding `<svg` near the top
  of the file, and every icon buried it under a ~1 KB license comment.
  The comment now lives inside the `<svg>` element; a check guards the
  tag's position forever. Qt never sniffs, which is why the menu and
  Qube Manager saw the icons all along.

### Changed

- Zone names may not be `autoconnect`, `dns` or `default`: they are the
  words that let `set` tell a key from a zone.
- `zone add` requires a name; the Enter-for-the-default prompt is gone.
- The reserved zone `wgq` is deprecated: it can no longer be created,
  an existing one still converges (with a warning), and
  `zone rename wgq <name>` migrates it — clone, retag, rewire, clients
  follow, mgmt bundle moves, registered key survives. Reading the bare
  `sys-wgq` name ends in 0.4.0: removing it in the same release that
  ships the migration tool would strand un-migrated machines mid-update.

## [0.2.0] — 2026-09-06

### Added

- `wgq verify [-z zone] [--kill-rounds N]`: the leak checks as one dom0
  command. Parameters are gathered from the zone, probes are pushed into
  the client (Python stdlib only — nothing to install there), and the
  kill test is driven end to end: stop, prove the stop, probe, restart,
  prove recovery, N rounds. `test/verify.sh` remains for zones wgq did
  not build.
- `wgq doctor`: read-only check of every installed invariant — icons,
  policies, ownership tags, each zone's chain, the kill-switch rules
  read back, the accel fast path absent, the no-accel hook present —
  with a fix command printed for every failure.
- `wgq connect` / `wgq disconnect`: tunnel up and down from dom0.
  Disconnected means dark — the kill switch stays, clients get nothing.
- `wgq set autoconnect on|off`: autoconnect remains the default; off
  makes the zone boot sealed (forwarding refused) until an explicit
  connect.
- `wgq set dns <ip>|default`: pin client DNS to a chosen resolver,
  reached through the tunnel only. An unusable value is refused in dom0;
  an unusable stored override falls back to the provider pin, never to
  no pin.
- `wgq get`: the zone's settings and tunnel state, each value labeled
  with the layer that answered (zone override, global, default).
- `wgq set --global`: settings layer under the per-zone overrides --
  a global default applies to every zone without its own value, stored
  as features on dom0, materialized into the zones at set and connect,
  and checked for drift by doctor. New zones inherit globals at birth.
  An explicit zone value beats the global even when they agree, and
  `set <key> default` clears a layer.
- A STUN probe joins `wgq verify` (check 1b): the public address a STUN
  server sees over UDP must match the tunnel exit -- the WebRTC leak
  question answered at the layer this tool controls.
- `--json` on `servers`, `peer list`, `status` and `zone list`: one
  parseable document on stdout, human notes on stderr.

### Changed

- The README is a front door again: status, quickstart, and a map. The
  full documentation moved to `docs/` — threat model, architecture,
  install, lifecycle, verify — one file per question, versioned and
  signed with the code they describe.

- The tunnel's boot-time start moved from `wg-tunnel.service` to a new
  `wg-autoconnect.service`; `wg-tunnel` is now started only by
  autoconnect or `wgq connect`.

### Upgrading

A `set autoconnect off` made with a build before the settings layering
must be re-run once (the bare boot flag is no longer read as intent).

The template changed. After `airlock apply wgq`: shut down the wgq
template, restart the zone qubes, then check with `wgq doctor` and
`wgq verify --kill-rounds 3`.

The next release (0.3.0) retires the reserved default zone in favour of
named zones only; that one will be breaking.

## [0.1.0] — 2026-09-04

First release, verified end to end on hardware before tagging.

- One VPN qube per identity zone: `wgq zone add/attach/detach/remove`,
  clients pointing at `sys-fw-<zone>`, explicit-only attachment.
- Provisioning through wgq-mgmt (`credential`, `keygen`, `provision`,
  `sync`, `switch`, `firewall`) for Mullvad and IVPN; the private key
  never leaves the zone qube.
- Kill switch installed as one atomic nftables transaction; the
  qubes-nat-accel fast path removed from VPN qubes; client DNS pinned
  to the active peer's resolver.
- `test/verify.sh`: exit address, DNS pinning, the kill test.
- Identity and ownership: named custom labels and icons, only-dom0
  creation policies, the created-by-wgq tag with adopt-or-refuse.
- Install path: verify the signed tag, bootstrap in a disposable,
  `airlock pull` as a reviewed diff, `airlock apply` step by step.
