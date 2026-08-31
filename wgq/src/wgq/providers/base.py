"""The provider interface.

A provider's only job is to turn a public key and an account credential into
(a) an assigned tunnel address and (b) a list of servers with *numeric*
endpoints.  Everything else - config generation, key handling, firewall
rules - happens above this layer and is provider-independent.

Numeric endpoints are not a preference.  qvm-firewall resolves hostnames at
the moment a rule takes effect, which includes every qube and netvm start,
and does not work reliably against a load-balanced name.  A provider that
publishes only hostnames must resolve them here and emit the result.
"""

from __future__ import annotations

import abc
import socket
from dataclasses import dataclass
from typing import Any, ClassVar, Iterable, Mapping

from ..errors import ProviderError, ServerListError
from ..validate import (
    require_peer_name,
    require_port,
    require_public_ipv4,
    require_server_name,
    require_unicast_ipv4,
    require_wg_key,
)


@dataclass(frozen=True)
class Server:
    """One provider endpoint, validated on construction."""

    name: str
    pubkey: str
    endpoint_ip: str
    port: int = 51820
    country: str = ""
    city: str = ""
    hostname: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "name", require_server_name(self.name))
        object.__setattr__(
            self, "pubkey", require_wg_key(self.pubkey, f"server {self.name} public key")
        )
        object.__setattr__(
            self,
            "endpoint_ip",
            require_public_ipv4(self.endpoint_ip, f"server {self.name} endpoint"),
        )
        object.__setattr__(self, "port", require_port(self.port, f"server {self.name} port"))

    @property
    def endpoint(self) -> str:
        return f"{self.endpoint_ip}:{self.port}"

    @property
    def location(self) -> str:
        parts = [part for part in (self.city, self.country) if part]
        return ", ".join(parts)

    def peer_name(self) -> str:
        """The file name this server's config will be stored under.

        Separate from :attr:`name` because a provider identifier may be
        longer or richer than a WireGuard interface name allows.  Raises if
        the name will not fit, so the failure lands at provisioning time
        with an actionable message.
        """
        try:
            return require_peer_name(self.name, f"server name {self.name!r}")
        except ProviderError as exc:
            raise ProviderError(
                f"{exc}. Override it with --name {self.name}=<shortname>."
            ) from None

    def matches(self, needle: str) -> bool:
        needle = needle.lower()
        return any(
            needle in field.lower()
            for field in (self.name, self.hostname, self.country, self.city)
            if field
        )


@dataclass(frozen=True)
class Device:
    """A key registered with the provider's account."""

    id: str
    name: str
    pubkey: str
    address: str

    def describe(self) -> str:
        label = self.name or self.id
        return f"{label:<24} {self.address:<18} {self.pubkey}"


class Provider(abc.ABC):
    """Base class for every VPN backend."""

    #: short identifier, used in metadata and on the command line
    name: ClassVar[str]
    #: the resolver reachable inside this provider's tunnel
    dns: ClassVar[str]
    #: WireGuard listen port to assume when the API does not say
    default_port: ClassVar[int] = 51820
    #: one line describing what the credential file should contain
    credential_hint: ClassVar[str] = ""

    @abc.abstractmethod
    def authenticate(self, credential: str) -> None:
        """Validate and use *credential*.  Must not persist it anywhere."""

    @abc.abstractmethod
    def register(self, pubkey: str, *, force_login: bool = False) -> str:
        """Register *pubkey* and return the assigned address as ``a.b.c.d/32``.

        Idempotent wherever the provider's API allows it: registering a key
        the account already holds returns that key's existing address
        rather than consuming a second device slot (Mullvad).  A provider
        whose API cannot offer that (IVPN's session-based registration)
        must say so in its docstring and fail loudly at the limit instead
        of burning slots silently.

        ``force_login`` is the explicit opt-in to make room by logging the
        account's other devices out as part of this registration (IVPN's
        ``force`` field).  Never a default anywhere.  A provider without
        the concept must refuse loudly when it is set -- silently ignoring
        a flag that promises destructive behaviour would be worse than not
        having it.
        """

    @abc.abstractmethod
    def servers(self, filt: str | None = None) -> list[Server]:
        """Return every matching server, or raise.  Never a partial list."""

    # Optional capabilities.  The CLI checks for NotImplementedError and
    # says which provider lacks the feature rather than crashing.

    def devices(self) -> list[Device]:
        raise NotImplementedError(f"{self.name} does not expose a device list")

    def revoke(self, pubkey: str) -> None:
        raise NotImplementedError(f"{self.name} does not support revoking a key")

    def rotate(self, old_pubkey: str, new_pubkey: str) -> str:
        raise NotImplementedError(f"{self.name} does not support key rotation")

    def account(self) -> Mapping[str, Any]:
        raise NotImplementedError(f"{self.name} does not expose account status")


def filter_servers(servers: Iterable[Server], filt: str | None) -> list[Server]:
    """Apply a substring filter, refusing to return nothing silently."""
    all_servers = list(servers)
    if not all_servers:
        raise ServerListError("the provider returned no usable servers")
    if not filt:
        return all_servers
    hits = [server for server in all_servers if server.matches(filt)]
    if not hits:
        raise ServerListError(
            f"no server matches {filt!r} "
            f"(searched {len(all_servers)} servers by name, country and city)"
        )
    return hits


def resolve_ipv4(host: str) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_DGRAM)
    except socket.gaierror as exc:
        raise ProviderError(f"cannot resolve {host}: {exc}") from None
    addrs = sorted({info[4][0] for info in infos})
    if not addrs:
        raise ProviderError(f"{host} has no IPv4 address")
    return addrs


def resolve_single_ipv4(host: str, *, allow_private: bool = False) -> str:
    """Resolve *host*, refusing anything that is load balanced.

    A name with several A records cannot be pinned in a qvm-firewall rule:
    the rule would allow whichever address was current when it was applied,
    and the tunnel would fail the next time DNS returned a different one.

    The result passes the same validation a literal address would: public
    by default, RFC1918 permitted only when the caller has said the peer is
    deliberately private -- so ``--allow-private-endpoint`` means the same
    thing whether the user typed an address or a name.
    """
    addrs = resolve_ipv4(host)
    if len(addrs) != 1:
        raise ProviderError(
            f"{host} resolves to {len(addrs)} addresses ({', '.join(addrs)}); "
            "a load-balanced endpoint cannot be pinned in a firewall rule"
        )
    check = require_unicast_ipv4 if allow_private else require_public_ipv4
    return check(addrs[0], f"{host}")
