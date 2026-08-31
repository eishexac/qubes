"""Peer serialisation, file modes, and the things the config must NOT contain."""

import os
import tempfile
import unittest
from pathlib import Path

from wgq.errors import LayoutError, ProviderError
from wgq.peers import PLACEHOLDER, Peer, PeerDir

KEY = "iEXVh4hPZ0fUgL/uUEDaCyGLmXhrWmvB0aDOTOZWSiw="


def make_peer(name="se-mma-wg-001", ip="185.65.135.170", port=51820):
    return Peer(
        name=name,
        provider="mullvad",
        address="10.66.1.2/32",
        server_pubkey=KEY,
        endpoint_ip=ip,
        endpoint_port=port,
        dns="10.64.0.1",
    )


class TestPeer(unittest.TestCase):
    def test_meta_round_trip(self):
        peer = make_peer()
        self.assertEqual(Peer.from_meta(peer.name, peer.meta_text()), peer)

    def test_partial_meta_is_refused(self):
        peer = make_peer()
        lines = [ln for ln in peer.meta_text().splitlines() if not ln.startswith("dns=")]
        with self.assertRaises(LayoutError) as ctx:
            Peer.from_meta(peer.name, "\n".join(lines))
        self.assertIn("dns", str(ctx.exception))

    def test_malformed_meta_is_refused(self):
        with self.assertRaises(LayoutError):
            Peer.from_meta("x", "this is not a key=value line")

    def test_private_resolver_is_allowed(self):
        # The in-tunnel resolver is RFC1918 by design; only the endpoint has
        # to be globally routable.
        self.assertEqual(make_peer().dns, "10.64.0.1")

    def test_resolver_must_still_be_unicast(self):
        # A DNAT rule pointed at multicast, loopback or 0.0.0.0 is not a
        # resolver, it is a misconfiguration that must fail at build time.
        for bad in ("224.0.0.1", "0.0.0.0", "127.0.0.1"):
            with self.subTest(bad=bad):
                with self.assertRaises(ProviderError):
                    Peer(
                        name="x",
                        provider="p",
                        address="10.66.1.2/32",
                        server_pubkey=KEY,
                        endpoint_ip="185.65.135.170",
                        endpoint_port=51820,
                        dns=bad,
                    )

    def test_config_omits_dns_line(self):
        # wg-quick applies DNS= through resolvconf, which Debian minimal
        # does not ship; the tunnel would fail to come up.
        text = make_peer().conf_text()
        for line in text.splitlines():
            self.assertFalse(
                line.strip().lower().startswith("dns ="),
                f"config must not carry a DNS= line: {line!r}",
            )

    def test_config_has_no_ipv6(self):
        text = make_peer().conf_text()
        self.assertNotIn("::", text)
        self.assertIn("AllowedIPs = 0.0.0.0/0", text)

    def test_config_endpoint_is_numeric(self):
        # qvm-firewall resolves hostnames when a rule takes effect, which is
        # unreliable against load-balanced names.
        self.assertIn("Endpoint = 185.65.135.170:51820", make_peer().conf_text())

    def test_config_carries_the_placeholder_by_default(self):
        self.assertIn(f"PrivateKey = {PLACEHOLDER}", make_peer().conf_text())


class TestPeerDir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = PeerDir(Path(self.tmp.name) / "peers")

    def tearDown(self):
        self.tmp.cleanup()

    def test_save_and_load(self):
        peer = make_peer()
        self.dir.save(peer)
        self.assertEqual(self.dir.names(), [peer.name])
        self.assertEqual(self.dir.load(peer.name), peer)

    def test_config_is_created_private(self):
        peer = make_peer()
        self.dir.save(peer)
        mode = os.stat(self.dir.conf_path(peer.name)).st_mode & 0o777
        self.assertEqual(mode, 0o600, "a config may hold a private key")
        self.assertEqual(os.stat(self.dir.root).st_mode & 0o777, 0o700)

    def test_load_all_is_sorted_and_complete(self):
        for name in ("se-mma-wg-001", "at1", "de-fra-wg-009"):
            self.dir.save(make_peer(name=name))
        self.assertEqual(
            [p.name for p in self.dir.load_all()],
            ["at1", "de-fra-wg-009", "se-mma-wg-001"],
        )

    def test_missing_meta_is_an_error_not_a_default(self):
        with self.assertRaises(LayoutError):
            self.dir.load("nope")

    def test_remove(self):
        peer = make_peer()
        self.dir.save(peer)
        self.dir.remove(peer.name)
        self.assertEqual(self.dir.names(), [])

    def test_save_survives_a_stale_tmp_file(self):
        # A crashed earlier run may leave <name>.conf.tmp behind; the next
        # save must clear it and still write through its own O_EXCL fd.
        peer = make_peer()
        self.dir.ensure()
        stale = self.dir.root / f"{peer.name}.conf.tmp"
        stale.write_text("stale")
        self.dir.save(peer)
        self.assertFalse(stale.exists())
        self.assertEqual(self.dir.load(peer.name), peer)
        mode = os.stat(self.dir.conf_path(peer.name)).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_dir_mode_is_configurable(self):
        # The zone qube passes 0o755 so unprivileged status can read
        # metadata; the default stays private for the mgmt records.
        readable = PeerDir(Path(self.tmp.name) / "zone", dir_mode=0o755)
        readable.ensure()
        self.assertEqual(os.stat(readable.root).st_mode & 0o777, 0o755)
        self.dir.ensure()
        self.assertEqual(os.stat(self.dir.root).st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
