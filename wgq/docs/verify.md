# Verify

This is the part nobody ships, and it matters more than the rest.

The one-command way, from dom0: `sudo wgq verify [zone]
[--kill-rounds N]` (no zone on a terminal: the picker asks). It gathers the endpoint and resolver from the zone,
the clearnet address from wgq-mgmt, pushes stdlib-Python probes into the
zone's client (nothing to install there, ever), runs the checks, and
drives the kill test itself — stopping the tunnel, proving it stopped,
probing, restarting, and proving recovery, N rounds in one run. The
manual script below remains for zones wgq did not build.

Alongside it, `sudo wgq doctor` checks every installed invariant --
icons, policies, tags, each zone's chain, the kill switch, the absent
fast path -- read-only, with a fix command printed for every failure.
verify proves the dataplane holds; doctor explains what drifted when it
does not.

Run the manual script from a **client** qube — never the VPN qube, whose
own egress to the endpoint is deliberately permitted.

```sh
qvm-copy test/verify.sh          # into a client qube
./verify.sh --dns 10.64.0.1 --endpoint 185.65.135.170:51820 \
            --provider mullvad --peer se-mma-wg-001
```

Five checks:

1. The public address is the tunnel exit. **Needs an anchor** —
   `--provider mullvad`, `--exit-ip`, or `--clearnet-ip`. Without one it
   reports SKIP, because a check that cannot fail is worse than no check.
1c. (wgq verify only) An advisory, not a gate: the exit's network
   (autonomous system) is compared with your clearnet's, and a match
   is flagged — the tunnel is sealed, but a same-ISP exit barely moves
   your apparent origin, which is a traffic-correlation weakness in the
   choice of server. Never fails the leak-tight verdict.
1b. (wgq verify only) The UDP path exits where the TCP path does: a
   STUN binding must see the tunnel exit — the WebRTC-leak question
   answered as a proof. Clearnet match fails; no answer is an honest
   SKIP.
2. Client DNS is pinned. Proven by aiming a query at `192.0.2.1`
   (TEST-NET-1, which can never legitimately answer): a reply means the DNAT
   is intercepting, so a client that sets its own resolver cannot escape it.
3. **The kill test.** With `wg-tunnel` stopped in the VPN qube, the client
   gets nothing. This is the check that separates a working kill switch from
   a lucky one.
4. A capture from the upstream firewall qube holds only allowlisted UDP.

Checks 3 and 4 need a hand elsewhere — stopping the tunnel is a dom0 command,
and the capture is taken in `sys-firewall`. The script walks you through both
and tells you exactly what to run where. A skipped check exits non-zero.
