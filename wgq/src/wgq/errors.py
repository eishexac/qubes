"""Exception hierarchy.

Every failure path in wgq raises one of these rather than returning a
partial result.  The CLI turns them into a one-line message and a non-zero
exit; nothing else catches them.
"""

from __future__ import annotations


class WgqError(Exception):
    """Base class for every error wgq raises deliberately."""


class UsageError(WgqError):
    """The command cannot be run as invoked, or not in this qube."""


class LayoutError(WgqError):
    """Something on disk is missing, malformed, or unsafe to overwrite."""


class ProviderError(WgqError):
    """The provider returned something we cannot fully validate.

    Raised in preference to emitting a config or an allowlist that is only
    partly correct.
    """


class AuthError(ProviderError):
    """Credential rejected, or no valid token."""


class DeviceLimitError(ProviderError):
    """The account has no free device slot."""


class ServerListError(ProviderError):
    """The server list was empty, truncated, or shaped unexpectedly."""


class AdminAPIError(WgqError):
    """An admin.vm.* qrexec call failed or was denied."""
