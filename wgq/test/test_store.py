"""apply_bundle installs what was VALIDATED, never what was received.

wg-quick executes PostUp/PreUp/PostDown lines as root. If the bundle's
conf text were written verbatim, a compromised wgq-mgmt could ship
`PostUp = <anything>` and own every zone qube at the next tunnel start
— found by external review. The contract pinned here: the received
bytes prove their origin (the placeholder) and are then discarded; the
installed conf is re-rendered from the validated Peer alone.
"""

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from wgq import store
from wgq.peers import Peer, PeerDir

KEY = "X5yVvKMhFH6Grup699IfUn/RJ2XA9NkzHTbXilLBNBI="


class TestApplyBundleRenders(unittest.TestCase):
    def test_injected_directives_never_reach_the_installed_conf(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "peers"
            peers = PeerDir(bundle)
            peers.ensure()
            peers.save(
                Peer(
                    name="se-mma-wg-001",
                    provider="mullvad",
                    address="10.66.1.2/32",
                    server_pubkey=KEY,
                    endpoint_ip="185.65.135.170",
                    endpoint_port=51820,
                    dns="10.64.0.1",
                )
            )
            # a hostile mgmt appends root execution to the valid conf
            conf = peers.conf_path("se-mma-wg-001")
            conf.write_text(
                conf.read_text() + "PostUp = /usr/bin/touch /rw/owned\n"
            )

            target = Path(tmp) / "installed"
            with mock.patch.object(store, "require_root"), mock.patch.object(
                store, "require_zone_qube"
            ), mock.patch.object(store, "has_key", return_value=True), mock.patch.object(
                store, "_read_private_key", return_value="SECRETKEY"
            ), mock.patch.object(store, "ensure_dirs"), mock.patch.object(
                store, "peer_dir", return_value=PeerDir(target, dir_mode=0o700)
            ):
                PeerDir(target, dir_mode=0o700).ensure()
                installed = store.apply_bundle(bundle)

            self.assertEqual(installed, ["se-mma-wg-001"])
            written = (target / "se-mma-wg-001.conf").read_text()
            self.assertNotIn("PostUp", written)
            self.assertNotIn("touch", written)
            self.assertIn("SECRETKEY", written)
            self.assertIn("185.65.135.170:51820", written)

    def test_a_conf_without_the_placeholder_is_refused_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "peers"
            peers = PeerDir(bundle)
            peers.ensure()
            peers.save(
                Peer(
                    name="se-mma-wg-001",
                    provider="mullvad",
                    address="10.66.1.2/32",
                    server_pubkey=KEY,
                    endpoint_ip="185.65.135.170",
                    endpoint_port=51820,
                    dns="10.64.0.1",
                )
            )
            conf = peers.conf_path("se-mma-wg-001")
            conf.write_text(conf.read_text().replace(store.PLACEHOLDER, KEY))
            with mock.patch.object(store, "require_root"), mock.patch.object(
                store, "require_zone_qube"
            ), mock.patch.object(store, "has_key", return_value=True):
                with self.assertRaises(Exception):
                    store.apply_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
