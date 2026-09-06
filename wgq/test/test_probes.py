"""The DNS wire code in verify-probes must be strict.

The probe replaces dig precisely because dig's stdout lied to the
verifier; the replacement earns that trust only if anything short of a
well-formed NOERROR answer to our own query id counts as no answer.
"""

import importlib.util
import struct
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "verify_probes", Path(__file__).parent.parent / "dom0" / "verify-probes.py"
)
probes = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(probes)

TID = 0x5747


def response(
    tid=TID, flags=0x8180, answers=(("1.2.3.4", 1, 1),), name="example.com"
):
    """A DNS response whose answers use a compression pointer to the
    question name -- the layout real resolvers actually send."""
    q = b"".join(
        bytes([len(label)]) + label.encode() for label in name.split(".")
    ) + b"\x00" + struct.pack(">HH", 1, 1)
    out = struct.pack(">HHHHHH", tid, flags, 1, len(answers), 0, 0) + q
    for addr, rtype, rclass in answers:
        rdata = bytes(int(o) for o in addr.split("."))
        out += b"\xc0\x0c" + struct.pack(">HHIH", rtype, rclass, 60, len(rdata)) + rdata
    return out


class TestBuildQuery(unittest.TestCase):
    def test_query_layout(self):
        q = probes.build_query("example.com", TID)
        tid, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", q[:12])
        self.assertEqual((tid, flags, qd, an, ns, ar), (TID, 0x0100, 1, 0, 0, 0))
        self.assertTrue(q.endswith(b"\x00" + struct.pack(">HH", 1, 1)))
        self.assertIn(b"\x07example\x03com", q)


class TestParseAnswers(unittest.TestCase):
    def test_accepts_a_real_answer(self):
        self.assertEqual(probes.parse_answers(response(), TID), ["1.2.3.4"])

    def test_multiple_a_records(self):
        data = response(answers=(("1.2.3.4", 1, 1), ("5.6.7.8", 1, 1)))
        self.assertEqual(probes.parse_answers(data, TID), ["1.2.3.4", "5.6.7.8"])

    def test_rejects_wrong_transaction_id(self):
        with self.assertRaises(ValueError):
            probes.parse_answers(response(tid=0x1111), TID)

    def test_rejects_error_rcode(self):
        # NXDOMAIN and SERVFAIL are what a hijacking or broken resolver
        # returns; neither may ever count as an answer.
        for rcode in (2, 3):
            with self.assertRaises(ValueError):
                probes.parse_answers(response(flags=0x8180 | rcode), TID)

    def test_rejects_non_a_records(self):
        with self.assertRaises(ValueError):
            probes.parse_answers(response(answers=(("9.9.9.9", 5, 1),)), TID)

    def test_rejects_queries_and_junk(self):
        with self.assertRaises(ValueError):
            probes.parse_answers(response(flags=0x0100), TID)  # not a response
        with self.assertRaises(ValueError):
            probes.parse_answers(b"\x00\x01", TID)  # short


if __name__ == "__main__":
    unittest.main()
