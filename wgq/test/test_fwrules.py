"""The layer-1 allowlist.

These assertions encode decisions that are easy to undo by accident, so they
are written as "must not" as often as "must".
"""

import unittest

from wgq import fwrules
from wgq.errors import UsageError
from wgq.peers import Peer

KEY = "iEXVh4hPZ0fUgL/uUEDaCyGLmXhrWmvB0aDOTOZWSiw="


def peer(name, ip, port=51820):
    return Peer(
        name=name,
        provider="mullvad",
        address="10.66.1.2/32",
        server_pubkey=KEY,
        endpoint_ip=ip,
        endpoint_port=port,
        dns="10.64.0.1",
    )


PEERS = [peer("se-mma-wg-001", "185.65.135.170"), peer("se-got-wg-002", "193.138.218.74")]


class TestApiRules(unittest.TestCase):
    def test_one_accept_per_endpoint_then_drop(self):
        rules = fwrules.api_rules(PEERS)
        self.assertEqual(
            rules,
            [
                "action=accept dst4=185.65.135.170/32 proto=udp dstports=51820-51820",
                "action=accept dst4=193.138.218.74/32 proto=udp dstports=51820-51820",
                "action=drop",
            ],
        )

    def test_dstports_renders_as_a_range(self):
        # qubes/firewall.py serialises dstports as "low-high" even for a
        # single port; a bare port would not round-trip.
        self.assertIn("dstports=51820-51820", fwrules.api_rules(PEERS)[0])

    def test_duplicate_endpoints_collapse(self):
        dupes = [peer("a", "185.65.135.170"), peer("b", "185.65.135.170")]
        self.assertEqual(len(fwrules.api_rules(dupes)), 2)  # one accept + drop

    def test_distinct_ports_are_kept_apart(self):
        mixed = [peer("a", "185.65.135.170"), peer("b", "185.65.135.170", port=2049)]
        rules = fwrules.api_rules(mixed)
        self.assertIn("dstports=51820-51820", rules[0])
        self.assertIn("dstports=2049-2049", rules[1])

    def test_no_dns_hole(self):
        # Every endpoint is numeric, Qubes VMs get time from dom0 over qrexec
        # and updates through the qrexec proxy, so the VPN qube never needs
        # to resolve anything. An open DNS rule would be a UDP side channel.
        joined = " ".join(fwrules.api_rules(PEERS))
        self.assertNotIn("dns", joined)
        self.assertNotIn("specialtarget", joined)

    def test_no_icmp_rule(self):
        # The trailing drop already covers ICMP.
        self.assertNotIn("icmp", " ".join(fwrules.api_rules(PEERS)))

    def test_empty_refuses_rather_than_emitting_a_bare_drop(self):
        with self.assertRaises(UsageError):
            fwrules.api_rules([])


class TestManualBlock(unittest.TestCase):
    def setUp(self):
        self.text = fwrules.qvm_firewall_block("sys-wgq-work", PEERS)

    def test_uses_the_four_command_sequence(self):
        self.assertIn("qvm-firewall sys-wgq-work reset", self.text)
        self.assertIn("qvm-firewall sys-wgq-work del --rule-no 0", self.text)
        self.assertEqual(self.text.count("add accept"), len(PEERS))

    def test_does_not_renumber_around_an_icmp_rule(self):
        # `reset` installs exactly one rule (action=accept), so there is no
        # `accept icmp` line to find and no --before juggling to do.
        self.assertNotIn("--before", self.text)
        self.assertNotIn("accept icmp", self.text)

    def test_warns_to_halt_the_qube_first(self):
        self.assertIn("HALTED", self.text)

    def test_shows_the_expected_final_state(self):
        self.assertIn("185.65.135.170", self.text)
        self.assertIn("193.138.218.74", self.text)


if __name__ == "__main__":
    unittest.main()
