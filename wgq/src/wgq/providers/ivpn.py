"""IVPN backend.

STATUS: request and response shapes verified against IVPN's open-source
client (ivpn/desktop-app: daemon/api/api.go, daemon/api/types/requests.go,
responses.go, errors.go) and the live v5/servers.json -- but NOT yet
exercised against a live account.  The shapes are no longer hypotheses;
the end-to-end behaviour still is.

Three differences from Mullvad worth knowing:

  * There is no separate "get a token" step.  ``/v4/session/new`` takes the
    account id (field name ``username``) and the public key
    (``wg_public_key``) together and registers the key as a side effect, so
    authenticate() only validates and stores the credential and register()
    does the work.

  * Registration is NOT idempotent: every ``session/new`` occupies one of
    the account's session slots (2 on Standard, 7 on Pro) until the API
    answers status 602.  wgq deliberately does not persist the session
    token (it keeps exactly one credential on disk), so it cannot use the
    ``v4/session/wg/set`` rotation endpoint; when the limit bites, log a
    device out in the IVPN app or website and provision again.

  * The default WireGuard port is 2049, not 51820 -- it is what the
    official app defaults to, and it is in the provider's published UDP
    port list.  The endpoint allowlist is built from Server.port, so this
    flows through to the firewall rules automatically; override it with
    --port if you use one of IVPN's alternative ports.
"""

from __future__ import annotations

import re
from typing import Any, Mapping

from ..errors import AuthError, DeviceLimitError, ProviderError, ServerListError
from ..http import Http, iter_mappings, require_field, require_list, require_mapping
from ..validate import require_tunnel_address, require_wg_key
from .base import Provider, Server, filter_servers

API_BASE = "https://api.ivpn.net"

SERVERS_PATH = "v5/servers.json"
SESSION_NEW_PATH = "v4/session/new"

# i-XXXX-XXXX-XXXX is the current form; the legacy one is ivpn + exactly
# 7 or 8 alphanumerics (the official daemon's own validation regex).
ACCOUNT_RE = re.compile(
    r"^(i-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}|ivpn[A-Za-z0-9]{7,8})$"
)

# API status values, from daemon/api/types/errors.go in the official client.
_STATUS_OK = 200
_STATUS_UNAUTHORIZED = 401
_STATUS_WG_KEY_NOT_FOUND = 424
_STATUS_SESSION_NOT_FOUND = 601
_STATUS_SESSION_LIMIT = 602
_STATUS_ACCOUNT_NOT_ACTIVE = 702


class IVPN(Provider):
    name = "ivpn"
    dns = "172.16.0.1"
    default_port = 2049
    credential_hint = "an IVPN account ID such as i-XXXX-XXXX-XXXX, on one line"

    def __init__(self, *, timeout: float = 20.0) -> None:
        self._http = Http(API_BASE, timeout=timeout)
        self._account: str | None = None
        self._token: str | None = None

    def authenticate(self, credential: str) -> None:
        account = "".join(credential.split())
        if not ACCOUNT_RE.match(account):
            raise AuthError(
                "that does not look like an IVPN account ID "
                "(expected i-XXXX-XXXX-XXXX)"
            )
        self._http.redact(account)
        self._account = account

    def register(self, pubkey: str, *, force_login: bool = False) -> str:
        require_wg_key(pubkey, "public key")
        if not self._account:
            raise AuthError("not authenticated; call authenticate() first")

        # force defaults to false, matching the official client: kicking the
        # account's other devices out is only ever an explicit --force-login.
        payload = require_mapping(
            self._http.request(
                "POST",
                SESSION_NEW_PATH,
                json_body={
                    "username": self._account,
                    "wg_public_key": pubkey,
                    "force": bool(force_login),
                },
                expect=(200, 201),
            ),
            SESSION_NEW_PATH,
        )

        self._check_status(payload)

        token = payload.get("token")
        if isinstance(token, str) and token:
            self._http.redact(token)
            self._token = token

        return require_tunnel_address(self._assigned_address(payload), "assigned address")

    @staticmethod
    def _check_status(payload: Mapping[str, Any]) -> None:
        """Map the API's integer status to an error that says what to do."""
        status = payload.get("status")
        if status in (_STATUS_OK, None):
            return
        message = payload.get("message") or payload.get("error") or f"status {status}"
        if status == _STATUS_SESSION_LIMIT:
            raise DeviceLimitError(
                f"IVPN session limit reached: {message}\n"
                "Every provisioning run opens a session, and accounts hold 2 "
                "(Standard) or 7 (Pro). Two ways out:\n"
                "  - log a device out in the IVPN app or at ivpn.net, then "
                "run this again, or\n"
                "  - re-run with --force-login to log your OTHER IVPN devices "
                "out as part of this login."
            )
        if status in (_STATUS_UNAUTHORIZED, _STATUS_SESSION_NOT_FOUND):
            raise AuthError(f"IVPN rejected the account credential: {message}")
        if status == _STATUS_ACCOUNT_NOT_ACTIVE:
            raise AuthError(f"this IVPN account is not active: {message}")
        if status == _STATUS_WG_KEY_NOT_FOUND:
            raise ProviderError(f"IVPN did not accept the WireGuard key: {message}")
        raise ProviderError(f"IVPN refused the session: {message}")

    @staticmethod
    def _assigned_address(payload: Mapping[str, Any]) -> Any:
        """Pull the tunnel address out of the session response.

        The verified shape (daemon/api/types/responses.go) nests it as
        ``wireguard.ip_address``, beside a per-key ``status``/``message``
        of its own; the flat fallbacks stay only as a hedge against an API
        revision, and failing both is a loud error rather than a guess.
        """
        nested = payload.get("wireguard")
        if isinstance(nested, dict):
            wg_status = nested.get("status")
            if wg_status not in (_STATUS_OK, None, 0):
                message = nested.get("message") or f"status {wg_status}"
                raise ProviderError(
                    f"IVPN opened the session but refused the WireGuard key: {message}"
                )
            for key in ("ip_address", "ip", "local_ip"):
                if nested.get(key):
                    return nested[key]
        for key in ("wg_ip", "wireguard_ip"):
            if payload.get(key):
                return payload[key]
        raise ProviderError(
            "IVPN's session response carried no tunnel address "
            f"(looked for wireguard.ip_address and wg_ip; got keys: "
            f"{', '.join(sorted(payload)) or 'none'})"
        )

    def servers(self, filt: str | None = None) -> list[Server]:
        payload = require_mapping(self._http.request("GET", SERVERS_PATH), SERVERS_PATH)
        groups = require_list(
            require_field(payload, "wireguard", SERVERS_PATH), "servers.json wireguard"
        )
        if not groups:
            raise ServerListError("IVPN returned no WireGuard server groups")

        found = []
        for group in iter_mappings(groups, "servers.json wireguard"):
            country = str(group.get("country_code") or "")
            city = str(group.get("city") or "")
            hosts = require_list(
                require_field(group, "hosts", "server group"), "server group hosts"
            )
            for host in iter_mappings(hosts, "server group hosts"):
                hostname = str(require_field(host, "hostname", "host"))
                # at1.wg.ivpn.net -> at1, which fits a WireGuard interface
                # name where the full hostname is right at the 15-char limit.
                short = hostname.split(".", 1)[0]
                found.append(
                    Server(
                        name=short,
                        hostname=hostname,
                        pubkey=str(require_field(host, "public_key", "host")),
                        endpoint_ip=str(require_field(host, "host", "host")),
                        port=self.default_port,
                        country=country,
                        city=city,
                    )
                )

        if not found:
            raise ServerListError("IVPN's server list contains no WireGuard hosts")
        return filter_servers(found, filt)
