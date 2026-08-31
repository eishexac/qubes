"""`wgq peer import` end to end: what it must refuse, and what it must survive.

These run the real CLI entry point against a temp state directory
(WGQ_STATE_DIR), because the refusals are part of the security design:
key material must never ride through the management qube inside an
imported config, silently or otherwise.
"""

import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from wgq import cli
from wgq.peers import PLACEHOLDER

KEY = "iEXVh4hPZ0fUgL/uUEDaCyGLmXhrWmvB0aDOTOZWSiw="


class TestPeerImport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.environ["WGQ_STATE_DIR"] = self.tmp.name
        self.addCleanup(os.environ.pop, "WGQ_STATE_DIR", None)

    def _conf(self, text: str) -> str:
        path = Path(self.tmp.name) / "imported.conf"
        path.write_text(text, encoding="ascii")
        return str(path)

    def _run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_dual_stack_config_imports_the_ipv4_half(self):
        # Provider-generated configs routinely carry v4+v6 lists; wgq is
        # IPv4-only and must take the v4 member, not choke on the v6 one.
        conf = self._conf(
            "[Interface]\n"
            f"PrivateKey = {PLACEHOLDER}\n"
            "Address = 10.66.1.2/32, fc00::2/128\n"
            "DNS = fc00::1, 10.64.0.1\n"
            "MTU = 1420\n"
            "[Peer]\n"
            f"PublicKey = {KEY}\n"
            "AllowedIPs = 0.0.0.0/0\n"
            "Endpoint = 185.65.135.170:51820\n"
            "PersistentKeepalive = 25\n"
        )
        code, out, err = self._run(
            ["peer", "import", conf, "--zone", "home", "--name", "home-gw"]
        )
        self.assertEqual(code, 0, err)
        meta = (
            Path(self.tmp.name) / "zones" / "home" / "peers" / "home-gw.meta"
        ).read_text()
        self.assertIn("address=10.66.1.2/32", meta)
        self.assertIn("dns=10.64.0.1", meta)
        # Dropped knobs are named on stderr, never silently eaten.
        self.assertIn("mtu", err)
        self.assertIn("persistentkeepalive", err)

    def test_refuses_a_preshared_key(self):
        # A PSK is key material; it must never be stored, forwarded, or
        # silently dropped so the tunnel fails later with no explanation.
        conf = self._conf(
            "[Interface]\n"
            f"PrivateKey = {PLACEHOLDER}\n"
            "Address = 10.66.1.2/32\n"
            "DNS = 10.64.0.1\n"
            "[Peer]\n"
            f"PublicKey = {KEY}\n"
            f"PresharedKey = {KEY}\n"
            "Endpoint = 185.65.135.170:51820\n"
        )
        code, out, err = self._run(
            ["peer", "import", conf, "--zone", "home", "--name", "home-gw"]
        )
        self.assertEqual(code, 1)
        self.assertIn("PresharedKey", err)
        peers = Path(self.tmp.name) / "zones" / "home" / "peers"
        self.assertFalse(
            peers.exists() and any(peers.iterdir()), "refusal must write nothing"
        )

    def test_refuses_a_real_private_key(self):
        conf = self._conf(
            "[Interface]\n"
            f"PrivateKey = {KEY}\n"
            "Address = 10.66.1.2/32\n"
            "DNS = 10.64.0.1\n"
            "[Peer]\n"
            f"PublicKey = {KEY}\n"
            "Endpoint = 185.65.135.170:51820\n"
        )
        code, out, err = self._run(
            ["peer", "import", conf, "--zone", "home", "--name", "home-gw"]
        )
        self.assertEqual(code, 1)
        self.assertIn("PrivateKey", err)

    def test_ipv6_only_config_fails_loudly(self):
        conf = self._conf(
            "[Interface]\n"
            f"PrivateKey = {PLACEHOLDER}\n"
            "Address = fc00::2/128\n"
            "DNS = fc00::1\n"
            "[Peer]\n"
            f"PublicKey = {KEY}\n"
            "Endpoint = 185.65.135.170:51820\n"
        )
        code, out, err = self._run(
            ["peer", "import", conf, "--zone", "home", "--name", "home-gw",
             "--dns", "10.64.0.1"]
        )
        self.assertEqual(code, 1)
        self.assertIn("IPv4", err)

    def test_missing_file_is_one_line_not_a_traceback(self):
        code, out, err = self._run(
            ["peer", "import", "/nowhere/wg0.conf", "--zone", "home", "--name", "x"]
        )
        self.assertEqual(code, 1)
        self.assertIn("cannot read", err)


if __name__ == "__main__":
    unittest.main()
