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

    def test_rejects_truncation_inside_an_rr_header(self):
        # A packet cut mid-answer must be "no answer", never a crash:
        # struct.error escaping the parser once let a crashed kill probe
        # read as a clean round.
        data = response()
        with self.assertRaises(ValueError):
            probes.parse_answers(data[: len(data) - 8], TID)

    def test_rejects_rdlength_beyond_buffer(self):
        data = response()
        # rdlength says 4; deliver 2 bytes of rdata.
        with self.assertRaises(ValueError):
            probes.parse_answers(data[: len(data) - 2], TID)

    def test_rejects_lying_qdcount(self):
        data = response()
        lying = data[:4] + struct.pack(">H", 7) + data[6:]
        with self.assertRaises(ValueError):
            probes.parse_answers(lying, TID)

    def test_rejects_queries_and_junk(self):
        with self.assertRaises(ValueError):
            probes.parse_answers(response(flags=0x0100), TID)  # not a response
        with self.assertRaises(ValueError):
            probes.parse_answers(b"\x00\x01", TID)  # short


class TestParseStun(unittest.TestCase):
    TXID = b"\x01" * 12

    def binding_success(self, ip="185.65.135.170", port=51820, txid=None):
        cookie = probes.STUN_COOKIE
        xport = port ^ (cookie >> 16)
        xaddr = struct.unpack(">I", bytes(int(o) for o in ip.split(".")))[0] ^ cookie
        attr = struct.pack(">HHBBH I", 0x0020, 8, 0, 0x01, xport, xaddr)
        return (
            struct.pack(">HHI", 0x0101, len(attr), cookie)
            + (txid or self.TXID)
            + attr
        )

    def test_xor_mapped_address_round_trips(self):
        ip, port = probes.parse_stun(self.binding_success(), self.TXID)
        self.assertEqual((ip, port), ("185.65.135.170", 51820))

    def test_rejects_foreign_transaction(self):
        with self.assertRaises(ValueError):
            probes.parse_stun(self.binding_success(txid=b"\x02" * 12), self.TXID)

    def test_rejects_a_lying_attribute_length_over_a_short_value(self):
        data = self.binding_success()
        # attribute claims 0xFFFF bytes; only 4 value bytes exist, so the
        # 8-byte XOR-MAPPED payload can never be read -- no answer, not
        # a crash. (A lying alen over a COMPLETE value parses: the slice
        # truncates safely and all eight needed bytes are present.)
        lying = data[:22] + struct.pack(">H", 0xFFFF) + data[24:28]
        with self.assertRaises(ValueError):
            probes.parse_stun(lying, self.TXID)

    def test_rejects_wrong_message_type_and_cookie(self):
        good = self.binding_success()
        for bad in (
            struct.pack(">H", 0x0111) + good[2:],  # error response
            good[:4] + struct.pack(">I", 0xDEADBEEF) + good[8:],  # cookie
        ):
            with self.assertRaises(ValueError):
                probes.parse_stun(bad, self.TXID)

    def test_rejects_response_without_the_attribute(self):
        bare = struct.pack(">HHI", 0x0101, 0, probes.STUN_COOKIE) + self.TXID
        with self.assertRaises(ValueError):
            probes.parse_stun(bare, self.TXID)


if __name__ == "__main__":
    unittest.main()
