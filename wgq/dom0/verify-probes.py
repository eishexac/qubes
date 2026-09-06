#!/usr/bin/env python3
"""Leak probes, pushed into a client qube by `wgq verify`.

Runs on the Python standard library alone, because the client must need
NOTHING installed: every template ships python3, and runtime-installed
tools (dig, curl) die with the qube -- re-installing them was half the
pain this orchestrator exists to remove.  Building the DNS query
ourselves also permanently retires the dig-stdout class of false
positive: either we parse a real answer out of the bytes, or there is
no answer.

Output contract: exactly one JSON document on stdout, diagnostics on
stderr, like every other machine interface in wgq.

    verify-probes.py exitip
    verify-probes.py dnscheck <resolver|system> [name]
    verify-probes.py killcheck <endpoint_ip> <endpoint_port>
"""

import json
import socket
import struct
import sys
import urllib.request

TIMEOUT = 6.0
DNS_TIMEOUT = 3.0


# -- raw DNS ----------------------------------------------------------------


def build_query(name: str, tid: int) -> bytes:
    header = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    question = b"".join(
        bytes([len(label)]) + label.encode("ascii") for label in name.split(".")
    )
    return header + question + b"\x00" + struct.pack(">HH", 1, 1)  # A, IN


def skip_name(data: bytes, off: int) -> int:
    """Return the offset just past a (possibly compressed) name."""
    while True:
        if off >= len(data):
            raise ValueError("truncated name")
        length = data[off]
        if length == 0:
            return off + 1
        if length & 0xC0 == 0xC0:  # compression pointer: 2 bytes, ends name
            return off + 2
        off += 1 + length


def parse_answers(data: bytes, tid: int) -> list[str]:
    """A-record addresses from a response, or a ValueError.

    Anything that is not a well-formed NOERROR answer to OUR query id
    counts as no answer at all -- the strictness is the point.
    """
    if len(data) < 12:
        raise ValueError("short response")
    rtid, flags, qdcount, ancount = struct.unpack(">HHHH", data[:8])
    if rtid != tid:
        raise ValueError("transaction id mismatch")
    if not flags & 0x8000:
        raise ValueError("not a response")
    if flags & 0x000F:
        raise ValueError(f"rcode {flags & 0x000F}")
    off = 12
    try:
        for _ in range(qdcount):
            off = skip_name(data, off) + 4
        addresses = []
        for _ in range(ancount):
            off = skip_name(data, off)
            rtype, rclass, _ttl, rdlength = struct.unpack(
                ">HHIH", data[off : off + 10]
            )
            off += 10
            rdata = data[off : off + rdlength]
            off += rdlength
            if len(rdata) != rdlength:
                raise ValueError("truncated rdata")
            if rtype == 1 and rclass == 1 and rdlength == 4:
                addresses.append(".".join(str(b) for b in rdata))
    except struct.error as exc:  # truncated packet: not an answer
        raise ValueError(f"truncated response: {exc}") from None
    if not addresses:
        raise ValueError("no A records")
    return addresses


def system_resolvers() -> list[str]:
    servers = []
    try:
        with open("/etc/resolv.conf", encoding="ascii", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver" and "." in parts[1]:
                    servers.append(parts[1])
    except OSError:
        pass
    return servers or ["10.139.1.1"]


def dns_probe(server: str, name: str) -> dict:
    tid = 0x5747  # fixed id: one query per socket, nothing to collide with
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(DNS_TIMEOUT)
    try:
        sock.sendto(build_query(name, tid), (server, 53))
        data, _ = sock.recvfrom(4096)
        return {"ok": True, "answers": parse_answers(data, tid)}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}
    finally:
        sock.close()


# -- other probes -----------------------------------------------------------
#
# The kill test asks a different question than the tunnel-up checks: not
# "did I get a valid answer" but "did ANY evidence of my packet come
# back". With the tunnel down, an NXDOMAIN from a clearnet resolver, a
# TCP reset, an ICMP error -- each one is a round trip in the clear and
# therefore a leak. Only silence (a timeout) is clean. Anything the
# probe cannot classify counts as a leak: the verifier must fail toward
# FAIL, never toward certifying a broken zone.


def dns_roundtrip(server: str, name: str) -> bool:
    """True if ANY datagram comes back -- rcode and validity irrelevant."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(DNS_TIMEOUT)
    try:
        sock.sendto(build_query(name, 0x5747), (server, 53))
        sock.recvfrom(4096)
        return True
    except TimeoutError:
        return False
    except OSError:
        return True  # ICMP error delivered locally: something answered
    finally:
        sock.close()


def tcp_roundtrip(ip: str, port: int) -> bool:
    """True on any evidence of a round trip: connect, refuse, or error.

    A refused connection means our SYN left and a RST came back -- a
    leak even though nothing "connected". Only a timeout is silence.
    """
    try:
        socket.create_connection((ip, port), timeout=DNS_TIMEOUT).close()
        return True
    except TimeoutError:
        return False
    except OSError:
        return True


STUN_COOKIE = 0x2112A442


def parse_stun(data: bytes, txid: bytes) -> tuple[str, int]:
    """XOR-MAPPED-ADDRESS out of a binding success, or ValueError."""
    if len(data) < 20:
        raise ValueError("short response")
    mtype, mlen, cookie = struct.unpack(">HHI", data[:8])
    if mtype != 0x0101 or cookie != STUN_COOKIE or data[8:20] != txid:
        raise ValueError("not our binding success")
    off = 20
    end = min(len(data), 20 + mlen)
    while off + 4 <= end:
        atype, alen = struct.unpack(">HH", data[off : off + 4])
        value = data[off + 4 : off + 4 + alen]
        off += 4 + alen + ((4 - alen % 4) % 4)  # attributes pad to 32 bits
        if atype == 0x0020 and len(value) >= 8 and value[1] == 0x01:  # IPv4
            port = struct.unpack(">H", value[2:4])[0] ^ (STUN_COOKIE >> 16)
            raw = struct.unpack(">I", value[4:8])[0] ^ STUN_COOKIE
            return socket.inet_ntoa(struct.pack(">I", raw)), port
    raise ValueError("no XOR-MAPPED-ADDRESS")


def stun_probe(host: str = "stun.cloudflare.com", port: int = 3478) -> dict:
    """The WebRTC question at the layer we control: what public address
    does a STUN server see our UDP arrive from? With the tunnel up this
    must be the exit -- it exercises the UDP egress path, which the
    HTTPS exit check does not."""
    import os

    txid = os.urandom(12)
    request = struct.pack(">HHI", 0x0001, 0, STUN_COOKIE) + txid
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)
    try:
        sock.sendto(request, (host, port))
        data, _ = sock.recvfrom(2048)
        ip, sport = parse_stun(data, txid)
        return {"ok": True, "ip": ip, "port": sport}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}
    finally:
        sock.close()


def exit_ip() -> dict:
    try:
        with urllib.request.urlopen("https://ifconfig.me/ip", timeout=TIMEOUT) as resp:
            ip = resp.read(64).decode("ascii", errors="replace").strip()
            return {"ok": True, "ip": ip}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


# -- modes ------------------------------------------------------------------


def mode_dnscheck(argv: list[str]) -> dict:
    server = argv[0] if argv else "system"
    name = argv[1] if len(argv) > 1 else "example.com"
    if server == "system":
        results = [dns_probe(s, name) for s in system_resolvers()]
        ok = any(r["ok"] for r in results)
        answers = [a for r in results if r["ok"] for a in r["answers"]]
        return {"ok": ok, "answers": answers}
    return dns_probe(server, name)


def mode_killcheck(argv: list[str]) -> dict:
    """With the tunnel down, every probe must meet SILENCE; a round trip
    of any kind leaks. A probe that crashes counts as leaked -- a broken
    detector must never read as a clean zone."""
    checks = [("tcp/1.1.1.1:443", lambda: tcp_roundtrip("1.1.1.1", 443))]
    checks += [
        (f"dns/system:{server}", lambda s=server: dns_roundtrip(s, "killprobe.example.net"))
        for server in system_resolvers()
    ]
    checks.append(("dns/8.8.8.8", lambda: dns_roundtrip("8.8.8.8", "killprobe.example.net")))
    checks.append(("dns/192.0.2.1", lambda: dns_roundtrip("192.0.2.1", "killprobe.example.net")))
    if len(argv) >= 2:
        checks.append(
            (f"tcp/{argv[0]}:{argv[1]}", lambda: tcp_roundtrip(argv[0], int(argv[1])))
        )
    leaked = []
    for label, check in checks:
        try:
            if check():
                leaked.append(label)
        except Exception as exc:  # noqa: BLE001
            leaked.append(f"{label} (probe crashed: {exc})")
    return {"ok": not leaked, "ran": len(checks), "leaked": leaked}


def main(argv: list[str]) -> int:
    socket.setdefaulttimeout(TIMEOUT)  # bounds getaddrinfo too
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    mode, rest = argv[0], argv[1:]
    if mode == "exitip":
        result = exit_ip()
    elif mode == "stun":
        result = stun_probe(*rest[:1], *[int(p) for p in rest[1:2]])
    elif mode == "dnscheck":
        result = mode_dnscheck(rest)
    elif mode == "killcheck":
        result = mode_killcheck(rest)
    else:
        print(f"unknown probe {mode!r}", file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0 if result.get("ok") or mode == "killcheck" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
