# Using wgq

Provisioning, zones, the connection lifecycle, and the emergency stop.
Prove the result with [verify.md](verify.md).

## Use

**Once per zone qube**, inside it:

```sh
sudo wgq keygen                 # prints the public key; never regenerates silently
```

**In `wgq-mgmt`:**

```sh
# /rw/config is root's; the file must be user's (the CLI runs as user)
sudo install -m 600 -o user -g user /dev/null /rw/config/mullvad-account
printf '%s\n' <16-digit account> > /rw/config/mullvad-account

wgq servers --provider mullvad --filter se
wgq provision --zone work --provider mullvad --filter se-mma --count 2 \
    --pubkey <the key from keygen>
qvm-copy ~/.local/share/wgq/zones/work
```

**Back in the zone qube:**

```sh
sudo wgq apply ~/QubesIncoming/wgq-mgmt/work/peers
sudo wgq switch se-mma-wg-001
wgq status
```

**And in `wgq-mgmt`:**

```sh
wgq firewall --zone work
```

Then point a client at `sys-fw-work` and run the verifier from it.

### Your own server, or any provider without an API

The data model does not care where a peer came from. Generate the key in the
qube, add the public half to your server, then record the rest:

```sh
wgq peer add --zone home --name home-gw \
    --server-pubkey <your server's public key> \
    --endpoint 203.0.113.5:51820 \
    --address 10.10.0.2 \
    --dns 10.10.0.1
```

Or import a config you already have:

```sh
wgq peer import --zone home --name home-gw ~/wg0.conf --dns 10.10.0.1
```

Import refuses a config carrying a real `PrivateKey`, because moving one
through the management qube would defeat the whole key-handling design. It
lifts the `DNS =` line into metadata, where it becomes a DNAT rule that
actually pins clients — `wg-quick` could not apply it anyway, since Debian
minimal ships no `resolvconf`.

A private endpoint (your own box on a LAN) needs `--allow-private-endpoint`.
Provider-sourced endpoints are always required to be publicly routable.

---

## Zones

`wgq zone`, in dom0, is the whole lifecycle. The `wgq` entrypoint is a
symlink into the reviewed tree (installed by `wgq.wg-cli`), so the file
that runs is always the one the airlock approved:

```
sudo wgq zone add <zone> [--upstream <netvm>] [--attach <qube>[,<qube>...]]...
sudo wgq zone attach <zone> <qube>    sudo wgq zone detach <qube> [netvm]
sudo wgq zone list                    sudo wgq zone remove <zone>
sudo wgq zone rename <old> <new>
sudo wgq zone add media --color blue
```

Each zone wears a console colour — picked with `--color`, or the first
free one from the 12-colour palette — unique across zones, painting the
zone's name in `zone list` and the picker. Pipes and `NO_COLOR` never
see an escape code.

`rename` migrates a zone under a new name — clone, retag, rewire
(clients follow), remove the old pair, converge. The zone is dark for
the duration and the mgmt bundle moves with it, so the registered
provider key survives. It exists chiefly to migrate the deprecated
reserved zone: `sudo wgq zone rename wgq <name>`.

(`sudo` is part of every dom0 `wgq` command, not just the destructive
ones: the entrypoint is a symlink into `/srv/salt`, which Qubes keeps
root-only, so a user shell cannot even see the target — deliberate,
since the approved tree stays root's.)

The same entrypoint reaches the other qubes without opening their
terminals -- it frames a `qvm-run` you could type yourself, and prints
it before running: `wgq provision ...` (and every other management
verb) lands in wgq-mgmt; `wgq [-z <zone>] keygen|pubkey|apply|switch|
status` lands in the zone's VPN qube named by the positional (or
picked) zone. Two dom0-only verbs close the flow's remaining gaps:
`wgq credential <provider>` stores the account id into wgq-mgmt (typed
hidden in dom0, piped straight into the qube, never on any other
disk), and `wgq sync` streams the peer bundle from wgq-mgmt into the
zone's VPN qube and applies it -- no qvm-copy dance. The whole
lifecycle, from dom0:

```sh
sudo wgq credential ivpn
sudo wgq keygen
sudo wgq pubkey work | sudo wgq provision --provider ivpn --zone work
sudo wgq sync
sudo wgq switch <peer>
sudo wgq firewall --zone work
sudo wgq verify --kill-rounds 3
sudo wgq doctor
```

### Connection lifecycle

The zone is a positional on every zone verb — `wgq disconnect work`,
`wgq verify work`, `wgq set work dns <ip>` (`up`/`down` alias
connect/disconnect). Name no zone and, on a terminal, a picker opens —
always, even with one zone: choosing from a one-item list is explicit,
a guess is not — and per-zone verbs multi-select. Without a terminal
the command refuses and lists the zones. `-z <zone>` works anywhere on
the line, unchanged.

After an update that changed the template, running wgq qubes keep the
old code until restarted: `sudo wgq restart` offers the cycle — plan
first, dark clients named, one confirmation, decline means you do it
by hand. `sudo wgq restart <zone>` bounces one zone's pair.

The tunnel connects at boot by default. Both halves are yours to drive:

```sh
sudo wgq disconnect work             # zone goes DARK -- kill switch stays,
                                     # clients get nothing, never clear traffic
sudo wgq connect work                # tunnel up again, state read back
sudo wgq set work autoconnect off    # boot sealed; configure first, then connect
sudo wgq set work dns 10.64.0.1      # pin client DNS to a chosen resolver
sudo wgq set --global dns 10.64.0.1  # default for every zone without its own
sudo wgq get work                    # settings (with the layer that answered)
```

Settings are layered: a zone override beats a global default beats the
built-in default, and `get` names the layer every value came from.
An explicit value is stored even when it matches the layer below —
`set autoconnect on` on one zone beats a global `off` — and
`set <key> default` clears the named layer so the one beneath answers
again. The
stored settings (qubes features, on the zone qube or dom0) are the
truth; what the dataplane reads is a copy pushed at `set` and
`connect`, and `wgq doctor` fails when the two drift. A newborn zone
inherits the globals from its first boot.

`disconnect` is a pause button, not a bypass: the kill switch is
installed by the firewall script regardless of tunnel state. With
autoconnect off the zone boots exactly like an unconfigured qube --
sealed, forwarding refused -- until an explicit `connect`.

A custom resolver is reached *through the tunnel*: if it does not
answer there, clients get no DNS rather than a leak, and an unusable
override falls back to the provider pin, never to no pin. An
off-provider resolver is a fingerprinting and trust trade-off; the
provider default avoids it.

The only qubes whose netvm ever changes are the ones you typed — there is
no discovery and no "all"; a sweep of "networked qubes" would eventually
rewire plumbing it does not understand. `add` asks exactly one question
of its own (attach the qube that shares the zone's name?), moving a qube
between zones always requires a yes, and `remove` refuses while any
client is still attached. The tool imposes no topology — all of these
are legitimate:

- **one zone, everything attached** (`--attach work,media,...` — a typed
  list, not a discovered one): one peer, one exit, the simple mental model
- **one zone per identity**: the reason zones exist
- **a dedicated infra zone** for system traffic, separate from identities

Every zone is named — `zone add` requires it, and there is no default
to reach for. An install from before 0.3.0 that still runs the reserved
zone `wgq` (bare `sys-wgq` + `sys-fw-wgq`) keeps working while
deprecated: migrate it with `zone rename wgq <name>`; reading the bare
name ends in 0.4.0.

`sudo wgq top <zone>` watches one tunnel live — handshake age,
transfer rates, and the kill-switch drop counter ticking up the moment
anything tries to leave outside the tunnel (`--once` for scripts).

`sudo wgq tree` draws the whole topology on one screen: every zone as
a painted chain with its live tunnel state, clients, and the system
routes as the footer.

**System services** are a consumer decision, one grammar:

```sh
sudo wgq route list                    # every role, where it goes, why
sudo wgq route dom0-updates work
sudo wgq route template-updates work   # prints the policy line, installs on yes;
                                       # Whonix templates keep their Tor route
sudo wgq route new-qubes work
sudo wgq route clock work              # allowed, but argued with (see below)
sudo wgq route dom0-updates default    # back to stock
```

Tor gateways are ordinary clients: `sudo wgq zone attach work sys-whonix`.

Clock sync carries a paradox worth understanding before routing it:
WireGuard re-handshakes can fail on a badly wrong clock, and a clock
source *behind* the tunnel can then never fix the clock — a cold boot
with a drifted RTC can wedge until you route clock elsewhere. The verb
says so and asks twice.
Everything routed through a zone inherits fail-closed — tunnel down means
those services stop until `wgq switch` succeeds.

**The emergency stop.** `sudo wgq panic` takes every zone dark at once
(`sudo wgq panic -z <zone>` for one): straight from dom0, no prompt, no
qube code trusted, it sets a deny-all firewall on each zone's firewall
qube and then kills the VPN qube. The deny-all is enforced upstream in
sys-fw's own netvm, so it holds even against a fully compromised zone,
and it **persists across restarts** — restarting a qube cannot bring the
tunnel back behind your back. The kill is instant: the only route ceases
to exist, so client packets have nowhere to go. Recovery is deliberate,
never automatic — `qvm-start` the VPN qube, then `wgq firewall --zone
<zone>` to restore the real allowlist (the command prints these lines
for each zone it stops).
