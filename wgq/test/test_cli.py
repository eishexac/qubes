"""Entry-point guards.

wgq runs in two qubes and in neither case is one of them dom0. The check
lives in main() rather than in each command so that a subcommand added later
inherits it, and this test is what keeps that true.
"""

import io
import unittest
from contextlib import redirect_stderr, redirect_stdout

from wgq import cli


class TestDom0Refusal(unittest.TestCase):
    def setUp(self):
        self._real = cli.looks_like_dom0
        cli.looks_like_dom0 = lambda: True

    def tearDown(self):
        cli.looks_like_dom0 = self._real

    def _run(self, argv):
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            code = cli.main(argv)
        return code, err.getvalue()

    def test_every_subcommand_refuses_in_dom0(self):
        # Each of these previously had to remember the guard for itself.
        # servers in particular would have made HTTPS requests from dom0.
        invocations = [
            ["servers"],
            ["provision", "--zone", "work", "--pubkey", "x"],
            ["peer", "list", "--zone", "work"],
            ["peer", "rm", "--zone", "work", "name"],
            ["firewall", "--zone", "work"],
            ["devices"],
            ["account"],
            ["revoke", "--pubkey", "x"],
            ["rotate", "--old-pubkey", "x", "--pubkey", "y"],
            ["keygen"],
            ["pubkey"],
            ["apply", "/tmp/nowhere"],
            ["switch", "peer"],
            ["status"],
        ]
        for argv in invocations:
            with self.subTest(argv=argv):
                code, err = self._run(argv)
                self.assertEqual(code, 1, f"{argv} did not refuse")
                self.assertIn("dom0", err.lower())

    def test_the_guard_is_not_simply_always_on(self):
        # A refusal that fires everywhere would pass the test above while
        # making the tool useless, so confirm it depends on the detection.
        cli.looks_like_dom0 = lambda: False
        code, err = self._run(["peer", "list", "--zone", "work"])
        self.assertNotIn("must never run in dom0", err)


class TestZoneNames(unittest.TestCase):
    def test_normal_zones_are_suffixed(self):
        self.assertEqual(cli.vm_for_zone("work"), "sys-wgq-work")

    def test_reserved_singleton_zone_collapses_the_stutter(self):
        # zone 'wgq' is the single-VPN-for-everything default; its VPN
        # qube is the bare sys-wgq, never sys-wgq-wgq.
        self.assertEqual(cli.vm_for_zone("wgq"), "sys-wgq")


class TestDom0Detection(unittest.TestCase):
    def test_detection_needs_both_signals(self):
        # dom0 ships qrexec-client; VMs ship qrexec-client-vm. Presence of
        # /etc/qubes-release alone is true in every qube, so it cannot be
        # the only signal or wgq would refuse to run anywhere.
        import wgq.qrexec as qrexec

        real_available = qrexec.available
        real_isfile = cli.Path.is_file
        try:
            qrexec.available = lambda: True  # a VM
            cli.Path.is_file = lambda self: True
            self.assertFalse(cli.looks_like_dom0())

            qrexec.available = lambda: False  # dom0
            self.assertTrue(cli.looks_like_dom0())
        finally:
            qrexec.available = real_available
            cli.Path.is_file = real_isfile


if __name__ == "__main__":
    unittest.main()


class TestJsonOutput(unittest.TestCase):
    """--json emits exactly one parseable document on stdout.

    Stdout purity is load-bearing: the dom0 pickers and wgq verify will
    parse this without filtering, and the framing-on-stdout bug (#43)
    is the cautionary tale for letting anything else leak in.
    """

    def run_cli(self, argv, env):
        import contextlib
        import os as _os

        old = {k: _os.environ.get(k) for k in env}
        _os.environ.update(env)
        out, err = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(out), redirect_stderr(err):
                with contextlib.suppress(SystemExit):
                    code = cli.main(argv)
        finally:
            for k, v in old.items():
                if v is None:
                    _os.environ.pop(k, None)
                else:
                    _os.environ[k] = v
        return code, out.getvalue(), err.getvalue()

    def test_peer_list_json_is_pure_and_complete(self):
        import json
        import tempfile

        from wgq.peers import Peer, PeerDir

        with tempfile.TemporaryDirectory() as tmp:
            peers = PeerDir(f"{tmp}/zones/t/peers")
            peers.ensure()
            peers.save(
                Peer(
                    name="se-mma-wg-001",
                    provider="mullvad",
                    address="10.66.1.2/32",
                    server_pubkey="X5yVvKMhFH6Grup699IfUn/RJ2XA9NkzHTbXilLBNBI=",
                    endpoint_ip="185.65.135.170",
                    endpoint_port=51820,
                    dns="10.64.0.1",
                )
            )
            code, out, _ = self.run_cli(
                ["peer", "list", "--zone", "t", "--json"], {"WGQ_STATE_DIR": tmp}
            )
            self.assertEqual(code, 0)
            data = json.loads(out)  # would raise on ANY stray stdout text
            self.assertEqual(len(data), 1)
            row = data[0]
            self.assertEqual(row["name"], "se-mma-wg-001")
            self.assertEqual(row["endpoint"], "185.65.135.170:51820")
            self.assertEqual(row["dns"], "10.64.0.1")

    def test_peer_list_json_empty_zone_is_empty_document(self):
        import json
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            code, out, _ = self.run_cli(
                ["peer", "list", "--zone", "empty", "--json"], {"WGQ_STATE_DIR": tmp}
            )
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out), [])
