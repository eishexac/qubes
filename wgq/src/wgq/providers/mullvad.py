"""Mullvad backend.

Endpoint paths were read from mullvadvpn-app's mullvad-api crate rather than
from documentation: ``src/lib.rs`` defines ``ACCOUNTS_URL_PREFIX =
"accounts/v1"`` and ``APP_URL_PREFIX = "app/v1"``, and ``src/device.rs``
shows every device call built from the former.  Several third-party guides
still name ``app/v1/devices`` and ``www/wg-pubkeys/revoke/``; neither is
what the app uses.  The relay-list field names were verified against the
live ``www/relays/wireguard/`` response (August 2026) -- note the server
key arrives as ``pubkey`` there, not ``public_key``.

Error codes are the exact constants from ``mullvad-api/src/lib.rs``
(``MAX_DEVICES_REACHED``, ``INVALID_ACCOUNT``, ``INVALID_ACCESS_TOKEN``,
``PUBKEY_IN_USE``); newer errors arrive as ``problem+json`` carrying the
identifier in ``type`` instead of ``code``, so both spellings are read.

Mullvad has been WireGuard-only since 15 January 2026, so there are no
OpenVPN paths here.
"""

from __future__ import annotations

import json
import re
from typing import Any, Mapping

from ..errors import AuthError, DeviceLimitError, ProviderError, ServerListError
from ..http import Http, HttpError, iter_mappings, require_field, require_list, require_mapping
from ..validate import require_tunnel_address, require_wg_key
from .base import Device, Provider, Server, filter_servers

API_BASE = "https://api.mullvad.net"

TOKEN_PATH = "auth/v1/token"
DEVICES_PATH = "accounts/v1/devices"
ACCOUNT_PATH = "accounts/v1/accounts/me"
RELAYS_PATH = "www/relays/wireguard/"

# New accounts are 16 digits, but 12- and 13-digit legacy numbers remain
# valid (Mullvad's 2017 lengthening announcement grandfathered them), and
# the official login UI enforces only digits with a minimum length of 10.
# Rejecting a working legacy account here would be a false refusal.
ACCOUNT_RE = re.compile(r"^\d{10,20}$")


class Mullvad(Provider):
    name = "mullvad"
    dns = "10.64.0.1"
    default_port = 51820
    credential_hint = (
        "a Mullvad account number, on one line (16 digits for current "
        "accounts; shorter legacy numbers still work)"
    )

    def __init__(self, *, hijack_dns: bool = False, timeout: float = 20.0) -> None:
        self._http = Http(API_BASE, timeout=timeout)
        self._token: str | None = None
        self._account: str | None = None
        # The app itself submits hijack_dns: false (device.rs). Our nftables
        # DNAT already pins client DNS, so server-side hijacking is redundant.
        self._hijack_dns = bool(hijack_dns)

    # -- auth ---------------------------------------------------------------

    def authenticate(self, credential: str) -> None:
        account = "".join(credential.split())
        if not ACCOUNT_RE.match(account):
            raise AuthError(
                "that does not look like a Mullvad account number "
                "(expected 10 to 20 digits, spaces ignored)"
            )
        # Register before the request, so a provider that echoes the number
        # back in an error body cannot put it in a traceback.
        self._http.redact(account)

        payload = require_mapping(
            self._http.request(
                "POST", TOKEN_PATH, json_body={"account_number": account}, expect=(200, 201)
            ),
            "auth/v1/token",
        )
        token = require_field(payload, "access_token", "auth/v1/token")
        if not isinstance(token, str) or not token:
            raise AuthError("Mullvad returned an empty access token")

        self._http.redact(token)
        self._token = token
        self._account = account

    def _auth(self) -> dict[str, str]:
        if not self._token:
            raise AuthError("not authenticated; call authenticate() first")
        return {"Authorization": f"Bearer {self._token}"}

    # -- account and devices ------------------------------------------------

    def account(self) -> Mapping[str, Any]:
        return require_mapping(
            self._http.request("GET", ACCOUNT_PATH, headers=self._auth()),
            ACCOUNT_PATH,
        )

    def devices(self) -> list[Device]:
        raw = require_list(
            self._http.request("GET", DEVICES_PATH, headers=self._auth()), DEVICES_PATH
        )
        devices = []
        for entry in iter_mappings(raw, DEVICES_PATH):
            devices.append(
                Device(
                    id=str(require_field(entry, "id", DEVICES_PATH)),
                    name=str(entry.get("name") or ""),
                    pubkey=require_wg_key(
                        require_field(entry, "pubkey", DEVICES_PATH), "registered device key"
                    ),
                    address=require_tunnel_address(
                        require_field(entry, "ipv4_address", DEVICES_PATH),
                        "registered device address",
                    ),
                )
            )
        return devices

    def register(self, pubkey: str) -> str:
        require_wg_key(pubkey, "public key")

        existing = self.devices()
        for device in existing:
            if device.pubkey == pubkey:
                # Already registered. Returning the existing address keeps
                # re-runs idempotent instead of burning a second slot on a
                # key the account already holds.
                return device.address

        self._check_capacity(existing)

        try:
            payload = require_mapping(
                self._http.request(
                    "POST",
                    DEVICES_PATH,
                    json_body={"pubkey": pubkey, "hijack_dns": self._hijack_dns},
                    headers=self._auth(),
                    expect=(200, 201),
                ),
                DEVICES_PATH,
            )
        except HttpError as exc:
            raise self._translate(exc, existing) from None

        return require_tunnel_address(
            require_field(payload, "ipv4_address", DEVICES_PATH), "assigned address"
        )

    def rotate(self, old_pubkey: str, new_pubkey: str) -> str:
        """Replace a registered key in place.

        This is the reason to prefer PUT over delete-then-create: rotating
        in place needs no free device slot, so it works on a full account.
        """
        require_wg_key(old_pubkey, "current public key")
        require_wg_key(new_pubkey, "new public key")

        for device in self.devices():
            if device.pubkey == old_pubkey:
                payload = require_mapping(
                    self._http.request(
                        "PUT",
                        f"{DEVICES_PATH}/{device.id}/pubkey",
                        json_body={"pubkey": new_pubkey},
                        headers=self._auth(),
                    ),
                    "device pubkey rotation",
                )
                return require_tunnel_address(
                    require_field(payload, "ipv4_address", "device rotation"),
                    "reassigned address",
                )
        raise ProviderError("no registered device holds that public key")

    def revoke(self, pubkey: str) -> None:
        require_wg_key(pubkey, "public key")
        for device in self.devices():
            if device.pubkey == pubkey:
                self._http.request(
                    "DELETE",
                    f"{DEVICES_PATH}/{device.id}",
                    headers=self._auth(),
                    expect=(200, 202, 204),
                )
                return
        raise ProviderError("no registered device holds that public key")

    # -- servers ------------------------------------------------------------

    def servers(self, filt: str | None = None) -> list[Server]:
        # The public relay list needs no token, so `wgq servers` works
        # without touching the credential file at all.
        raw = require_list(self._http.request("GET", RELAYS_PATH), RELAYS_PATH)
        if not raw:
            raise ServerListError("Mullvad returned an empty relay list")

        found = []
        for entry in iter_mappings(raw, RELAYS_PATH):
            if entry.get("active") is False:
                continue
            hostname = str(require_field(entry, "hostname", RELAYS_PATH))
            found.append(
                Server(
                    name=hostname,
                    hostname=hostname,
                    # The live relay list calls this field "pubkey"; the
                    # devices API uses the same name. It is NOT public_key.
                    pubkey=str(require_field(entry, "pubkey", RELAYS_PATH)),
                    endpoint_ip=str(require_field(entry, "ipv4_addr_in", RELAYS_PATH)),
                    port=self.default_port,
                    country=str(entry.get("country_code") or ""),
                    city=str(entry.get("city_code") or ""),
                )
            )
        if not found:
            raise ServerListError("Mullvad's relay list contains no active WireGuard relays")
        return filter_servers(found, filt)

    # -- errors -------------------------------------------------------------

    def _check_capacity(self, existing: list[Device]) -> None:
        """Refuse before the API does, so the message can be useful."""
        try:
            info = self.account()
        except ProviderError:
            return  # not fatal; the API will still reject if full

        # These two fields appear in live accounts/me responses but not in
        # the app's own parsed types, so treat them as observed rather than
        # contractual: act on them when present, and let the API's own
        # MAX_DEVICES_REACHED refusal be the backstop when absent.
        can_add = info.get("can_add_devices")
        max_devices = info.get("max_devices")
        if can_add is False or (
            isinstance(max_devices, int) and len(existing) >= max_devices
        ):
            raise DeviceLimitError(self._device_limit_message(existing, max_devices))

    def _device_limit_message(self, existing: list[Device], max_devices: Any) -> str:
        limit = max_devices if isinstance(max_devices, int) else len(existing)
        lines = [
            f"this Mullvad account already holds {len(existing)} of {limit} devices.",
            "Registered devices:",
        ]
        lines += [f"  {device.describe()}" for device in existing]
        lines += [
            "",
            "Your phone and laptop consume the same slots. Free one with:",
            "  wgq revoke --provider mullvad --pubkey <key>",
            "or, to move an existing slot to a new key without needing a free one:",
            "  wgq rotate --provider mullvad --old-pubkey <old> --pubkey <new>",
        ]
        return "\n".join(lines)

    def _translate(self, exc: HttpError, existing: list[Device]) -> ProviderError:
        code = ""
        try:
            payload = json.loads(exc.body)
            if isinstance(payload, dict):
                # Older errors carry the identifier in "code"; the newer
                # problem+json variant uses "type".
                code = str(
                    payload.get("code") or payload.get("type") or payload.get("error") or ""
                )
        except ValueError:
            pass

        normalised = code.upper().replace("-", "_")
        if normalised in ("MAX_DEVICES_REACHED", "MAXDEVICESREACHED"):
            return DeviceLimitError(self._device_limit_message(existing, None))
        if normalised == "PUBKEY_IN_USE":
            return ProviderError(
                "Mullvad says this public key is already registered "
                "(PUBKEY_IN_USE). If it belongs to another of your devices, "
                "generate a fresh key in the zone qube with "
                "'sudo wgq keygen --force'."
            )
        if normalised in ("INVALID_ACCOUNT", "INVALID_ACCESS_TOKEN") or exc.status in (401, 403):
            return AuthError(f"Mullvad rejected the credential{f' ({code})' if code else ''}")
        return exc
