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
