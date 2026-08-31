"""Validators shared by the providers, the peer store and the CLI.

These are the choke points where "fail loudly" is actually enforced: every
value that reaches a config file or a firewall rule passes through one of
them first, and anything that does not validate raises rather than being
coerced, skipped or defaulted.
"""

from __future__ import annotations

import base64
import binascii
import ipaddress
import re

from .errors import ProviderError

# wg-quick derives the interface name from the config file's basename and
# enforces this exact pattern (wireguard-tools, src/wg-quick/linux.bash):
#
#     [[ $CONFIG_FILE =~ (^|/)([a-zA-Z0-9_=+.-]{1,15})\\.conf$ ]]
#
# Applying it here means an over-long provider hostname is caught at
# provisioning time with a useful message, rather than at boot with a
# wg-quick error.  It also rules out path traversal out of peers/.
PEER_NAME_RE = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")

# Provider-side identifiers are only ever displayed or matched against, so
# they may be longer -- but must still be a single inert token.
SERVER_NAME_RE = re.compile(r"^[A-Za-z0-9_.:@-]{1,64}$")

WG_KEY_BYTES = 32


def is_wg_key(value: object) -> bool:
    """True if *value* is a base64 WireGuard key of the right length."""
    if not isinstance(value, str) or len(value) != 44:
        return False
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        return False
    return len(raw) == WG_KEY_BYTES


def require_wg_key(value: object, what: str) -> str:
    if not is_wg_key(value):
        raise ProviderError(f"{what} is not a WireGuard key: {value!r}")
    assert isinstance(value, str)
    return value


def require_peer_name(value: object, what: str = "peer name") -> str:
    if not isinstance(value, str) or not PEER_NAME_RE.match(value):
        raise ProviderError(
            f"{what} {value!r} cannot be used as a WireGuard interface name "
            "(1-15 characters of A-Za-z0-9_=+.-)"
        )
    if value in (".", ".."):
        raise ProviderError(f"{what} {value!r} is not a usable file name")
    return value


def require_server_name(value: object, what: str = "server name") -> str:
    if not isinstance(value, str) or not SERVER_NAME_RE.match(value):
        raise ProviderError(f"{what} is unusable: {value!r}")
    return value


def require_ipv4(value: object, what: str) -> str:
    """Any IPv4 address, including private ranges (tunnel addresses)."""
    try:
        return str(ipaddress.IPv4Address(str(value).strip()))
    except ValueError as exc:
        raise ProviderError(f"{what} is not an IPv4 address: {value!r}") from exc


def require_unicast_ipv4(value: object, what: str) -> str:
    """A sane unicast destination for a tunnel endpoint.

    Rejects addresses that can never be a WireGuard peer, but *allows*
    RFC1918: a self-hosted server may genuinely live on a LAN address, or
    be reached across another tunnel.  Use :func:`require_public_ipv4` for
    anything a commercial provider handed us.

    The exclusions are spelled out rather than left to ``is_global``, which
    reports True for multicast - ipaddress treats 224.0.0.1 as global on the
    grounds that it is not in a private range.
    """
    addr = ipaddress.IPv4Address(require_ipv4(value, what))
    for predicate, label in (
        (addr.is_multicast, "multicast"),
        (addr.is_loopback, "loopback"),
        (addr.is_link_local, "link-local"),
        (addr.is_reserved, "reserved"),
        (addr.is_unspecified, "unspecified"),
    ):
        if predicate:
            raise ProviderError(f"{what} is a {label} address, not a usable endpoint: {addr}")
    return str(addr)


def require_public_ipv4(value: object, what: str) -> str:
    """A globally routable unicast address.

    Applied to everything a provider returns.  A private endpoint from a
    commercial VPN means something upstream is wrong, and pinning a
    qvm-firewall rule to it would allow traffic to an address the tunnel can
    never reach.
    """
    text = require_unicast_ipv4(value, what)
    addr = ipaddress.IPv4Address(text)
    if addr.is_private:
        raise ProviderError(f"{what} is a private address, not a routable one: {addr}")
    if not addr.is_global:
        raise ProviderError(f"{what} is not a routable public address: {addr}")
    return text


def require_tunnel_address(value: object, what: str) -> str:
    """Normalise an assigned tunnel address to exactly ``a.b.c.d/32``.

    Providers are inconsistent about whether they include the prefix, so
    accept both and always emit one form.  IPv6 is rejected outright: Qubes
    disables it unless every qube in the chain sets the ipv6 feature, and a
    mismatch breaks connectivity or leaks.
    """
    text = str(value).strip()
    if "/" in text:
        addr_part, _, prefix = text.partition("/")
        if prefix not in ("32", ""):
            raise ProviderError(
                f"{what} must be a single address, got prefix /{prefix}: {value!r}"
            )
    else:
        addr_part = text
    return f"{require_ipv4(addr_part, what)}/32"


def require_port(value: object, what: str) -> int:
    try:
        port = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError) as exc:
        raise ProviderError(f"{what} is not a port number: {value!r}") from exc
    if not 1 <= port <= 65535:
        raise ProviderError(f"{what} is out of range: {port}")
    return port
