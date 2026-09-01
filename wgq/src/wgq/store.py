"""The zone qube's own state, under /rw/config/wg.

Everything here runs inside sys-wgq-<zone>.  This is the only module that
ever handles a private key, and the key never leaves the qube that made it:
wgq-mgmt is given the public half and emits configs holding the literal
string ``__PRIVATE_KEY__``, which is substituted here.

Layout::

    /rw/config/wg/                  0755  (directories readable; secrets
        private.key                 0600   carry their own 0600)
        public.key                  0644
        peers/<name>.conf           0600
        peers/<name>.meta           0644
        wg0.conf -> peers/<name>.conf     the active peer, and the only
                                          record of which one that is

The directories are world-readable on purpose: ``wgq pubkey`` and ``wgq
status`` are run as the ordinary qube user (the printed provisioning
pipeline pipes ``qvm-run -p ... 'wgq pubkey'``), and a 0700 root directory
made them lie -- "no keypair yet" with the key sitting right there.
Everything secret is an 0600 file; the directory mode never carried the
secrecy, and in a qube with passwordless-root it could not have.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

from .errors import LayoutError, UsageError
from .peers import PLACEHOLDER, Peer, PeerDir, _write
from .validate import require_peer_name

WG_DIR = Path("/rw/config/wg")
PEERS_DIR = WG_DIR / "peers"
LINK = WG_DIR / "wg0.conf"
PRIVATE_KEY = WG_DIR / "private.key"
PUBLIC_KEY = WG_DIR / "public.key"
RETIRED_KEY = WG_DIR / "private.key.retired"
STATE_FILE = Path("/run/wgq/state")
TUN = "wg0"
UNIT = "wg-tunnel.service"


def peer_dir() -> PeerDir:
    return PeerDir(PEERS_DIR, dir_mode=0o755)


def looks_like_zone_qube() -> bool:
    return Path("/rw/config").is_dir()


def require_zone_qube() -> None:
    if not looks_like_zone_qube():
        raise UsageError(
            "this command must run inside the VPN qube (sys-wgq-<zone>); "
            "/rw/config does not exist here"
        )


def require_root() -> None:
    if os.geteuid() != 0:
        raise UsageError("this command writes /rw/config/wg and must run as root (use sudo)")


def ensure_dirs() -> None:
    WG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(WG_DIR, 0o755)
    peer_dir().ensure()


# -- keys -------------------------------------------------------------------


def _wg(*args: str, stdin: bytes | None = None) -> bytes:
    try:
        proc = subprocess.run(
            ["wg", *args],
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        raise LayoutError("wireguard-tools is not installed (no `wg` binary)") from None
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise LayoutError(f"wg {' '.join(args)} failed: {detail}")
    return proc.stdout


def has_key() -> bool:
    return PRIVATE_KEY.is_file()


def keygen(*, force: bool = False) -> str:
    """Create the keypair if absent and return the public key.

    Never regenerates silently.  A new key orphans the one registered with
    the provider, which keeps consuming a device slot on an account that
    probably has five.
    """
    require_root()
    ensure_dirs()

    if has_key() and not force:
        return public_key()

    if has_key() and force:
        if RETIRED_KEY.exists():
            raise LayoutError(
                f"{RETIRED_KEY} already exists, so a previous key was retired and "
                "never dealt with.\nRevoke it at the provider, then remove that file:\n"
                f"    wgq revoke --provider <p> --pubkey $(wg pubkey < {RETIRED_KEY})\n"
                f"    sudo rm {RETIRED_KEY}"
            )
        os.replace(PRIVATE_KEY, RETIRED_KEY)

    old_umask = os.umask(0o077)
    try:
        secret = _wg("genkey").strip()
        _write(PRIVATE_KEY, secret.decode("ascii") + "\n", 0o600)
    finally:
        os.umask(old_umask)

    return public_key()


def public_key() -> str:
    """The qube's public key.

    As root, derived fresh from the private key and re-written to
    public.key, so the 0644 copy can never go stale.  Unprivileged, the
    private key is unreadable by design, so answer from that 0644 copy --
    and say exactly which situation the caller is in when it is missing,
    because "no keypair yet" when the key exists sends the user in the
    wrong direction.
    """
    if os.geteuid() == 0:
        if not has_key():
            raise LayoutError("no keypair yet; run 'sudo wgq keygen' first")
        secret = PRIVATE_KEY.read_bytes()
        pub = _wg("pubkey", stdin=secret).decode("ascii").strip()
        _write(PUBLIC_KEY, pub + "\n", 0o644)
        return pub

    try:
        pub = PUBLIC_KEY.read_text(encoding="ascii").strip()
    except FileNotFoundError:
        if has_key():
            raise LayoutError(
                f"{PUBLIC_KEY} is missing; run 'sudo wgq pubkey' once to rewrite it"
            ) from None
        raise LayoutError("no keypair yet; run 'sudo wgq keygen' first") from None
    except PermissionError:
        raise LayoutError(f"cannot read {PUBLIC_KEY}; re-run with sudo") from None
    if not pub:
        raise LayoutError(f"{PUBLIC_KEY} is empty; run 'sudo wgq pubkey' to rewrite it")
    return pub


def _read_private_key() -> str:
    secret = PRIVATE_KEY.read_text(encoding="ascii").strip()
    if not secret:
        raise LayoutError(f"{PRIVATE_KEY} is empty")
    return secret


# -- peers ------------------------------------------------------------------


def apply_bundle(bundle: Path) -> list[str]:
    """Install every peer in *bundle* into this qube.

    Validates the whole bundle before writing anything, so a malformed peer
    cannot leave the qube holding half an update.
    """
    require_root()
    require_zone_qube()
    if not has_key():
        raise LayoutError("no keypair yet; run 'sudo wgq keygen' first")

    source = PeerDir(bundle)
    names = source.names()
    if not names:
        raise UsageError(f"no peer configs found in {bundle}")

    staged: list[tuple[Peer, str]] = []
    for name in names:
        peer = source.load(name)
        text = source.conf_path(name).read_text(encoding="ascii")
        if PLACEHOLDER not in text:
            raise LayoutError(
                f"{name}.conf does not contain {PLACEHOLDER}. wgq only installs "
                "configs it generated; a config carrying someone else's key is refused."
            )
        staged.append((peer, text))

    ensure_dirs()
    secret = _read_private_key()
    installed = []
    for peer, text in staged:
        target = peer_dir()
        _write(target.conf_path(peer.name), text.replace(PLACEHOLDER, secret), 0o600)
        _write(target.meta_path(peer.name), peer.meta_text(), 0o644)
        installed.append(peer.name)
    return installed


def active() -> str | None:
    try:
        target = os.readlink(LINK)
    except OSError:
        return None
    name = Path(target).name
    if name.endswith(".conf"):
        name = name[: -len(".conf")]
    try:
        return require_peer_name(name)
    except Exception:  # noqa: BLE001 - a malformed link is "no active peer"
        return None


def set_active(name: str) -> None:
    """Point wg0.conf at *name* and restart the tunnel.

    The unit is stopped *before* the symlink moves.  ExecStop resolves the
    link too, so restarting afterwards would tear down the new interface
    name and leave the old tunnel up.
    """
    require_root()
    require_zone_qube()
    require_peer_name(name)

    target = peer_dir().conf_path(name)
    if not target.is_file():
        known = ", ".join(peer_dir().names()) or "none"
        raise UsageError(f"no peer named {name!r}. Installed peers: {known}")

    _systemctl("stop", UNIT, check=False)

    tmp = LINK.with_name(LINK.name + ".tmp")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    os.symlink(os.path.join("peers", f"{name}.conf"), tmp)
    os.replace(tmp, LINK)

    _systemctl("start", UNIT, check=True)


def _systemctl(*args: str, check: bool = True) -> None:
    try:
        proc = subprocess.run(
            ["systemctl", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    except FileNotFoundError:
        raise LayoutError("systemctl not found") from None
    if check and proc.returncode != 0:
        detail = proc.stdout.decode("utf-8", "replace").strip()
        raise LayoutError(f"systemctl {' '.join(args)} failed: {detail}")


# -- status -----------------------------------------------------------------


def firewall_state() -> str:
    """What 50-wgq recorded on its last run."""
    try:
        return STATE_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown (50-wgq has not run in this boot)"


def tunnel_up() -> bool:
    proc = subprocess.run(
        ["ip", "link", "show", TUN],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return proc.returncode == 0


def handshake_age() -> int | None:
    """Seconds since the newest handshake; -1 if none ever; None if unreadable."""
    try:
        out = _wg("show", TUN, "latest-handshakes").decode("ascii", "replace")
    except LayoutError:
        return None
    newest = 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            newest = max(newest, int(parts[1]))
    if newest == 0:
        return -1
    return max(0, int(time.time()) - newest)


def tunnel_state() -> str:
    """What the tunnel is actually doing, not just whether wg0 exists.

    An existing interface says nothing about the peer answering, so a bare
    'up' would overclaim.  Reading handshakes needs CAP_NET_ADMIN, hence
    the unprivileged fallback wording instead of a guess.
    """
    if not tunnel_up():
        return "DOWN"
    age = handshake_age()
    if age is None:
        return "up (handshake unknown; run as root for detail)"
    if age < 0:
        return "up, NO HANDSHAKE YET"
    return f"up (last handshake {age}s ago)"
