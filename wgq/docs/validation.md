# Validating a release on a real machine

The test suite proves the parts that can be proved without Qubes: the
Python core, the deterministic build, the airlock's scan and receipt
logic. It cannot prove the dataplane, the Admin API grants, or the
qvm-firewall idioms — the shell tests are mock-shaped, they pin *which
calls are made*, not *whether the call is real* (a panic subcommand
that never existed passed those mocks for two releases). A run on a
real Qubes install is not ceremony; it is the only thing that
exercises the layer the harness structurally cannot.

This is the run sheet. Each checkpoint has an ID (**V1**–**V9**) so a
report can say "V6 failed" and mean something exact. Work top to
bottom; capture raw output as you go. How to file what you find:
[../CONTRIBUTING.md](../CONTRIBUTING.md).

## What to record — software, never hardware

wgq is software on Qubes OS. The machine's make and model determine
nothing about how it behaves, and naming your hardware only narrows
who a report could be about. **Leave hardware identity out.** Record
the software environment:

| Field | How to get it |
|---|---|
| Qubes OS release | `cat /etc/qubes-release` in dom0 |
| wgq version and tag/commit | `git describe --tags` in the checkout you installed from |
| Template base | `debian-13-minimal` unless you changed it |
| Provider | mullvad, ivpn, or self-hosted |
| Install path | fresh install, or updated from which version |
| `fzf` in dom0? | `command -v fzf` — it changes which picker you see |

## V1 — install or update

**Fresh:** in a disposable, `git verify-tag wgq-v0.3.0 && git checkout
wgq-v0.3.0`, then `sh bootstrap.sh wgq`; in dom0 `sudo airlock pull
<disp> wgq <repo>` and `sudo airlock apply wgq`.

**Update:** the same pull — **expect** it to fetch the repo's own
airlock first and, when it differs, show the diff and offer the
replacement before anything else; accept and watch it re-run itself.
**Expect** the apply plan to end with a `note` pointing at
`wgq restart`. Run `sudo wgq restart`; **expect** the plan printed,
dark clients named, one confirmation.

## V2 — baseline health

```
sudo wgq
sudo wgq doctor
```

**Expect** bare `wgq` to draw the health view (the tree) with a
`commands: wgq -h` hint, and doctor to print gutter rows (ok / note /
skip) with a closing tally. On failure, doctor prints its own fix
lines — capture them with the output.

## V3 — the migration *(new in 0.3.0; highest risk; upgrades only)*

If the machine still runs the pre-0.3.0 reserved zone:

```
sudo wgq zone rename wgq <name>
```

**Expect** the printed plan (clone → retag → rewire → remove →
converge), clients named as going dark, a typed-name confirmation —
and, the part to verify hardest, **keys and provider registration
survive**: `sudo wgq verify <name>` afterwards must pass without
re-provisioning. **Capture on failure:** the full output, plus whether
the new pair exists and the old pair is gone (`qvm-ls | grep wgq`).

## V4 — a zone, end to end

```
sudo wgq zone add work --color blue     # expect: colour named, zone up
sudo wgq credential <provider>
sudo wgq keygen work
sudo wgq pubkey work | sudo wgq provision --provider <p> --zone work
sudo wgq sync work                      # expect: the salt VERDICT, not the wall
sudo wgq switch work <peer>
sudo wgq firewall --zone work           # expect: the ask prompt names source and target
sudo wgq zone attach work <client>
```

## V5 — prove it leak-tight

```
sudo wgq verify work --kill-rounds 3
```

**Expect** check 1 (exit ≠ clearnet), 1b (STUN: the UDP exit equals
the tunnel exit), 2 (DNS pinned; arbitrary resolvers intercepted),
3 (kill test, three rounds, recovery proven each time), 4 (SKIP).
**This is the report that matters most — paste it whole, pass or
fail, after one redaction: the `clearnet` address is *your* ISP
address (verify says so in its own output). Every other address in the
run is the provider's.**

## V6 — panic's deny-all *(new: it works for the first time)*

```
sudo wgq panic -z work
qvm-firewall sys-fw-work list           # expect: EMPTY rule list (implicit drop)
qvm-start sys-wgq-work                  # expect: clients STAY dark
sudo wgq firewall --zone work           # deliberate recovery
```

Before 0.3.0 the "deny-all" silently installed a blanket *accept*. If
that `list` shows an accept rule, that is a real finding — capture it
exactly.

## V7 — the live views *(new)*

```
sudo wgq tree                            # rooted forest to sys-net, painted
sudo wgq logs work                       # merged journal, labeled by source
sudo wgq top                             # full-screen dashboard
```

With `top` on screen, run the kill test (or a `disconnect`) beside it:
**expect the drop counter to tick and say so in words.** Note the
number it reaches — it is the seal working, live.

## V8 — settings and routes

```
sudo wgq set work dns 10.64.0.1 && sudo wgq get work   # expect: layer named
sudo wgq set --global dns default
sudo wgq route list
sudo wgq route dom0-updates work        # then run an actual dom0 update through it
sudo wgq route dom0-updates default
```

## V9 — the desktop, every face

wgq's icons and colours render through two different pipelines — Qt
tools draw SVGs by file extension, GTK tools sniff file content — so a
bug can hide in one while the other looks fine (that exact split
concealed a real bug once). Check each surface:

- the **application menu**: wgq qubes show their cube icons
- **Qube Manager** (Qt): icons and rows for every wgq qube
- the **Qubes Update GUI** (GTK): the wgq template shows its icon
- **window borders and titles** of any open wgq qube terminal: the
  label colour is the one the zone was created with
- the **domains tray widget**: running wgq qubes listed with icons

**Expect** no blank icon anywhere. A blank on one surface but not
another is especially valuable — name the surface.

## Reporting

File what you found — pass or fail — following the issue requirements
in [../CONTRIBUTING.md](../CONTRIBUTING.md): the software-environment
table, the checkpoint IDs you ran, raw output untidied. A clean run is
worth filing too: it is one more machine this has run on, and that
count is the whole point. A **leak** — traffic reaching the clear when
a checkpoint says it must not — goes through private vulnerability
reporting instead: [../SECURITY.md](../SECURITY.md).
