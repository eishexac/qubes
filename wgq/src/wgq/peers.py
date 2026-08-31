"""On-disk representation of a peer.

The same directory shape is used in two places:

  sys-vpn-<zone>   /rw/config/wg/peers/
                   configs with the real private key substituted in

  wgq-mgmt         ~/.local/share/wgq/zones/<zone>/peers/
                   the record of what was handed out, placeholder intact

Keeping the resolver and endpoint in a ``.meta`` file beside each config is
what removes the last hand-edited value from the design: the firewall script
reads the resolver for whichever peer is active, and `wgq firewall` builds
the allowlist from the union of the endpoints, so the rules and the configs
cannot drift out of agreement.

Nothing in this module ever writes a private key.  Substitution happens in
the zone qube, in store.py.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from .errors import LayoutError
from .validate import (
    require_peer_name,
    require_port,
    require_tunnel_address,
    require_unicast_ipv4,
    require_wg_key,
)

PLACEHOLDER = "__PRIVATE_KEY__"

CONF_TEMPLATE = """\
# wgq: generated for {name} ({provider})
# The private key is substituted locally inside the VPN qube. Nothing that
# has seen the secret half of this keypair produced this file.
#
# Deliberately absent:
#   DNS =        wg-quick applies it via resolvconf, which Debian minimal
#                does not ship. Client DNS is pinned by nftables instead.
#   IPv6         Qubes disables it unless every qube in the chain opts in;
#                a mismatch breaks connectivity or leaks.
[Interface]
PrivateKey = {private_key}
Address = {address}

[Peer]
PublicKey = {server_pubkey}
AllowedIPs = 0.0.0.0/0
Endpoint = {endpoint}
"""

_META_KEYS = (
    "provider",
    "address",
    "server_pubkey",
    "endpoint_ip",
    "endpoint_port",
    "dns",
)


@dataclass(frozen=True)
class Peer:
    """Everything wgq knows about one server, minus key material."""

    name: str
    provider: str
    address: str
    server_pubkey: str
    endpoint_ip: str
    endpoint_port: int
    dns: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "name", require_peer_name(self.name))
        object.__setattr__(
            self, "address", require_tunnel_address(self.address, f"{self.name} address")
        )
        object.__setattr__(
            self,
            "server_pubkey",
            require_wg_key(self.server_pubkey, f"{self.name} server public key"),
        )
        # Unicast rather than strictly public: Server enforces the public
        # rule on everything a provider returns, but a peer the user added
        # by hand may point at their own server on a LAN address.
        object.__setattr__(
            self,
            "endpoint_ip",
            require_unicast_ipv4(self.endpoint_ip, f"{self.name} endpoint"),
        )
        object.__setattr__(
            self, "endpoint_port", require_port(self.endpoint_port, f"{self.name} port")
        )
        # Unicast, not require_public_ipv4: an in-tunnel resolver is private
        # by design (Mullvad 10.64.0.1, IVPN 172.16.0.1). Only the endpoint,
        # which goes into a firewall allowlist, has to be globally routable.
        # But it does have to be something a DNAT rule can sensibly point
        # at, which multicast, loopback and 0.0.0.0 are not.
        object.__setattr__(
            self, "dns", require_unicast_ipv4(self.dns, f"{self.name} resolver")
        )
        if not self.provider or not self.provider.isalnum():
            raise LayoutError(f"{self.name}: unusable provider name {self.provider!r}")

    @property
    def endpoint(self) -> str:
        return f"{self.endpoint_ip}:{self.endpoint_port}"

    def conf_text(self, private_key: str = PLACEHOLDER) -> str:
        return CONF_TEMPLATE.format(
            name=self.name,
            provider=self.provider,
            private_key=private_key,
            address=self.address,
            server_pubkey=self.server_pubkey,
            endpoint=self.endpoint,
        )

    def meta_text(self) -> str:
        values = {
            "provider": self.provider,
            "address": self.address,
            "server_pubkey": self.server_pubkey,
            "endpoint_ip": self.endpoint_ip,
            "endpoint_port": str(self.endpoint_port),
            "dns": self.dns,
        }
        return "".join(f"{key}={values[key]}\n" for key in _META_KEYS)

    @classmethod
    def from_meta(cls, name: str, text: str) -> "Peer":
        values: dict[str, str] = {}
        for lineno, line in enumerate(text.splitlines(), start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep:
                raise LayoutError(f"{name}.meta:{lineno}: not a key=value line: {line!r}")
            values[key.strip()] = value.strip()

        missing = [key for key in _META_KEYS if key not in values]
        if missing:
            raise LayoutError(
                f"{name}.meta is missing {', '.join(missing)}; refusing to use a partial peer"
            )
        return cls(
            name=name,
            provider=values["provider"],
            address=values["address"],
            server_pubkey=values["server_pubkey"],
            endpoint_ip=values["endpoint_ip"],
            endpoint_port=int(values["endpoint_port"]),
            dns=values["dns"],
        )


class PeerDir:
    """A directory of ``<name>.conf`` + ``<name>.meta`` pairs.

    ``dir_mode`` defaults to private: in wgq-mgmt the records live in the
    user's own home and nothing else needs to read them.  The zone qube
    passes 0o755 instead, so that unprivileged ``wgq status`` can list peers
    and read metadata; everything secret in there is file-mode 0600 anyway.
    """

    def __init__(self, root: Path, *, dir_mode: int = 0o700) -> None:
        self.root = Path(root)
        self.dir_mode = dir_mode

    def ensure(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, self.dir_mode)

    def names(self) -> list[str]:
        if not self.root.is_dir():
            return []
        names = []
        for entry in sorted(self.root.iterdir()):
            if entry.suffix == ".conf" and entry.is_file():
                names.append(entry.stem)
        return names

    def conf_path(self, name: str) -> Path:
        return self.root / f"{require_peer_name(name)}.conf"

    def meta_path(self, name: str) -> Path:
        return self.root / f"{require_peer_name(name)}.meta"

    def load(self, name: str) -> Peer:
        path = self.meta_path(name)
        try:
            text = path.read_text(encoding="ascii")
        except FileNotFoundError:
            raise LayoutError(f"no metadata for peer {name!r} at {path}") from None
        except UnicodeDecodeError:
            raise LayoutError(f"{path} contains non-ASCII data") from None
        return Peer.from_meta(name, text)

    def load_all(self) -> list[Peer]:
        return [self.load(name) for name in self.names()]

    def save(self, peer: Peer, *, private_key: str = PLACEHOLDER) -> None:
        """Write one peer's config and metadata.

        The config is created 0600 before any content is written, so it is
        never briefly readable while it holds a real key.
        """
        self.ensure()
        conf = self.conf_path(peer.name)
        meta = self.meta_path(peer.name)
        _write(conf, peer.conf_text(private_key), 0o600)
        _write(meta, peer.meta_text(), 0o644)

    def remove(self, name: str) -> None:
        self.conf_path(name).unlink(missing_ok=True)
        self.meta_path(name).unlink(missing_ok=True)


def parse_wg_conf(text: str) -> dict[str, str]:
    """Pull the fields wgq needs out of an existing WireGuard config.

    Used by `wgq peer import` for servers with no API: a self-hosted
    endpoint, or a provider that just hands you a .conf file.  Returns the
    raw strings; validation happens when the Peer is constructed.

    Only the first [Peer] section is read.  A multi-peer config describes a
    topology this project does not model (one tunnel, one exit), so taking
    the first and ignoring the rest would be a silent wrong answer.
    """
    section = ""
    interface: dict[str, str] = {}
    peers: list[dict[str, str]] = []

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            if section == "peer":
                peers.append({})
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise LayoutError(f"line {lineno}: not a key = value line: {raw.strip()!r}")
        key = key.strip().lower()
        value = value.strip()
        if section == "interface":
            interface[key] = value
        elif section == "peer" and peers:
            peers[-1][key] = value
        else:
            raise LayoutError(f"line {lineno}: setting outside any section: {raw.strip()!r}")

    if not peers:
        raise LayoutError("config has no [Peer] section")
    if len(peers) > 1:
        raise LayoutError(
            f"config has {len(peers)} [Peer] sections. wgq models one tunnel with one "
            "exit; import them as separate peers instead of guessing which to use."
        )

    result = {f"peer_{k}": v for k, v in peers[0].items()}
    result.update({f"iface_{k}": v for k, v in interface.items()})
    return result


def _write(path: Path, text: str, mode: int) -> None:
    """Create the file with its final mode, then fill it, then rename.

    O_EXCL (after clearing any stale temp file) means the fd can only ever
    be a file this call created: a pre-existing file or planted symlink at
    the temp path is never written through, and never briefly holds content
    under an older, looser mode.  fchmod then pins the exact mode, since
    the mode passed to open() is masked by the umask.
    """
    tmp = path.with_name(path.name + ".tmp")
    tmp.unlink(missing_ok=True)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        os.fchmod(fd, mode)
        handle = os.fdopen(fd, "w", encoding="ascii")
    except BaseException:
        os.close(fd)
        tmp.unlink(missing_ok=True)
        raise
    try:
        with handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    os.replace(tmp, path)
    # Sync the directory too, or a crash can forget the rename it just saw.
    dirfd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)
