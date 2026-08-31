"""The Admin API response envelope.

qubesd answers every admin.vm.* call with a status envelope, and the qrexec
exit code is 0 whether the call succeeded or raised -- so this parse is the
only place a dom0-side failure can be detected.  Getting it wrong meant
printing "applied" for rules dom0 refused, which is the exact silent
failure the rest of the project is built to avoid.
"""

import unittest

from wgq import qrexec
from wgq.errors import AdminAPIError


class TestEnvelope(unittest.TestCase):
    def test_success_returns_the_payload(self):
        self.assertEqual(
            qrexec.parse_admin_response("vm", "svc", b"0\x00rule one\nrule two\n"),
            b"rule one\nrule two\n",
        )

    def test_empty_success_payload_is_valid(self):
        # admin.vm.firewall.Set answers with a bare success envelope.
        self.assertEqual(qrexec.parse_admin_response("vm", "svc", b"0\x00"), b"")

    def test_dom0_exception_raises_with_type_and_message(self):
        raw = b"2\x00QubesFirewallError\x00\x00invalid rule %s\x00nonsense\x00"
        with self.assertRaises(AdminAPIError) as ctx:
            qrexec.parse_admin_response("vm", "svc", raw)
        message = str(ctx.exception)
        self.assertIn("QubesFirewallError", message)
        self.assertIn("invalid rule nonsense", message)

    def test_garbage_is_never_interpreted_as_success(self):
        # An empty response, an unknown status byte, and rules arriving
        # without any envelope must all raise: each of these previously
        # looked like success to code that only checked the exit code.
        for raw in (b"", b"1\x00x", b"action=accept dst4=1.2.3.4/32"):
            with self.subTest(raw=raw):
                with self.assertRaises(AdminAPIError):
                    qrexec.parse_admin_response("vm", "svc", raw)

    def test_malformed_exception_body_still_raises(self):
        # A truncated error envelope must not crash the parser into a
        # different exception, and must still be reported as a failure.
        with self.assertRaises(AdminAPIError):
            qrexec.parse_admin_response("vm", "svc", b"2\x00OnlyAType")


class TestRulesEqual(unittest.TestCase):
    RULES = [
        "action=accept dst4=185.65.135.170/32 proto=udp dstports=51820-51820",
        "action=drop",
    ]

    def test_identical_lists_match(self):
        self.assertTrue(qrexec.rules_equal(self.RULES, list(self.RULES)))

    def test_token_reordering_within_a_rule_matches(self):
        # qubesd re-serialises properties in its own order; that is not a
        # difference in the rules.
        reordered = [
            "dst4=185.65.135.170/32 action=accept dstports=51820-51820 proto=udp",
            "action=drop",
        ]
        self.assertTrue(qrexec.rules_equal(self.RULES, reordered))

    def test_rule_order_matters(self):
        # First match wins in the firewall, so a reordered rule LIST is a
        # different policy.
        self.assertFalse(qrexec.rules_equal(self.RULES, list(reversed(self.RULES))))

    def test_different_rules_do_not_match(self):
        changed = [
            "action=accept dst4=185.65.135.171/32 proto=udp dstports=51820-51820",
            "action=drop",
        ]
        self.assertFalse(qrexec.rules_equal(self.RULES, changed))
        self.assertFalse(qrexec.rules_equal(self.RULES, self.RULES[:1]))


if __name__ == "__main__":
    unittest.main()
