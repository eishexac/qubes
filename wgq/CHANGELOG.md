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
- `wgq top <zone>` (`--once` for scripts): the tunnel live — handshake
  age, transfer rates, and the kill-switch drop counter, the number
  that says the seal is working, not just installed: every packet a
  client tried to push outside the tunnel, counted as it happens. One
  streaming loop runs inside the qube; dom0 only renders.
- `wgq tree`: the whole topology on one screen — every zone as a
  painted chain (uplink → VPN qube → firewall → clients) with its
  tunnel state read from the qube that knows, the autoconnect stance,
  chained zones marked, and the system routes as the footer.
  Read-only; halted qubes are never started to be asked.
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

- The airlock updates itself at pull time: `airlock pull` fetches the
  repo's own airlock first and, when it differs from the installed
  tool, shows the diff and offers to install it before anything else —
  one accepted yes re-runs the pull with the new tool. The
  unknown-verb refusal points there.
- Bare `wgq` is the health view — the tree itself, with a
  `commands: wgq -h` hint — because the naked command should answer
  "is everything okay"; usage moved to `-h`.
- `-n` (`--dry-run`), accepted anywhere: the qvm-run-framed verbs print
  exactly what would run and execute nothing (`credential` reads no
  secret under it); the dom0-native verbs that already print a plan
  before asking say so instead of faking a second dry layer.
- `docs/validation.md`: the hardware run sheet — nine referenceable
  checkpoints (V1–V9) from install to the desktop's every icon
  surface, with the expected result beside each step. CONTRIBUTING
  gains issue requirements (software environment only — hardware
  identity is asked out — raw output, a checkpoint or command per
  finding), and the repository gains matching issue templates.
- `wgq --version` (`-V`) in dom0, answered from the reviewed tree —
  the same string the in-qube CLI prints, no qube started to ask.
  (`-v` stays verbose, on the verbs that have a wall to hide.)
- Bash completion for the dom0 entrypoint: verbs, live zone names, and
  the sub-verbs of `zone`/`route`/`set`; installed by the CLI state,
  removed by uninstall.

### Security

- `wgq panic`'s upstream deny-all never worked: it called a
  `qvm-firewall set-policy` subcommand that does not exist (upstream
  has exactly add/del/list/reset), the error was silenced, and the
  harness mock accepted any subcommand — so the tests enshrined the
  bug while the kill alone took zones dark. The persistent block is
  now the real idiom (reset, then delete the accept-all rule 0,
  leaving the implicit drop), the mock rejects unknown subcommands
  like the real tool, and the tests assert the real calls. Found by
  external review.
- `sync` installed the received conf text verbatim (after validating
  its sidecar and origin placeholder) — and wg-quick executes
  PostUp/PreUp lines as root, so a compromised wgq-mgmt could have run
  code in every zone qube at the next tunnel start. The installed conf
  is now re-rendered from the validated Peer alone; mgmt's reach is
  capped at what the validators admit. The threat model now states
  mgmt's actual trust position. Found by external review.

### Fixed

- The rest of the external review: `uninstall` resets system routes
  **before** removing zones (qubesd refuses to remove a qube a global
  pref references; the order was backwards) and `zone remove` refuses
  up front, fix named, when updatevm/clockvm/default_netvm points at
  the zone. The template now ships `qubes-core-agent-dom0-updates`, so
  `route dom0-updates <zone>` actually serves dom0 updates (the verb
  says what other targets need). `30-wgq.policy`'s header stops
  claiming a footprint of "no scripts"; the creation policy is marked
  optional in the plan and install doc for sys-gui/admin setups; the
  Status chronology separates the 0.1.0 run (2026-09-04) from the
  0.2.0 validation (2026-09-06); stale reserved-zone comments across
  the dispatcher, cli.py, wg-zone.sls and wgq-ctl now describe the
  deprecation, and wgq-ctl requires a zone instead of defaulting to
  one.
- External review, all findings fixed: the root README and
  CONTRIBUTING still claimed wgq had never run on hardware — both now
  tell the truth, and CONTRIBUTING's most-wanted list asks for what is
  actually still unobserved (Mullvad live, server retirement, any
  machine that is not the author's). The airlock vets an incoming
  archive by listing **before** extraction (regular files and
  directories only, no absolute or dot-dot paths, `--no-same-owner`) —
  root in dom0 no longer leans on tar's own symlink handling against a
  hostile qube; a dead qube now reports as a failed transfer instead
  of "payload is not a readable tar"; an oversize payload refuses
  loudly at the same gate; a dead pre-rename self-update block is
  gone. Approval receipts now hash file **modes** along with contents,
  so a post-approval `chmod +x` is drift and is refused — note: the
  first pull after updating the airlock re-approves each project once,
  since old receipts used the contents-only hash.

- `wgq uninstall` resets system routes (updatevm, clockvm,
  default_netvm) and clears the global settings before removing zones —
  a qube still serving as updatevm cannot be removed, so an uninstall
  after `wgq route` would have jammed halfway.

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
- `wgq verify` gains an origin advisory (check 1c): it compares the
  exit's autonomous system against your clearnet's and flags a match —
  a sealed tunnel to a same-ISP exit barely moves your apparent origin,
  a real traffic-correlation weakness in the *choice* of server. It is
  an ADVISORY, loud but never part of the leak-tight pass/fail verdict
  (the seal is fine; the choice is the issue). AS numbers come from
  Team Cymru's DNS interface via the stdlib probe.
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
