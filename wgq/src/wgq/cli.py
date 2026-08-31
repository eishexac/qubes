"""Command line interface.

One tool, two roles.  Provisioning commands run in wgq-mgmt, which holds the
account credential and reaches the network through sys-firewall; key
handling runs in sys-vpn-<zone>, where the private key is generated and
never leaves.  dom0 is refused for every command.  The mgmt/zone split is
enforced by possession -- the credential file lives in one qube and the key
in the other, so a command run in the wrong qube fails on the missing
material -- not by guessing qube names.

Nothing here runs in dom0.  The only things this project puts there are two
qrexec policy lines and the Salt formula, both of which are text the user
reads first.
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import sys
from pathlib import Path

from . import __version__, fwrules, qrexec, store
from .errors import AdminAPIError, UsageError, WgqError
from .peers import PLACEHOLDER, Peer, PeerDir, parse_wg_conf
from .providers import PROVIDERS, get as get_provider, resolve_single_ipv4
from .validate import (
    require_ipv4,
    require_peer_name,
    require_port,
    require_public_ipv4,
    require_tunnel_address,
    require_unicast_ipv4,
    require_wg_key,
)

ZONE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,20}$")
DEFAULT_COUNT = 2


# -- environment guards -----------------------------------------------------


def looks_like_dom0() -> bool:
    """dom0 has qrexec-client but not qrexec-client-vm."""
    return Path("/etc/qubes-release").is_file() and not qrexec.available()


def refuse_dom0() -> None:
    if looks_like_dom0():
        raise UsageError(
            "wgq must never run in dom0.\n"
            "Provisioning belongs in wgq-mgmt and key handling in sys-vpn-<zone>. "
            "The only things this project puts in dom0 are the Salt formula and "
            "two lines in /etc/qubes/policy.d/30-wgq.policy."
        )


def require_zone(zone: str) -> str:
    if not ZONE_RE.match(zone):
        raise UsageError(
            f"unusable zone name {zone!r}; use lowercase letters, digits and dashes"
        )
    return zone


def vm_for_zone(zone: str) -> str:
    return f"sys-vpn-{require_zone(zone)}"


def record_dir(zone: str) -> Path:
    """Where wgq-mgmt keeps the record of what it handed out.

    This doubles as the bundle that gets qvm-copied to the zone qube, so the
    allowlist and the installed configs are built from the same files and
    cannot drift apart.
    """
    base = os.environ.get("WGQ_STATE_DIR")
    root = Path(base) if base else Path.home() / ".local" / "share" / "wgq"
    return root / "zones" / require_zone(zone) / "peers"


# -- inputs -----------------------------------------------------------------


def read_credential(path: Path) -> str:
    try:
        info = path.stat()
    except FileNotFoundError:
        raise UsageError(
            f"no credential file at {path}.\n"
            f"Create it with:\n"
            f"    install -m 600 /dev/null {path}\n"
            f"    printf '%s\\n' <account-number> > {path}"
        ) from None
    if not path.is_file():
        raise UsageError(f"{path} is not a regular file")
    if info.st_mode & 0o077:
        raise UsageError(
            f"{path} is mode {info.st_mode & 0o777:o}; it holds an account credential "
            f"and must not be group- or world-readable.\n    chmod 600 {path}"
        )
    text = path.read_text(encoding="ascii", errors="strict").strip()
    if not text:
        raise UsageError(f"{path} is empty")
    return text


def read_pubkey(value: str | None) -> str:
    if value in (None, "-"):
        if sys.stdin.isatty():
            raise UsageError(
                "no public key given. Pass --pubkey <key>, or pipe it in:\n"
                "    qvm-run -p sys-vpn-work 'wgq pubkey' | wgq provision --zone work ..."
            )
        value = sys.stdin.read().strip()
    assert value is not None
    return require_wg_key(value.strip(), "public key")


def parse_renames(pairs: list[str]) -> dict[str, str]:
    renames = {}
    for pair in pairs:
        server, sep, peer = pair.partition("=")
        if not sep or not server or not peer:
            raise UsageError(f"--name expects SERVER=PEERNAME, got {pair!r}")
        renames[server] = require_peer_name(peer, f"peer name in --name {pair}")
    return renames


# -- commands: management qube ----------------------------------------------


def cmd_servers(args: argparse.Namespace) -> int:
    provider = get_provider(args.provider)(timeout=args.timeout)
    servers = provider.servers(args.filter)
    for server in servers:
        print(f"{server.name:<20} {server.endpoint:<24} {server.location}")
    print(f"\n{len(servers)} server(s)", file=sys.stderr)
    return 0


def cmd_provision(args: argparse.Namespace) -> int:
    zone = require_zone(args.zone)
    provider_cls = get_provider(args.provider)
    provider = provider_cls(timeout=args.timeout)

    pubkey = read_pubkey(args.pubkey)
    account_path = Path(
        args.account_file or f"/rw/config/{provider_cls.name}-account"
    )
    credential = read_credential(account_path)

    provider.authenticate(credential)
    del credential

    chosen = select_servers(provider, args)
    renames = parse_renames(args.name)
    unknown = sorted(set(renames) - {server.name for server in chosen})
    if unknown:
        raise UsageError(
            f"--name refers to server(s) outside this selection: {', '.join(unknown)}. "
            "A silently ignored rename would leave a peer under a name you did not expect."
        )

    address = provider.register(pubkey)

    # Build and validate every peer before writing any of them.
    peers = []
    for server in chosen:
        name = renames.get(server.name) or server.peer_name()
        peers.append(
            Peer(
                name=name,
                provider=provider_cls.name,
                address=address,
                server_pubkey=server.pubkey,
                endpoint_ip=server.endpoint_ip,
                endpoint_port=args.port or server.port,
                dns=provider_cls.dns,
            )
        )
    names = [peer.name for peer in peers]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise UsageError(
            f"two servers would be stored under the same peer name: "
            f"{', '.join(duplicates)}. Rename with --name SERVER=PEER so "
            "neither silently overwrites the other."
        )

    bundle = record_dir(zone)
    target = PeerDir(bundle)
    target.ensure()
    stale = set(target.names()) - {peer.name for peer in peers}
    for peer in peers:
        target.save(peer)

    print(f"wrote {len(peers)} peer(s) to {bundle}")
    for peer in peers:
        print(f"  {peer.name:<18} {peer.endpoint:<24} dns={peer.dns}")
    if stale:
        print(
            f"\nnote: {bundle} still holds peers from an earlier run: "
            f"{', '.join(sorted(stale))}\n"
            f"      They stay in the allowlist. Drop one with "
            f"'wgq peer rm --zone {zone} <name>'.",
            file=sys.stderr,
        )

    # gethostname(), evaluated here: the QubesIncoming subdirectory is named
    # after the qube that ran qvm-copy -- this one -- while the printed
    # command is pasted in the receiver, where $(hostname) would name the
    # wrong qube.
    print(
        f"\nNext:\n"
        f"    qvm-copy {bundle.parent}\n"
        f"    # then in {vm_for_zone(zone)}:\n"
        f"    sudo wgq apply ~/QubesIncoming/{socket.gethostname()}/{zone}/peers\n"
        f"    sudo wgq switch {peers[0].name}\n"
        f"    # and back here:\n"
        f"    wgq firewall --zone {zone}"
    )
    return 0


def select_servers(provider, args: argparse.Namespace):
    if args.server and args.filter:
        raise UsageError(
            "--server picks exact names, so --filter would be silently "
            "ignored; pass one or the other"
        )
    servers = provider.servers(None if args.server else args.filter)
    if args.server:
        by_name = {server.name: server for server in servers}
        missing = [name for name in args.server if name not in by_name]
        if missing:
            raise UsageError(
                f"no such server(s): {', '.join(missing)}. "
                f"List them with: wgq servers --provider {args.provider}"
            )
        return [by_name[name] for name in args.server]

    count = args.count
    if len(servers) < count:
        raise UsageError(
            f"only {len(servers)} server(s) match {args.filter!r} but --count is {count}. "
            "Refusing to write a shorter allowlist than you asked for."
        )
    return servers[:count]


def parse_endpoint(value: str, *, allow_private: bool = False) -> tuple[str, int]:
    """Accept ``IP:PORT`` or ``host:port``, always emitting a numeric IP.

    A hostname is resolved here and refused if it is load balanced, because
    a qvm-firewall rule pins one address and would silently stop matching
    the next time DNS answered differently.
    """
    host, sep, port = value.rpartition(":")
    if not sep or not host:
        raise UsageError(f"--endpoint expects IP:PORT, got {value!r}")
    port_number = require_port(port, "endpoint port")

    check = require_unicast_ipv4 if allow_private else require_public_ipv4
    try:
        return check(host, "endpoint"), port_number
    except WgqError as exc:
        # A literal address that failed validation is a hard error; only a
        # name should fall through to resolution.
        if any(char.isalpha() for char in host):
            return resolve_single_ipv4(host), port_number
        if not allow_private:
            raise UsageError(
                f"{exc}\nIf this is your own server on a LAN or reached across "
                "another tunnel, pass --allow-private-endpoint."
            ) from None
        raise


def _store_peer(zone: str, peer: Peer) -> int:
    target = PeerDir(record_dir(zone))
    target.ensure()
    target.save(peer)
    print(f"recorded {peer.name} in {target.root}")
    print(f"  endpoint {peer.endpoint}   resolver {peer.dns}   address {peer.address}")
    # gethostname() rather than a printed $(hostname): QubesIncoming is
    # named after the sending qube, and the command runs in the receiver.
    print(
        f"\nNext:\n"
        f"    qvm-copy {target.root.parent}\n"
        f"    # then in {vm_for_zone(zone)}:\n"
        f"    sudo wgq apply ~/QubesIncoming/{socket.gethostname()}/{zone}/peers\n"
        f"    sudo wgq switch {peer.name}\n"
        f"    # and back here:\n"
        f"    wgq firewall --zone {zone}"
    )
    return 0


def cmd_peer_add(args: argparse.Namespace) -> int:
    """Record a peer wgq did not provision: your own server, or any
    endpoint whose details you already have."""
    zone = require_zone(args.zone)
    endpoint_ip, port = parse_endpoint(
        args.endpoint, allow_private=args.allow_private_endpoint
    )
    return _store_peer(
        zone,
        Peer(
            name=require_peer_name(args.name),
            provider=args.label,
            address=args.address,
            server_pubkey=require_wg_key(args.server_pubkey, "server public key"),
            endpoint_ip=endpoint_ip,
            endpoint_port=port,
            dns=args.dns,
        ),
    )


# The config keys `peer import` carries over. Anything else is dropped, and
# the import says so: a knob that silently vanishes is discovered later as a
# tunnel that behaves differently from the file the user handed us.
_IMPORT_KEYS = {
    "iface_privatekey",
    "iface_address",
    "iface_dns",
    "peer_publickey",
    "peer_endpoint",
    "peer_allowedips",
}


def first_ipv4(values: str, convert) -> str:
    """First entry in a comma-separated list that *convert* accepts.

    Provider configs routinely carry dual-stack lists such as
    ``Address = 10.66.1.2/32, fc00::2/128``.  wgq is IPv4-only, so pick the
    v4 member instead of tripping over the v6 one; returns "" when no entry
    validates, and the caller says why that is fatal.
    """
    for part in values.split(","):
        part = part.strip()
        if part:
            try:
                return convert(part)
            except WgqError:
                continue
    return ""


def cmd_peer_import(args: argparse.Namespace) -> int:
    """Import an existing .conf, for a server with no API."""
    zone = require_zone(args.zone)
    try:
        text = Path(args.conf).read_text(encoding="utf-8", errors="strict")
    except OSError as exc:
        raise UsageError(f"cannot read {args.conf}: {exc}") from None
    except UnicodeDecodeError:
        raise UsageError(f"{args.conf} is not a text file") from None
    fields = parse_wg_conf(text)

    private = fields.get("iface_privatekey", "")
    if private and private != PLACEHOLDER:
        raise UsageError(
            f"{args.conf} carries a real PrivateKey, so that key was generated "
            "outside the VPN qube.\n"
            "wgq will not move a private key through the management qube. Instead:\n"
            f"    1. qvm-run -p {vm_for_zone(zone)} 'wgq pubkey'   "
            "(run 'sudo wgq keygen' there first)\n"
            "    2. add that public key to your server's configuration\n"
            "    3. wgq peer add --zone %s --name %s \\\n"
            "           --server-pubkey <server key> --endpoint <ip:port> \\\n"
            "           --address <the address your server assigned>"
            % (zone, args.name)
        )

    if fields.get("peer_presharedkey"):
        raise UsageError(
            f"{args.conf} carries a PresharedKey. That is key material, and it "
            "has already transited this management qube -- the situation the "
            "key-handling design exists to prevent.\n"
            "wgq does not model preshared keys: re-issue the server config "
            "without one, or configure that peer by hand in the zone qube."
        )

    dropped = sorted(key for key in fields if key not in _IMPORT_KEYS)
    if dropped:
        shown = ", ".join(
            key.split("_", 1)[1] + (" [Peer]" if key.startswith("peer_") else "")
            for key in dropped
        )
        print(
            f"note: not carried over from {args.conf}: {shown}.\n"
            "      wgq regenerates the config from its own template, so hooks "
            "and tuning knobs (PostUp, MTU, PersistentKeepalive, ...) never "
            "survive an import.",
            file=sys.stderr,
        )

    # A provider-supplied conf carries DNS=, which wg-quick cannot apply on
    # Debian minimal. Lift it into the metadata, where the firewall script
    # turns it into a DNAT rule that actually pins clients.
    dns = args.dns or first_ipv4(
        fields.get("iface_dns", ""), lambda value: require_ipv4(value, "DNS")
    )
    if not dns:
        raise UsageError(
            f"{args.conf} has no usable IPv4 DNS= entry, so pass --dns with the "
            "resolver reachable inside this tunnel (your own, or a public one)."
        )

    address = first_ipv4(
        fields.get("iface_address", ""),
        lambda value: require_tunnel_address(value, "Address"),
    )
    if not address:
        raise UsageError(
            f"{args.conf} has no usable IPv4 Address= entry; wgq is IPv4-only "
            "(DESIGN.md explains why IPv6 is refused outright)."
        )

    endpoint = fields.get("peer_endpoint")
    if not endpoint:
        raise UsageError(f"{args.conf} has no Endpoint in its [Peer] section")
    endpoint_ip, port = parse_endpoint(
        endpoint, allow_private=args.allow_private_endpoint
    )

    allowed = fields.get("peer_allowedips", "")
    if allowed and "0.0.0.0/0" not in allowed:
        print(
            f"note: AllowedIPs was {allowed!r}; wgq writes 0.0.0.0/0 because a "
            "split tunnel cannot be made leak-tight by the kill switch.",
            file=sys.stderr,
        )

    return _store_peer(
        zone,
        Peer(
            name=require_peer_name(args.name),
            provider=args.label,
            address=address,
            server_pubkey=require_wg_key(
                fields.get("peer_publickey", ""), "server public key"
            ),
            endpoint_ip=endpoint_ip,
            endpoint_port=port,
            dns=dns,
        ),
    )


def cmd_peer_list(args: argparse.Namespace) -> int:
    peers = PeerDir(record_dir(require_zone(args.zone))).load_all()
    if not peers:
        print("no peers recorded for this zone")
        return 1
    for peer in peers:
        print(f"{peer.name:<18} {peer.provider:<10} {peer.endpoint:<24} dns={peer.dns}")
    return 0


def cmd_peer_rm(args: argparse.Namespace) -> int:
    target = PeerDir(record_dir(require_zone(args.zone)))
    if args.name not in target.names():
        raise UsageError(f"no peer named {args.name!r} in zone {args.zone!r}")
    target.remove(args.name)
    print(f"removed {args.name}")
    print(
        f"It stays installed in {vm_for_zone(args.zone)} until you remove it there, "
        f"and stays in the allowlist until you re-run:\n    wgq firewall --zone {args.zone}",
        file=sys.stderr,
    )
    return 0


def cmd_firewall(args: argparse.Namespace) -> int:
    zone = require_zone(args.zone)
    vm = args.vm or vm_for_zone(zone)
    peers = PeerDir(record_dir(zone)).load_all()
    if not peers:
        raise UsageError(
            f"no peers recorded for zone {zone!r}. Run 'wgq provision --zone {zone}' first."
        )

    rules = fwrules.api_rules(peers)

    if args.print_only or not qrexec.available():
        if not args.print_only:
            print(
                "qrexec-client-vm is unavailable, so falling back to the manual block.\n",
                file=sys.stderr,
            )
        print(fwrules.qvm_firewall_block(vm, peers))
        return 0

    print(f"Applying {len(rules)} rule(s) to {vm}:")
    print(fwrules.describe(rules))
    print(
        "\nIf the dom0 policy says 'ask', confirm the prompt now.",
        file=sys.stderr,
    )
    qrexec.firewall_set(vm, rules)
    applied = qrexec.firewall_get(vm)
    if not qrexec.rules_equal(applied, rules):
        raise AdminAPIError(
            "dom0 accepted the call, but the rules read back are not the rules "
            "sent. Do not trust this qube's allowlist until they match.\n"
            "sent:\n" + fwrules.describe(rules)
            + "\nread back:\n" + fwrules.describe(applied)
        )
    print(f"\napplied, and the read-back matches. {vm} now enforces:")
    for line in applied:
        print(f"  {line}")
    return 0


def cmd_devices(args: argparse.Namespace) -> int:
    provider = _authenticated(args)
    devices = provider.devices()
    if not devices:
        print("no devices registered")
        return 0
    for device in devices:
        print(device.describe())
    return 0


def cmd_account(args: argparse.Namespace) -> int:
    provider = _authenticated(args)
    info = provider.account()
    for key in sorted(info):
        print(f"{key:<18} {info[key]}")
    return 0


def cmd_revoke(args: argparse.Namespace) -> int:
    provider = _authenticated(args)
    provider.revoke(require_wg_key(args.pubkey, "public key"))
    print("revoked; the device slot is free")
    return 0


def cmd_rotate(args: argparse.Namespace) -> int:
    provider = _authenticated(args)
    address = provider.rotate(
        require_wg_key(args.old_pubkey, "current public key"),
        require_wg_key(args.pubkey, "new public key"),
    )
    print(f"rotated in place; address is now {address}")
    print(
        "Rotating in place needs no free device slot, which is why it works "
        "on a full account where delete-then-create would not.",
        file=sys.stderr,
    )
    return 0


def _authenticated(args: argparse.Namespace):
    provider_cls = get_provider(args.provider)
    provider = provider_cls(timeout=args.timeout)
    path = Path(args.account_file or f"/rw/config/{provider_cls.name}-account")
    provider.authenticate(read_credential(path))
    return provider


# -- commands: zone qube ----------------------------------------------------


def cmd_keygen(args: argparse.Namespace) -> int:
    store.require_zone_qube()
    existed = store.has_key()
    pubkey = store.keygen(force=args.force)
    if existed and not args.force:
        print("existing keypair kept", file=sys.stderr)
    else:
        # Name the qube: /rw/config exists in every AppVM, so nothing can
        # refuse a keygen typed into the wrong one -- but the user reading
        # "wgq-mgmt" here can.
        print(
            f"keypair generated in this qube ({socket.gethostname()}); "
            "the private half never leaves it",
            file=sys.stderr,
        )
    print(pubkey)
    return 0


def cmd_pubkey(args: argparse.Namespace) -> int:
    store.require_zone_qube()
    print(store.public_key())
    return 0


def cmd_apply(args: argparse.Namespace) -> int:
    installed = store.apply_bundle(Path(args.bundle))
    print(f"installed {len(installed)} peer(s): {', '.join(installed)}")
    active = store.active()
    if active is None:
        print(f"\nNo active peer yet. Choose one:\n    sudo wgq switch {installed[0]}")
    elif active in installed:
        print(
            f"\nThe active peer {active!r} was just reinstalled, but the "
            "running tunnel still uses the old config. Load the new one with:\n"
            f"    sudo wgq switch {active}",
            file=sys.stderr,
        )
    return 0


def cmd_switch(args: argparse.Namespace) -> int:
    store.set_active(args.peer)
    print(f"active peer is now {args.peer}")
    print(f"firewall: {store.firewall_state()}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    store.require_zone_qube()
    peers = store.peer_dir().names()
    active = store.active()
    firewall = store.firewall_state()
    print(f"peers:    {', '.join(peers) if peers else 'none installed'}")
    print(f"active:   {active or 'none'}")
    print(f"key:      {'present' if store.has_key() else 'MISSING'}")
    print(f"tunnel:   {store.tunnel_state()}")
    print(f"firewall: {firewall}")
    if active:
        peer = store.peer_dir().load(active)
        print(f"endpoint: {peer.endpoint}")
        print(f"resolver: {peer.dns}")
    # The exit code answers "is this zone healthy" for scripts, so it must
    # include the firewall verdict: an up tunnel in front of a broken or
    # degraded rule set is not health.
    healthy = bool(active) and store.tunnel_up() and firewall.startswith("ok")
    return 0 if healthy else 1


# -- argument parsing -------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wgq",
        description="Leak-tight WireGuard proxy qubes for Qubes OS.",
        epilog=(
            "Provisioning commands run in wgq-mgmt; keygen/apply/switch/status "
            "run in sys-vpn-<zone>. Nothing runs in dom0."
        ),
    )
    parser.add_argument("--version", action="version", version=f"wgq {__version__}")
    sub = parser.add_subparsers(dest="command", required=True, metavar="<command>")

    def provider_opts(p: argparse.ArgumentParser) -> None:
        p.add_argument(
            "--provider", default="mullvad", choices=PROVIDERS, help="VPN provider"
        )
        p.add_argument(
            "--account-file",
            help="path to a mode-600 file holding the account credential "
            "(default: /rw/config/<provider>-account)",
        )
        p.add_argument("--timeout", type=float, default=20.0, help="HTTP timeout, seconds")

    p = sub.add_parser("servers", help="list matching servers (no credential needed)")
    p.add_argument("--provider", default="mullvad", choices=PROVIDERS)
    p.add_argument("--filter", help="match on hostname, country or city")
    p.add_argument("--timeout", type=float, default=20.0)
    p.set_defaults(func=cmd_servers)

    p = sub.add_parser("provision", help="register a public key and write a peer bundle")
    provider_opts(p)
    p.add_argument("--zone", required=True, help="identity zone, e.g. work")
    p.add_argument("--pubkey", help="public key, or - to read stdin")
    p.add_argument("--filter", help="restrict the server search")
    p.add_argument(
        "--count", type=int, default=DEFAULT_COUNT, help="how many servers to select"
    )
    p.add_argument(
        "--server", action="append", default=[], help="exact server name; repeatable"
    )
    p.add_argument(
        "--name", action="append", default=[], metavar="SERVER=PEER",
        help="store SERVER under a shorter peer name; repeatable",
    )
    p.add_argument("--port", type=int, help="override the endpoint port")
    p.set_defaults(func=cmd_provision)

    peer = sub.add_parser(
        "peer",
        help="record peers wgq did not provision (your own server, or any .conf)",
    )
    peer_sub = peer.add_subparsers(dest="peer_command", required=True, metavar="<action>")

    p = peer_sub.add_parser("add", help="record a peer from its details")
    p.add_argument("--zone", required=True)
    p.add_argument("--name", required=True, help="peer name, max 15 chars")
    p.add_argument("--server-pubkey", required=True, help="the server's public key")
    p.add_argument("--endpoint", required=True, metavar="IP:PORT")
    p.add_argument(
        "--address", required=True, metavar="A.B.C.D",
        help="the tunnel address your server assigned to this qube",
    )
    p.add_argument(
        "--dns", required=True, metavar="A.B.C.D",
        help="resolver reachable inside this tunnel",
    )
    p.add_argument("--label", default="custom", help="provider label recorded in metadata")
    p.add_argument(
        "--allow-private-endpoint", action="store_true",
        help="permit an RFC1918 endpoint (your own server on a LAN)",
    )
    p.set_defaults(func=cmd_peer_add)

    p = peer_sub.add_parser("import", help="record a peer from an existing .conf file")
    p.add_argument("conf", help="path to a WireGuard config")
    p.add_argument("--zone", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--dns", help="override the config's DNS= line")
    p.add_argument("--label", default="custom")
    p.add_argument("--allow-private-endpoint", action="store_true")
    p.set_defaults(func=cmd_peer_import)

    p = peer_sub.add_parser("list", help="show the peers recorded for a zone")
    p.add_argument("--zone", required=True)
    p.set_defaults(func=cmd_peer_list)

    p = peer_sub.add_parser("rm", help="forget a recorded peer")
    p.add_argument("--zone", required=True)
    p.add_argument("name")
    p.set_defaults(func=cmd_peer_rm)

    p = sub.add_parser("firewall", help="apply the endpoint allowlist to a zone qube")
    p.add_argument("--zone", required=True)
    p.add_argument("--vm", help="target qube (default: sys-vpn-<zone>)")
    p.add_argument(
        "--print", dest="print_only", action="store_true",
        help="print the manual qvm-firewall block instead of applying it",
    )
    p.set_defaults(func=cmd_firewall)

    p = sub.add_parser("devices", help="list keys registered with the account")
    provider_opts(p)
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("account", help="show account status and device limit")
    provider_opts(p)
    p.set_defaults(func=cmd_account)

    p = sub.add_parser("revoke", help="revoke a registered key, freeing its slot")
    provider_opts(p)
    p.add_argument("--pubkey", required=True)
    p.set_defaults(func=cmd_revoke)

    p = sub.add_parser("rotate", help="move a registered slot to a new key")
    provider_opts(p)
    p.add_argument("--old-pubkey", required=True)
    p.add_argument("--pubkey", required=True)
    p.set_defaults(func=cmd_rotate)

    p = sub.add_parser("keygen", help="[zone qube] create the keypair, print the public key")
    p.add_argument(
        "--force", action="store_true",
        help="replace an existing key (retires it; the old one still holds a device slot)",
    )
    p.set_defaults(func=cmd_keygen)

    p = sub.add_parser("pubkey", help="[zone qube] print this qube's public key")
    p.set_defaults(func=cmd_pubkey)

    p = sub.add_parser("apply", help="[zone qube] install a bundle copied from wgq-mgmt")
    p.add_argument("bundle", help="path to the copied peers/ directory")
    p.set_defaults(func=cmd_apply)

    p = sub.add_parser("switch", help="[zone qube] change the active peer")
    p.add_argument("peer")
    p.set_defaults(func=cmd_switch)

    p = sub.add_parser("status", help="[zone qube] show peer, tunnel and firewall state")
    p.set_defaults(func=cmd_status)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        # Checked once, here, rather than per command: a subcommand added
        # later cannot forget it. Nothing wgq does belongs in dom0 -- the
        # only things this project puts there are the Salt formula and two
        # lines of qrexec policy.
        refuse_dom0()
        return int(args.func(args))
    except WgqError as exc:
        print(f"wgq: {exc}", file=sys.stderr)
        return 1
    except (OSError, UnicodeDecodeError) as exc:
        # Filesystem and encoding surprises (missing file, permission
        # denied, a credential file with a stray byte) get one readable
        # line, not a traceback.
        print(f"wgq: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nwgq: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
