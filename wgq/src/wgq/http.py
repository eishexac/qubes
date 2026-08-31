"""Minimal JSON-over-HTTPS client built on the standard library.

wgq has no third-party dependencies.  The qube that holds the account
credential should need nothing from pip, and a REST client is not enough
code to justify making that qube harder to build.

Every response is validated by the caller before it reaches a config file
or a firewall rule; this module only guarantees that a non-2xx status or a
non-JSON body raises instead of returning something plausible.
"""

from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable, Mapping, Sequence

from . import __version__
from .errors import ProviderError

USER_AGENT = f"wgq/{__version__}"
DEFAULT_TIMEOUT = 20.0
_SNIPPET = 240
# A response bigger than this is not an answer wgq has any use for; reading
# it whole would let a broken or hostile endpoint balloon the process.
# Mullvad's full relay list is on the order of 2 MB, so 10 MB is generous.
MAX_BODY = 10 * 1024 * 1024
_ERROR_BODY_CAP = 64 * 1024


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Turn any redirect into an error instead of following it.

    urllib's default handler follows redirects cross-host and even from
    https to plain http, forwarding the Authorization header as it goes --
    which would quietly void the https-only guarantee the constructor
    enforces.  No API wgq talks to redirects in normal operation, so the
    only safe meaning of a 3xx here is "something is wrong": surface it.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HttpError(ProviderError):
    """A request completed but with a status we did not expect."""

    def __init__(self, method: str, url: str, status: int, body: str) -> None:
        self.status = status
        self.body = body
        super().__init__(f"{method} {url} -> HTTP {status}: {body[:_SNIPPET]}")


class Http:
    """A small, strict HTTPS client scoped to one API base URL.

    Strings registered with :meth:`redact` are scrubbed from every error
    message this client raises.  Account numbers and bearer tokens are
    registered as soon as they are known, so that a provider echoing a
    credential back in an error body cannot put it in a traceback.
    """

    def __init__(self, base_url: str, timeout: float = DEFAULT_TIMEOUT) -> None:
        if not base_url.startswith("https://"):
            raise ProviderError(f"refusing a non-HTTPS API base URL: {base_url!r}")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._ctx = ssl.create_default_context()
        self._opener = urllib.request.build_opener(
            _RefuseRedirects(), urllib.request.HTTPSHandler(context=self._ctx)
        )
        self._secrets: list[str] = []

    def redact(self, *secrets: str) -> None:
        for secret in secrets:
            if secret and len(secret) >= 6 and secret not in self._secrets:
                self._secrets.append(secret)

    def _scrub(self, text: str) -> str:
        for secret in self._secrets:
            text = text.replace(secret, "<redacted>")
        return text

    def _url(self, path: str) -> str:
        if path.startswith("https://"):
            return path
        return f"{self.base_url}/{path.lstrip('/')}"

    def request(
        self,
        method: str,
        path: str,
        *,
        json_body: Any = None,
        form: Mapping[str, str] | None = None,
        headers: Mapping[str, str] | None = None,
        expect: Sequence[int] = (200, 201),
    ) -> Any:
        """Perform a request and return the decoded JSON body.

        Returns ``None`` for a success with an empty body (204, and the
        bodiless 200 some delete endpoints return).
        """
        url = self._url(path)
        data: bytes | None = None
        request_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}

        if json_body is not None and form is not None:
            raise ProviderError("internal: pass json_body or form, not both")
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        elif form is not None:
            data = urllib.parse.urlencode(form).encode("utf-8")
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
        if headers:
            request_headers.update(headers)

        req = urllib.request.Request(url, data=data, headers=request_headers, method=method)

        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                status = resp.status
                raw = resp.read(MAX_BODY + 1)
        except urllib.error.HTTPError as exc:
            body = ""
            try:
                body = exc.read(_ERROR_BODY_CAP).decode("utf-8", "replace")
            except Exception:  # noqa: BLE001 - the status matters, the body is a nicety
                pass
            raise HttpError(method, self._scrub(url), exc.code, self._scrub(body)) from None
        except urllib.error.URLError as exc:
            raise ProviderError(
                f"{method} {self._scrub(url)}: {self._scrub(str(exc.reason))}"
            ) from None
        except OSError as exc:
            raise ProviderError(f"{method} {self._scrub(url)}: {exc}") from None

        if len(raw) > MAX_BODY:
            raise ProviderError(
                f"{method} {self._scrub(url)}: response exceeded {MAX_BODY} bytes"
            )
        if status not in expect:
            raise HttpError(method, self._scrub(url), status, self._scrub(raw.decode("utf-8", "replace")))

        text = raw.decode("utf-8", "replace").strip()
        if not text:
            return None
        try:
            return json.loads(text)
        except ValueError:
            raise ProviderError(
                f"{method} {self._scrub(url)}: response was not JSON: "
                f"{self._scrub(text)[:_SNIPPET]}"
            ) from None

def require_mapping(value: Any, what: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ProviderError(f"{what}: expected a JSON object, got {type(value).__name__}")
    return value


def require_list(value: Any, what: str) -> list[Any]:
    if not isinstance(value, list):
        raise ProviderError(f"{what}: expected a JSON array, got {type(value).__name__}")
    return value


def require_field(obj: Mapping[str, Any], key: str, what: str) -> Any:
    if key not in obj:
        raise ProviderError(f"{what}: response is missing {key!r}; refusing to guess")
    return obj[key]


def iter_mappings(values: Iterable[Any], what: str) -> Iterable[Mapping[str, Any]]:
    for index, value in enumerate(values):
        yield require_mapping(value, f"{what}[{index}]")
