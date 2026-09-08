# Contributing

## The most useful thing you can send

**Output from real hardware that is not the author's.** wgq has run end
to end on exactly one machine (Qubes 4.3, live IVPN account — see the
README's Status). What is still unobserved is worth more than a patch:

1. The Mullvad backend against a live account (it is source-verified
   only).
2. A server retirement mid-life: what `sync`/`switch` do when a
   provisioned peer disappears from the provider.
3. Any run on hardware that is not the author's — especially
   `sudo wgq verify --kill-rounds 3` output, pass or fail. A report
   that arrives as a failing check is worth two that arrive as prose.

Paste the raw output into an issue. Do not tidy it up.

## Filing an issue

Every issue needs three things; the templates ask for them:

1. **The software environment, never the hardware.** Qubes release,
   wgq tag or commit, template base, provider, and whether `fzf` is in
   dom0 (the table in
   [docs/validation.md](docs/validation.md#what-to-record--software-never-hardware)).
   wgq is software on Qubes OS: the machine's make and model determine
   nothing about its behavior, and naming hardware only narrows who a
   report could be about. Reports naming hardware will be asked to
   edit it out.
2. **Raw output, untidied.** The exact bytes of the failing command —
   a `verify` check gone red, a `doctor` FAIL with its printed fix, a
   refusal message. A failing check is worth two pages of prose; a
   screenshot of text is worth less than the text.
3. **A checkpoint or a command, not a vibe.** Validation findings name
   the checkpoint ID (V1–V9 in
   [docs/validation.md](docs/validation.md)); bug reports name the
   exact command and what was expected instead. One finding per issue.

Two hard rules: a **leak** — traffic reaching the clear when the
design says it must not — goes through private vulnerability
reporting ([SECURITY.md](SECURITY.md)), never a public issue; and
never paste an account number, a private key, or the `clearnet`
address `verify` prints — that one is *your* ISP address, and the
output says so beside it (everything else it prints belongs to the
provider). wgq prints no keys or account numbers itself, but a
hand-run `wg show` might.

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
