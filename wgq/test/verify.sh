#!/bin/sh
#
# verify.sh - prove that a wgq zone actually leaks nothing.
#
# Run this in a CLIENT qube, one that sits behind sys-firewall-<zone>.  Never
# in the VPN qube: its own egress to the endpoint is deliberately permitted,
# so testing there proves nothing about what clients can reach.
#
# It cannot be a single automatic run, and pretending otherwise would be the
# kind of check that always passes.  Two of the four checks need a hand
# elsewhere:
#
#   check 3 needs the tunnel STOPPED in the VPN qube  -> a dom0 command
#   check 4 needs a capture from the UPSTREAM firewall qube
#
# So the default mode walks you through it and tells you exactly what to run
# where.  Every check reports PASS, FAIL or SKIP, and a SKIP is never
# counted as success: an unverified check exits non-zero.
#
#   ./verify.sh --dns 10.64.0.1 --endpoint 185.65.135.170:51820 \
#               --provider mullvad --peer se-mma-wg-001
#
# Exit: 0 all passed, 1 a check failed, 2 bad usage or missing tools,
#       3 everything that ran passed but something was skipped.

set -u

DNS=""
PROVIDER="generic"
PEER=""
EXIT_IP=""
CLEARNET_IP=""
PCAP=""
STAGE="all"
ASSUME_YES=0
ENDPOINTS=""
NET_TIMEOUT=8

RESULTS=$(mktemp) || { echo "cannot create a temp file" >&2; exit 2; }
trap 'rm -f "$RESULTS"' EXIT INT TERM

usage() {
	# Print the header comment: skip the shebang, stop at the first line
	# that is not a comment, so the help can never drift out of a hardcoded
	# line range again.
	awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
	exit 2
}

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }
pass()   { printf '  PASS  %s\n' "$2"; record PASS "$1" "$2"; }
fail()   { printf '  FAIL  %s\n' "$2"; record FAIL "$1" "$2"; }
skip()   { printf '  SKIP  %s\n' "$2"; record SKIP "$1" "$2"; }
head2()  { printf '\n== %s ==\n' "$1"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dns)         DNS=${2:?}; shift 2 ;;
		--endpoint)    ENDPOINTS="$ENDPOINTS ${2:?}"; shift 2 ;;
		--exit-ip)     EXIT_IP=${2:?}; shift 2 ;;
		--clearnet-ip) CLEARNET_IP=${2:?}; shift 2 ;;
		--provider)    PROVIDER=${2:?}; shift 2 ;;
		--peer)        PEER=${2:?}; shift 2 ;;
		--pcap)        PCAP=${2:?}; shift 2 ;;
		--stage)       STAGE=${2:?}; shift 2 ;;
		--yes|-y)      ASSUME_YES=1; shift ;;
		-h|--help)     usage ;;
		*)             printf 'unknown option: %s\n' "$1" >&2; usage ;;
	esac
done

require_tools() {
	missing=""
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
	done
	if [ -n "$missing" ]; then
		printf 'missing required tools:%s\n' "$missing" >&2
		printf 'install them with: sudo apt install curl dnsutils iputils-ping tcpdump\n' >&2
		exit 2
	fi
}

fetch() { curl -fsS --max-time "$NET_TIMEOUT" "$1" 2>/dev/null; }

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '\n%s\nPress Enter when done, or Ctrl-C to stop. ' "$1"
	read -r _ignored < /dev/tty || return 1
	return 0
}

# --------------------------------------------------------------------------
# Check 1 - the public address is the tunnel exit.
#
# This needs an anchor. Without one there is nothing to compare against and
# the check can only ever pass, which is worse than not running it.
# --------------------------------------------------------------------------
check_public_ip() {
	head2 "Check 1: public address reflects the tunnel exit"

	seen=$(fetch https://api.ipify.org)
	confirm_ip=$(fetch https://icanhazip.com | tr -d '[:space:]')

	if [ -z "$seen" ] || [ -z "$confirm_ip" ]; then
		fail 1 "could not determine the public address (no connectivity?)"
		return
	fi
	if [ "$seen" != "$confirm_ip" ]; then
		fail 1 "two lookups disagree ($seen vs $confirm_ip) - egress is inconsistent"
		return
	fi
	printf '  observed public address: %s\n' "$seen"

	anchored=0

	if [ "$PROVIDER" = "mullvad" ]; then
		anchored=1
		json=$(fetch https://am.i.mullvad.net/json)
		if printf '%s' "$json" | grep -q '"mullvad_exit_ip"[[:space:]]*:[[:space:]]*true'; then
			host=$(printf '%s' "$json" \
				| sed -n 's/.*"mullvad_exit_ip_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
			if [ -n "$PEER" ] && [ "$host" != "$PEER" ]; then
				fail 1 "exiting via '$host' but the active peer is '$PEER'"
				return
			fi
			pass 1 "Mullvad confirms the exit${host:+ ($host)}"
		else
			fail 1 "Mullvad says this is NOT one of their exit addresses"
			return
		fi
	fi

	if [ -n "$EXIT_IP" ]; then
		anchored=1
		if [ "$seen" = "$EXIT_IP" ]; then
			pass 1 "public address matches --exit-ip"
		else
			fail 1 "expected exit $EXIT_IP but saw $seen"
			return
		fi
	fi

	if [ -n "$CLEARNET_IP" ]; then
		anchored=1
		if [ "$seen" = "$CLEARNET_IP" ]; then
			fail 1 "public address equals --clearnet-ip: traffic is NOT in the tunnel"
			return
		fi
		pass 1 "public address differs from the clearnet address"
	fi

	if [ "$anchored" -eq 0 ]; then
		skip 1 "no anchor given; pass --provider mullvad, --exit-ip or --clearnet-ip"
	fi
}

# --------------------------------------------------------------------------
# Check 2 - DNS is pinned to the in-tunnel resolver.
#
# The definitive probe aims a query at 192.0.2.1 (TEST-NET-1, which can
# never legitimately answer). An answer proves something is intercepting
# port 53 - that is the nftables DNAT in the VPN qube doing its job.
# --------------------------------------------------------------------------
check_dns() {
	head2 "Check 2: client DNS is pinned to the tunnel resolver"

	if [ -z "$DNS" ]; then
		skip 2 "no --dns given, so there is nothing to verify against"
		return
	fi

	ordinary=$(timeout "$NET_TIMEOUT" dig +time=3 +tries=1 +short example.com A 2>/dev/null)
	if [ -z "$ordinary" ]; then
		fail 2 "ordinary DNS resolution returned nothing"
		return
	fi

	intercepted=$(timeout "$NET_TIMEOUT" dig +time=3 +tries=1 +short @192.0.2.1 example.com A 2>/dev/null)
	if [ -z "$intercepted" ]; then
		fail 2 "a query to 192.0.2.1 went unanswered: DNS is NOT being intercepted, so a client that sets its own resolver bypasses $DNS"
		return
	fi
	pass 2 "queries to arbitrary resolvers are intercepted (192.0.2.1 answered)"

	if [ -n "$CLEARNET_IP" ]; then
		egress=$(timeout "$NET_TIMEOUT" dig +time=3 +tries=1 +short whoami.akamai.net 2>/dev/null)
		if [ "$egress" = "$CLEARNET_IP" ]; then
			fail 2 "the resolver egresses from $egress, your clearnet address"
			return
		fi
		printf '  resolver egress: %s\n' "${egress:-unknown}"
	fi
}

# --------------------------------------------------------------------------
# Check 3 - the kill test.
#
# With the tunnel down the client must get NOTHING. Not slow traffic, not
# degraded traffic. Every probe here is expected to fail; any success is a
# leak.
# --------------------------------------------------------------------------
check_killswitch() {
	head2 "Check 3: kill test (tunnel stopped)"

	leaked=""

	if fetch https://1.1.1.1/ >/dev/null 2>&1; then
		leaked="$leaked https/1.1.1.1"
	fi
	if curl -fsS -o /dev/null --max-time "$NET_TIMEOUT" https://8.8.8.8/ 2>/dev/null; then
		leaked="$leaked https/8.8.8.8"
	fi
	if timeout "$NET_TIMEOUT" dig +time=3 +tries=1 +short example.com A 2>/dev/null | grep -q .; then
		leaked="$leaked dns"
	fi
	if timeout "$NET_TIMEOUT" ping -n -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
		leaked="$leaked icmp"
	fi
	for endpoint in $ENDPOINTS; do
		ip=${endpoint%:*}
		if timeout "$NET_TIMEOUT" ping -n -c 2 -W 3 "$ip" >/dev/null 2>&1; then
			leaked="$leaked endpoint/$ip"
		fi
	done

	if [ -n "$leaked" ]; then
		fail 3 "traffic escaped with the tunnel down:$leaked"
	else
		pass 3 "nothing escaped with the tunnel down"
	fi
}

# --------------------------------------------------------------------------
# Check 4 - what the upstream firewall qube actually saw.
#
# Let tcpdump do the filtering: build an expression matching everything that
# is NOT allowlisted UDP, and treat any packet it prints as a finding.
# --------------------------------------------------------------------------
check_capture() {
	head2 "Check 4: upstream capture holds only allowlisted UDP"

	if [ -z "$PCAP" ]; then
		skip 4 "no --pcap given; see the instructions printed above"
		return
	fi
	if [ ! -r "$PCAP" ]; then
		fail 4 "cannot read $PCAP"
		return
	fi
	if [ -z "$ENDPOINTS" ]; then
		skip 4 "no --endpoint given, so there is no allowlist to compare against"
		return
	fi
	require_tools tcpdump

	# An unreadable or empty capture must FAIL, not pass: nothing read in
	# means nothing matched the violation filter below, and "all 0 packets
	# are allowlisted" is exactly the check-that-cannot-fail this script
	# exists to avoid.
	if ! tcpdump -n -r "$PCAP" >/dev/null 2>&1; then
		fail 4 "tcpdump cannot parse $PCAP"
		return
	fi
	total=$(tcpdump -n -r "$PCAP" 2>/dev/null | wc -l | tr -d ' ')
	if [ "$total" -eq 0 ]; then
		fail 4 "the capture holds no packets at all; capture on the vif facing the VPN qube while generating traffic"
		return
	fi

	allow=""
	for endpoint in $ENDPOINTS; do
		ip=${endpoint%:*}
		port=${endpoint##*:}
		allow="$allow or (udp and host $ip and port $port)"
	done
	allow=${allow# or }

	# ARP is link-layer housekeeping and is excluded deliberately.
	violations=$(tcpdump -n -r "$PCAP" "not arp and not ( $allow )" 2>/dev/null) || {
		fail 4 "tcpdump rejected the filter built from --endpoint; nothing was verified"
		return
	}

	if [ -n "$violations" ]; then
		fail 4 "the capture holds traffic outside the allowlist:"
		printf '%s\n' "$violations" | head -n 20 | sed 's/^/        /'
		count=$(printf '%s\n' "$violations" | wc -l | tr -d ' ')
		[ "$count" -gt 20 ] && printf '        ... and %s more\n' "$((count - 20))"
	else
		pass 4 "all $total captured packets are allowlisted UDP or ARP"
	fi
}

capture_instructions() {
	cat <<EOF

To produce a capture for check 4, run this in the UPSTREAM firewall qube
(sys-firewall), not here:

    ip -br link                       # find the vif facing sys-vpn-<zone>
    sudo tcpdump -n -i <vif> -w /tmp/wgq.pcap

Generate some traffic here, stop the capture, then bring it over:

    # in sys-firewall
    qvm-copy /tmp/wgq.pcap
    # back here
    ./verify.sh --stage pcap --pcap ~/QubesIncoming/sys-firewall/wgq.pcap \\
        $(for e in $ENDPOINTS; do printf -- '--endpoint %s ' "$e"; done)
EOF
}

report() {
	printf '\n== Summary ==\n'
	failed=0
	skipped=0
	while IFS="$(printf '\t')" read -r status number message; do
		printf '  %-5s check %s: %s\n' "$status" "$number" "$message"
		[ "$status" = "FAIL" ] && failed=$((failed + 1))
		[ "$status" = "SKIP" ] && skipped=$((skipped + 1))
	done < "$RESULTS"

	if [ "$failed" -gt 0 ]; then
		printf '\n%s check(s) FAILED. This zone is not leak-tight.\n' "$failed"
		return 1
	fi
	if [ "$skipped" -gt 0 ]; then
		printf '\n%s check(s) were skipped, so this run does not prove the zone is\n' "$skipped"
		printf 'leak-tight. Exiting non-zero on purpose.\n'
		return 3
	fi
	printf '\nAll checks passed.\n'
	return 0
}

require_tools curl dig ping timeout

case "$STAGE" in
	online)
		check_public_ip
		check_dns
		;;
	killswitch)
		check_killswitch
		;;
	pcap)
		check_capture
		;;
	all)
		check_public_ip
		check_dns

		if confirm "Now STOP the tunnel. In dom0:
    qvm-run -u root sys-vpn-<zone> 'systemctl stop wg-tunnel'"; then
			check_killswitch
		else
			skip 3 "operator did not stop the tunnel"
		fi

		if confirm "Now START it again. In dom0:
    qvm-run -u root sys-vpn-<zone> 'systemctl start wg-tunnel'"; then
			:
		fi

		check_capture
		[ -z "$PCAP" ] && capture_instructions
		;;
	*)
		printf 'unknown stage: %s\n' "$STAGE" >&2
		usage
		;;
esac

report
exit $?
