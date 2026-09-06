# Install

Read every file before it enters dom0. There are three, and they are all
text: two Salt states and two lines of qrexec policy.

The short path: in a disposable, verify and pin the signed release
(`gpg --locate-keys hexac@existin.space`, check the fingerprint against the repository root's
SECURITY.md, `git verify-tag wgq-v0.1.0 && git checkout wgq-v0.1.0` —
see the collection README), run `sh bootstrap.sh wgq` at the repository
root, then `airlock pull` and `airlock apply wgq` in dom0. The steps
below are the manual equivalent, and exactly what `apply` runs for you,
one confirmed step at a time.

```sh
# the whole collection, or sparse-checkout just this project -- see the
# repository README; wgq/ is self-contained either way
git clone <the qubes repo> && cd qubes/wgq
make                          # builds dist/wgq, one ~100 KB file
make check                    # syntax, shellcheck, unit tests, Salt render
```

The build is deterministic: the same tree produces byte-identical output, so
`sha256sum dist/wgq` is comparable across machines. A release's attached
artifact is only ever a convenience -- rebuild and compare instead of
trusting it.

**1. Copy the formula into dom0** (from the qube holding the clone):

```sh
# in dom0
qvm-run --pass-io <qube> 'tar -C /path/to/qubes -c wgq' | sudo tar -C /srv/salt -x
less /srv/salt/wgq/wg-template.sls
less /srv/salt/wgq/wg-mgmt.sls
less /srv/salt/wgq/dom0/30-wgq.policy
```

**2. Build the template:**

```sh
sudo qubesctl --show-output state.apply wgq.wg-template
sudo qubesctl --skip-dom0 --targets=debian-13-wgq --show-output \
    state.apply wgq.wg-template
```

The first invocation clones `debian-13-minimal` and bootstraps
`qubes-mgmt-salt-vm-connector` over `qvm-run`. That step cannot be a Salt
state: it is the package that makes a qube salt-manageable.

**3. Create the management qube:**

```sh
sudo qubesctl --show-output state.apply wgq.wg-mgmt
```

**4. Create a zone** — one deliberate command per identity, whenever you
need one (zones are lifecycle, not installation):

```sh
sudo wgq zone add work
```

That builds `sys-wgq-work` + `sys-fw-work`, tags and marks them — and the
new VPN qube **fails closed from birth**: clients behind it get nothing
until the first `wgq switch` succeeds. Later, point clients at the zone
with:

```sh
sudo wgq zone attach work <qube>
```

**5. Optionally install the policy** that lets `wgq firewall` apply the
allowlist for you:

```sh
sudo cp /srv/salt/wgq/dom0/30-wgq.policy /etc/qubes/policy.d/30-wgq.policy
```

Without it, `wgq firewall` prints a `qvm-firewall` block for you to paste.
With it, the same rules are applied by `admin.vm.firewall.Set` — one atomic
call, no rule numbers to miscount — and the default `ask` action raises a
dom0 confirmation each time. Read the file; it explains the trade.

**Icons blank after installing? Log out and back in, once.** The install
drops the wgq icons into a GUI session that is already running, and a
running menu does not rescan the icon theme — so the wgq qubes show blank
until the next login. This is a one-time step: after that login every zone
you create shows its cube immediately (the icon set covers both names a
zone qube passes through as it gains its service mark, so nothing blanks at
creation). If icons are *still* blank after a relogin, the files did not
land — re-apply just the identity with `sudo qubesctl state.apply
wgq.wg-icons` and check `/usr/share/icons/hicolor/scalable/apps/` for the
six `*-wgq*.svg` files.

---

## Uninstall

Full teardown is `sudo wgq uninstall`: zones first
(refusing while clients are attached), then wgq-mgmt, template, the wgq
labels and icons, policy — each step confirmed.

---

## Notes

The Qubes Salt API is provisional and can change between minor releases. The
states here are written for 4.3.

`qubes-core-agent-passwordless-root` is installed because minimal templates
omit it. It means anything running as the user in these qubes can become
root. For a qube with no user sessions that provides network to others, that
is an acceptable trade; if it is not acceptable to you, drop it from
`wg-template.sls` and use `qvm-run -u root` from dom0 instead.

`make check` runs `shellcheck` when it is installed. Install it before
sending patches that touch shell.
