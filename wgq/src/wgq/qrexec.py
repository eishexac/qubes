"""Admin API access from the management qube, over qrexec.

wgq never runs code in dom0.  The endpoint allowlist is applied with
``admin.vm.firewall.Set``, which dom0 grants to this qube through a policy
file the user installs and can read (``dom0/30-wgq.policy``).

Why this is safer than the qvm-firewall command sequence it replaces, not
merely more convenient: Set replaces the entire rule list in one call and
Qubes reloads it automatically, so there is no window in which a partial
rule set is live and no rule numbers for the operator to miscount.
"""

from __future__ import annotations

import os
import shutil
import subprocess

from .errors import AdminAPIError

_CLIENT_CANDIDATES = (
    "/usr/bin/qrexec-client-vm",
    "/usr/lib/qubes/qrexec-client-vm",
)

# qrexec uses 126 for "refused", which covers both a deny rule and the user
# answering No to an ask prompt.  They are indistinguishable by design.
_DENIED = 126


def client_path() -> str:
    for candidate in _CLIENT_CANDIDATES:
        if os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("qrexec-client-vm")
    if found:
        return found
    raise AdminAPIError(
        "qrexec-client-vm not found. This command must run inside a qube "
        "with qubes-core-agent installed, not in dom0 and not on a plain host."
    )


def available() -> bool:
    try:
        client_path()
    except AdminAPIError:
        return False
    return True


def call(dest: str, service: str, payload: bytes = b"", *, timeout: float = 120.0) -> bytes:
    """Invoke *service* against qube *dest* and return stdout.

    The timeout is generous because an ``ask`` policy blocks here until a
    human answers the dom0 prompt.
    """
    argv = [client_path(), "--", dest, service]
    try:
        proc = subprocess.run(
            argv,
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise AdminAPIError(
            f"{service} on {dest} timed out after {timeout:g}s. "
            "If the dom0 policy says 'ask', the confirmation prompt was not answered."
        ) from None
    except OSError as exc:
        raise AdminAPIError(f"cannot run qrexec-client-vm: {exc}") from None

    if proc.returncode == _DENIED:
        raise AdminAPIError(
            f"{service} on {dest} was refused.\n"
            "Either the dom0 policy does not allow it, or an 'ask' prompt was declined.\n"
            "Check that /etc/qubes/policy.d/30-wgq.policy is installed and that "
            f"{dest} carries the wgq-zone tag:\n"
            f"    qvm-tags {dest} list"
        )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip() or f"exit {proc.returncode}"
        raise AdminAPIError(f"{service} on {dest} failed: {detail}")

    return proc.stdout


def parse_admin_response(dest: str, service: str, raw: bytes) -> bytes:
    """Strip and check the qubesd response envelope.

    qubesd answers every admin.vm.* call with ``b"0\\0" + payload`` on
    success, or ``b"2\\0" + type\\0 + traceback\\0 + format\\0 + args`` on
    failure -- and the qrexec exit code is 0 in *both* cases, because the
    socket service that produced the envelope exited cleanly.  Trusting the
    exit code alone would report "applied" for rules dom0 refused, so this
    parse is load-bearing, not cosmetic.  The wire format follows
    qubesadmin's ``_parse_qubesd_response``.
    """
    if raw[:2] == b"0\x00":
        return raw[2:]
    if raw[:2] == b"2\x00":
        parts = raw[2:].split(b"\x00", 3)
        exc_type = parts[0].decode("ascii", "replace") or "unknown error"
        detail = ""
        if len(parts) == 4:
            fmt = parts[2].decode("utf-8", "replace")
            args = [a.decode("utf-8", "replace") for a in parts[3].split(b"\x00") if a]
            try:
                detail = fmt % tuple(args)
            except (TypeError, ValueError):
                detail = " ".join([fmt, *args]).strip()
        suffix = f": {detail}" if detail else ""
        raise AdminAPIError(f"{service} on {dest} failed in dom0: {exc_type}{suffix}")
    raise AdminAPIError(
        f"{service} on {dest} returned bytes that are not a qubesd response "
        f"(first bytes: {raw[:16]!r}). Refusing to interpret them as success."
    )


def admin_call(dest: str, service: str, payload: bytes = b"") -> bytes:
    """A qrexec call whose response must carry the qubesd envelope."""
    return parse_admin_response(dest, service, call(dest, service, payload))


def firewall_get(vm: str) -> list[str]:
    """Return the qube's current rules in Admin API syntax."""
    raw = admin_call(vm, "admin.vm.firewall.Get").decode("ascii", "replace")
    return [line for line in raw.splitlines() if line.strip()]


def firewall_set(vm: str, rules: list[str]) -> None:
    """Replace the qube's entire rule list.

    Qubes fires ``firewall-changed`` from ``Firewall.save()``, so the new
    rules take effect without a separate reload call.  Callers should still
    read the rules back and compare: this call succeeding proves dom0
    accepted the payload, not that the result is what was intended.
    """
    for rule in rules:
        if not rule.isascii():
            raise AdminAPIError(f"rule contains non-ASCII characters: {rule!r}")
        if "\n" in rule or "\r" in rule:
            raise AdminAPIError(f"rule contains a newline: {rule!r}")
    payload = "".join(f"{rule}\n" for rule in rules).encode("ascii")
    admin_call(vm, "admin.vm.firewall.Set", payload)


def rules_equal(sent: list[str], read_back: list[str]) -> bool:
    """Same rules in the same order; token order within a rule is free.

    qubesd re-serialises properties in its own order, so a literal string
    comparison would false-alarm on cosmetic reordering.
    """

    def normal(rules: list[str]) -> list[frozenset[str]]:
        return [frozenset(rule.split()) for rule in rules]

    return normal(sent) == normal(read_back)
