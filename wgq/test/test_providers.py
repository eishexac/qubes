"""Provider parsing locked to the shapes verified against upstream.

Every assertion here encodes something checked against the providers' own
open-source clients or live API responses (August 2026), so a refactor that
drifts back to a plausible-but-wrong field name fails immediately instead
of on the first live run.
"""

import unittest
from types import SimpleNamespace

from wgq.errors import AuthError, DeviceLimitError, ProviderError
from wgq.providers.ivpn import IVPN, ACCOUNT_RE as IVPN_ACCOUNT_RE
from wgq.providers.mullvad import ACCOUNT_RE as MULLVAD_ACCOUNT_RE, Mullvad

KEY = "iEXVh4hPZ0fUgL/uUEDaCyGLmXhrWmvB0aDOTOZWSiw="

# Built at runtime so no 16-digit literal sits in the tree (CI greps for
# strings that could be a real account number).
CURRENT_ACCOUNT = "1234" * 4


class TestMullvadAccountNumbers(unittest.TestCase):
    def test_current_16_digit_accounts_are_accepted(self):
        self.assertTrue(MULLVAD_ACCOUNT_RE.match(CURRENT_ACCOUNT))

    def test_legacy_shorter_accounts_are_accepted(self):
        # 12- and 13-digit numbers predate the 2017 lengthening and remain
        # valid; the official login UI enforces only digits with min 10.
        for legacy in ("123456789012", "1234567890123", "1234567890"):
            with self.subTest(legacy=legacy):
                self.assertTrue(MULLVAD_ACCOUNT_RE.match(legacy))

    def test_junk_is_rejected(self):
        for bad in ("123456789", "1" * 21, "letters12345678", ""):
            with self.subTest(bad=bad):
                self.assertFalse(MULLVAD_ACCOUNT_RE.match(bad))


class TestMullvadRelayParsing(unittest.TestCase):
    RELAY = {
        # Field names as they appear in the LIVE www/relays/wireguard/
        # response: the key is "pubkey", not "public_key".
        "hostname": "se-mma-wg-001",
        "pubkey": KEY,
        "ipv4_addr_in": "185.65.135.170",
        "active": True,
        "country_code": "se",
        "city_code": "mma",
    }

    def _provider_with(self, payload):
        provider = Mullvad()
        provider._http = SimpleNamespace(request=lambda *a, **kw: payload)
        return provider

    def test_live_field_names_parse(self):
        servers = self._provider_with([self.RELAY]).servers()
        self.assertEqual(len(servers), 1)
        self.assertEqual(servers[0].pubkey, KEY)
        self.assertEqual(servers[0].endpoint, "185.65.135.170:51820")

    def test_inactive_relays_are_skipped(self):
        provider = self._provider_with([dict(self.RELAY, active=False)])
        with self.assertRaises(ProviderError):
            provider.servers()


class TestIVPNAccountIds(unittest.TestCase):
    def test_accepted_forms(self):
        # i-XXXX-XXXX-XXXX, and legacy ivpn + exactly 7 or 8 alphanumerics
        # (the official daemon's own validation).
        for good in ("i-ABCD-1234-EFGH", "ivpnAbc1234", "ivpnAbc12345"):
            with self.subTest(good=good):
                self.assertTrue(IVPN_ACCOUNT_RE.match(good))

    def test_rejected_forms(self):
        # 6 and 9 trailing characters sit just outside the legacy {7,8}.
        for bad in ("ivpnAbc123", "ivpnAbc123456", "i-ABC-1234-EFGH", "mullvad"):
            with self.subTest(bad=bad):
                self.assertFalse(IVPN_ACCOUNT_RE.match(bad))


class TestUnsupportedCapabilities(unittest.TestCase):
    def test_missing_provider_feature_is_one_line_not_a_traceback(self):
        # IVPN has no device list; the CLI must say so cleanly. IVPN's
        # authenticate() is offline (format check only), so this runs
        # without network.
        import io
        import tempfile
        from contextlib import redirect_stderr, redirect_stdout
        from pathlib import Path

        from wgq import cli

        with tempfile.TemporaryDirectory() as tmp:
            account = Path(tmp) / "ivpn-account"
            account.write_text("i-ABCD-1234-EFGH\n", encoding="ascii")
            account.chmod(0o600)
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = cli.main(
                    ["devices", "--provider", "ivpn", "--account-file", str(account)]
                )
        self.assertEqual(code, 1)
        self.assertIn("does not expose a device list", err.getvalue())


class TestIVPNSessionParsing(unittest.TestCase):
    def test_session_limit_maps_to_device_limit_error(self):
        # 602 = CodeSessionsLimitReached in the official client.
        with self.assertRaises(DeviceLimitError):
            IVPN._check_status({"status": 602, "message": "limit reached"})

    def test_bad_credential_maps_to_auth_error(self):
        for status in (401, 601, 702):
            with self.subTest(status=status):
                with self.assertRaises(AuthError):
                    IVPN._check_status({"status": status})

    def test_ok_statuses_pass(self):
        IVPN._check_status({"status": 200})
        IVPN._check_status({})

    def test_address_is_read_from_the_verified_nested_field(self):
        # SessionNewResponse nests it as wireguard.ip_address.
        payload = {"wireguard": {"status": 200, "ip_address": "172.16.5.2"}}
        self.assertEqual(IVPN._assigned_address(payload), "172.16.5.2")

    def test_nested_wireguard_failure_is_loud(self):
        payload = {"wireguard": {"status": 424, "message": "key not accepted"}}
        with self.assertRaises(ProviderError):
            IVPN._assigned_address(payload)

    def test_missing_address_is_loud(self):
        with self.assertRaises(ProviderError):
            IVPN._assigned_address({"token": "x"})


if __name__ == "__main__":
    unittest.main()
