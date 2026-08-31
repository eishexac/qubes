"""The layer-1 endpoint allowlist.

These rules live in dom0 at /var/lib/qubes/appvms/<vm>/firewall.xml and are
implemented by the VPN qube's *net* qube, so they hold even if the VPN qube
itself is compromised, and they fail closed when the firewall service is not
running.  This is the layer that actually protects the user; everything
inside the VPN qube is defence in depth against tunnel loss.

The rule set is deliberately minimal:

  * one accept per distinct endpoint, UDP, on that endpoint's port
  * an explicit final drop

No `accept dns`.  Every endpoint here is numeric, so wg-quick resolves
nothing; Qubes VMs take their clock from dom0 over qrexec and their updates
through the qrexec update proxy.  A VPN qube has no legitimate reason to
send plaintext DNS to sys-net, and leaving that open would give a
compromised VPN qube a UDP side channel out of a domain otherwise pinned to
two addresses.

No icmp rule either: the final drop already covers it.
"""

from __future__ import annotations

from typing import Iterable, Sequence

from .errors import UsageError
from .peers import Peer


def endpoints(peers: Iterable[Peer]) -> list[tuple[str, int]]:
    """Distinct (ip, port) pairs, in first-seen order."""
    seen: list[tuple[str, int]] = []
    for peer in peers:
        key = (peer.endpoint_ip, peer.endpoint_port)
        if key not in seen:
            seen.append(key)
    if not seen:
        raise UsageError(
            "no peers to build an allowlist from; run 'wgq provision' first"
        )
    return seen


def api_rules(peers: Iterable[Peer]) -> list[str]:
    """Serialise to admin.vm.firewall.Set syntax.

    Format taken from qubes/firewall.py Rule.api_rule: space-separated
    key=value, one rule per line.  dstports always renders as a range, so a
    single port is written low-high with both halves equal.
    """
    rules = [
        f"action=accept dst4={ip}/32 proto=udp dstports={port}-{port}"
        for ip, port in endpoints(peers)
    ]
    rules.append("action=drop")
    return rules


def qvm_firewall_block(vm: str, peers: Iterable[Peer]) -> str:
    """The manual fallback, for when the Admin API grant is not installed.

    Corrected against qubesadmin/tools/qvm_firewall.py: `reset` installs a
    single `action=accept` rule and nothing else, so there is no `accept
    icmp` line to renumber around and no `accept dns` in the result.  The
    trailing drop is the qube's policy, which dom0 publishes separately.
    """
    pairs = endpoints(peers)
    lines = [
        "# Run these in a dom0 terminal, by hand. wgq does not execute them",
        "# for you. Read each line before you press Enter.",
        "#",
        f"# Do this with {vm} HALTED: between reset and the final del, rule 0",
        "# is a blanket accept, and every command triggers a reload.",
        "",
        f"qvm-firewall {vm} reset",
    ]
    lines += [
        f"qvm-firewall {vm} add accept dsthost={ip} proto=udp dstports={port}"
        for ip, port in pairs
    ]
    lines += [
        f"qvm-firewall {vm} del --rule-no 0",
        f"qvm-firewall {vm} list",
        "",
        "# The list should now read exactly this, and nothing else.",
        "# The final drop is implicit: it is the qube's policy, not a rule.",
        "#",
        "#   NO  ACTION  HOST             PROTOCOL  PORT(S)",
    ]
    lines += [
        f"#   {index:<3} accept  {ip:<15}  udp       {port}"
        for index, (ip, port) in enumerate(pairs)
    ]
    lines += [
        "#",
        "# If your output differs, stop and reconcile before trusting it.",
    ]
    return "\n".join(lines) + "\n"


def describe(rules: Sequence[str]) -> str:
    """Render a rule list for human review before it is applied."""
    return "\n".join(f"  {rule}" for rule in rules)
