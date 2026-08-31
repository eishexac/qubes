# Contributing

## The most useful thing you can send

**Output from real hardware.** This has never been run, and the two claims it
most depends on are unverified. If you have a Qubes 4.3 machine, either of
these is worth more than a patch:

1. What `qvm-firewall <qube> reset && qvm-firewall <qube> list` actually
   prints on a fresh qube. The emitted command block is derived from
   `qubesadmin/tools/qvm_firewall.py`, where `reset` installs a single
   `action=accept` rule. If the real output differs, the block is wrong and
   so is the README.

2. Whether the `admin.vm.firewall.Set` grant in `dom0/30-wgq.policy` works as
   written, and whether the `ask` prompt names the source and target qube
   the way the file claims.

Paste the raw output into an issue. Do not tidy it up.

## Running the checks

```sh
make check     # compile, sh -n, shellcheck, unit tests, Salt render
make build     # produces dist/wgq
```

`make check` will tell you if `shellcheck` or `pyyaml`/`jinja2` are missing
and skip those steps. CI installs all three, so a patch that passes locally
without them can still fail there. Install them:

```sh
sudo apt install shellcheck        # or: pip install shellcheck-py
pip install pyyaml jinja2
```

## Style

- **Template scripts are POSIX `sh`**, not bash. They run at qube start in
  the packet-filtering path, and being readable end to end in one sitting is
  a feature. `shellcheck -s sh` must be clean.
- **Python is standard library only.** The qube that holds the account
  credential should need nothing from pip. This is not negotiable for a
  convenience; if you need a dependency, open an issue first.
- Comments explain *why*, especially where the code looks odd. Most of the
  odd-looking decisions here have an upstream source behind them, and
  `DESIGN.md` cites it.

## Things that must stay true

A patch that breaks any of these will be declined regardless of what else it
does:

- **No private key leaves the qube that generated it.** `wgq-mgmt` handles
  public keys only, and emits configs containing `__PRIVATE_KEY__`.
- **No secrets in Salt.** Salt routes execution through a management
  disposable VM with full control of the target, so anything in a state file
  transits it.
- **No `accept` in `custom-forward`.** It terminates the `qubes` forward
  chain and skips the trailing `oifgroup 2 counter drop` that keeps
  unsolicited inbound off client qubes. Drops and non-terminal statements
  only.
- **Nothing partly correct gets written.** A provider response that cannot be
  fully validated raises; it never yields a config or an allowlist with a
  field guessed or defaulted.
- **No check that cannot fail.** If a step is skipped, it is reported as
  skipped and the run exits non-zero. `cmd || echo skipped` is a bug, not a
  fallback.

## Branch

The default branch is `main`. Base patches on it, and expect them to go through a pull request with the checks green.
