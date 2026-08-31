"""The validators are where 'fail loudly' is actually enforced, so they get
the closest tests: every one of these inputs would otherwise reach a config
file or a firewall rule.
"""

import unittest

from wgq.errors import ProviderError
from wgq.validate import (
    is_wg_key,
    require_peer_name,
    require_port,
    require_public_ipv4,
    require_tunnel_address,
    require_wg_key,
)

GOOD_KEY = "iEXVh4hPZ0fUgL/uUEDaCyGLmXhrWmvB0aDOTOZWSiw="


class TestKeys(unittest.TestCase):
    def test_accepts_a_real_key(self):
        self.assertTrue(is_wg_key(GOOD_KEY))
        self.assertEqual(require_wg_key(GOOD_KEY, "k"), GOOD_KEY)

    def test_rejects_wrong_length(self):
        for bad in ("", "x", GOOD_KEY[:-1], GOOD_KEY + "A", "A" * 44):
            with self.subTest(bad=bad):
                self.assertFalse(is_wg_key(bad))

    def test_rejects_non_base64(self):
        self.assertFalse(is_wg_key("!" * 43 + "="))

    def test_rejects_non_string(self):
        self.assertFalse(is_wg_key(None))
        self.assertFalse(is_wg_key(b"x" * 44))


class TestPeerNames(unittest.TestCase):
    def test_accepts_provider_hostnames(self):
        # Mullvad's form, and IVPN's full hostname which is exactly 15.
        for name in ("se-mma-wg-001", "at1", "at1.wg.ivpn.net"):
            with self.subTest(name=name):
                self.assertEqual(require_peer_name(name), name)

    def test_rejects_over_fifteen_chars(self):
        # wg-quick derives the interface name from the file name and caps it
        # here; catching it now beats a wg-quick failure at boot.
        with self.assertRaises(ProviderError):
            require_peer_name("a" * 16)

    def test_rejects_path_traversal(self):
        for name in ("../etc", "a/b", "..", ".", "", "a b"):
            with self.subTest(name=name):
                with self.assertRaises(ProviderError):
                    require_peer_name(name)


class TestAddresses(unittest.TestCase):
    def test_endpoint_must_be_globally_routable(self):
        self.assertEqual(require_public_ipv4("185.65.135.170", "e"), "185.65.135.170")
        for bad in ("10.64.0.1", "127.0.0.1", "192.168.1.1", "224.0.0.1", "0.0.0.0",
                    "169.254.1.1", "240.0.0.1", "255.255.255.255"):
            with self.subTest(bad=bad):
                with self.assertRaises(ProviderError):
                    require_public_ipv4(bad, "e")

    def test_tunnel_address_normalises_to_one_form(self):
        self.assertEqual(require_tunnel_address("10.66.1.2", "a"), "10.66.1.2/32")
        self.assertEqual(require_tunnel_address("10.66.1.2/32", "a"), "10.66.1.2/32")
        self.assertEqual(require_tunnel_address(" 10.66.1.2 ", "a"), "10.66.1.2/32")

    def test_tunnel_address_rejects_a_subnet(self):
        with self.assertRaises(ProviderError):
            require_tunnel_address("10.66.0.0/16", "a")

    def test_ipv6_is_refused_everywhere(self):
        # Qubes disables IPv6 unless every qube in the chain opts in; a
        # mismatch breaks connectivity or leaks, so wgq is IPv4-only.
        for bad in ("fc00::1", "2001:db8::1", "::1"):
            with self.subTest(bad=bad):
                with self.assertRaises(ProviderError):
                    require_tunnel_address(bad, "a")
                with self.assertRaises(ProviderError):
                    require_public_ipv4(bad, "e")


class TestPorts(unittest.TestCase):
    def test_range(self):
        self.assertEqual(require_port("51820", "p"), 51820)
        self.assertEqual(require_port(2049, "p"), 2049)
        for bad in (0, 65536, -1, "x", None):
            with self.subTest(bad=bad):
                with self.assertRaises(ProviderError):
                    require_port(bad, "p")


if __name__ == "__main__":
    unittest.main()
