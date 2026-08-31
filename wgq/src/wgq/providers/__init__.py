"""Provider registry.

Imports are lazy so that a broken or half-finished backend cannot stop the
others from loading, and so `wgq --help` works without touching the network
stack at all.
"""

from __future__ import annotations

from ..errors import UsageError
from .base import Device, Provider, Server, filter_servers, resolve_single_ipv4

__all__ = [
    "Device",
    "Provider",
    "Server",
    "filter_servers",
    "resolve_single_ipv4",
    "PROVIDERS",
    "get",
]

PROVIDERS = ("mullvad", "ivpn")


def get(name: str) -> type[Provider]:
    """Return the Provider subclass called *name*."""
    key = name.strip().lower()
    if key == "mullvad":
        from .mullvad import Mullvad

        return Mullvad
    if key == "ivpn":
        from .ivpn import IVPN

        return IVPN
    raise UsageError(f"unknown provider {name!r}; known: {', '.join(PROVIDERS)}")
