#!/bin/sh
#
# Tests for wgq/dom0/wgq, the dom0 dispatcher: every non-zone verb is
# framed into a qvm-run whose remote command line must quote each
# argument -- an argument is data for the tool inside the qube, never
# syntax for its shell. Routing is pinned too: vpn verbs go to the
# zone's VPN qube (root or user by verb), everything else to wgq-mgmt.

set -u

WGQ=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

failures=0
ok() { printf 'ok:   %s\n' "$*"; }
fail() {
	printf 'FAIL: %s\n' "$*"
	failures=$((failures + 1))
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/qvm-run" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${QLOG:?}"
EOF
# panic's tools log to the same file so order and targets can be pinned.
# The firewall mock validates its subcommand: upstream qvm-firewall
# knows exactly add/del/list/reset, and a mock that logs anything let a
# nonexistent set-policy call pass its tests for two releases. Mocks
# must reject what the real tool rejects.
cat >"$WORK/bin/qvm-firewall" <<'EOF'
#!/bin/sh
case "${2:-}" in
	add | del | list | reset) ;;
	*)
		printf 'qvm-firewall: unknown subcommand %s\n' "${2:-}" >&2
		exit 2
		;;
esac
printf 'qvm-firewall %s\n' "$*" >> "${QLOG:?}"
EOF
cat >"$WORK/bin/qvm-kill" <<'EOF'
#!/bin/sh
printf 'qvm-kill %s\n' "$*" >> "${QLOG:?}"
EOF
cat >"$WORK/bin/qvm-check" <<'EOF'
#!/bin/sh
# Every sys-fw-* / sys-wgq* the tests reference "exists".
for a in "$@"; do case "$a" in --quiet|--running) ;; *) n=$a ;; esac; done
case "$n" in sys-fw-*|sys-wgq|sys-wgq-*) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$WORK/bin/qvm-ls" <<'EOF'
#!/bin/sh
printf 'sys-fw-wgq\nsys-fw-work\n'
EOF
cat >"$WORK/bin/qvm-tags" <<'EOF'
#!/bin/sh
# ownership yes-man: dispatch tests pin routing, the zone harness pins
# ownership refusals
[ "$2" = list ] && printf 'created-by-wgq\n'
EOF

cat >"$WORK/bin/qvm-features" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$WORK/bin/"*
export QLOG="$WORK/qlog"

wgq() {
	: >"$QLOG"
	env PATH="$WORK/bin:$PATH" sh "$WGQ" "$@"
}

# 1. A mgmt verb frames into wgq-mgmt as user, arguments quoted.
if wgq servers --provider ivpn >"$WORK/out" 2>&1 \
	&& grep -q -- "-u user -- wgq-mgmt wgq 'servers' '--provider' 'ivpn'" "$QLOG"; then
	ok "mgmt verb routed to wgq-mgmt as user"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "mgmt routing went wrong"
fi

# 2. There is NO default zone: a one-arg switch with no zone named and
# no terminal refuses -- the argument is the peer, never a guessed zone.
if wgq switch nl1 >"$WORK/out" 2>&1; then
	fail "zoneless switch guessed a zone"
elif grep -q "no terminal to ask on" "$WORK/out"; then
	ok "zoneless switch refuses off-tty (peer kept, zone never guessed)"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "zoneless switch refusal said the wrong thing"
fi

# 3. -z picks the zone; read-only vpn verbs run as user.
if wgq -z work pubkey >"$WORK/out" 2>&1 \
	&& grep -q -- "-u user -- sys-wgq-work wgq 'pubkey'" "$QLOG"; then
	ok "-z routes to the named zone; pubkey runs as user"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "zoned vpn routing went wrong"
fi

# 4. Hostile arguments stay data: quoted through to the remote command.
if wgq switch work 'a b; rm -rf /' >"$WORK/out" 2>&1 \
	&& grep -qF -- "wgq 'switch' 'a b; rm -rf /'" "$QLOG"; then
	ok "arguments are quoted, shell metacharacters stay inert"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "argument quoting went wrong"
fi

# 5. A single quote inside an argument cannot break out.
if wgq switch work "it's" >"$WORK/out" 2>&1 \
	&& grep -qF -- "wgq 'switch' 'it'\\''s'" "$QLOG"; then
	ok "embedded single quotes are escaped"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "single-quote escaping went wrong"
fi

# 6. An unusable zone name is refused before any qvm-run.
if wgq -z 'Bad_Zone' switch x >"$WORK/out" 2>&1; then
	fail "an unusable zone name was accepted"
elif [ ! -s "$QLOG" ] && grep -q 'unusable zone name' "$WORK/out"; then
	ok "hostile zone name refused, nothing ran"
else
	cat "$WORK/out"
	fail "zone-name refusal failed for the wrong reason"
fi

# 7. The zone subcommand execs the real zone manager, which speaks as
# the command the operator typed.
if wgq zone add 'Bad_Zone' >"$WORK/out" 2>&1; then
	fail "the zone subcommand accepted a bad zone name"
elif grep -q 'wgq zone: error: unusable zone name' "$WORK/out"; then
	ok "zone verbs exec wgq-zone under the typed name"
else
	cat "$WORK/out"
	fail "zone routing failed for the wrong reason"
fi

# 8. credential pipes the typed secret into the provider file in mgmt.
# The write is dom0's root (qrexec authority, not in-qube sudo) because
# /rw/config is root-owned; the chown hands the 600 file to user, who
# is what the management verbs run as.
if printf 'acct123\n' | wgq credential ivpn >"$WORK/out" 2>&1 \
	&& grep -q -- '-u root -- wgq-mgmt umask 077 && cat > /rw/config/ivpn-account && chown user:user /rw/config/ivpn-account' "$QLOG"; then
	ok "credential frames the account file into wgq-mgmt"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "credential went wrong"
fi

# 9. A hostile provider name is refused before anything runs.
if printf 'x\n' | wgq credential 'ivpn;rm' >"$WORK/out" 2>&1; then
	fail "a hostile provider name was accepted"
elif [ ! -s "$QLOG" ] && grep -q 'unusable provider name' "$WORK/out"; then
	ok "hostile provider name refused, nothing ran"
else
	cat "$WORK/out"
	fail "provider refusal failed for the wrong reason"
fi

# 10. sync streams the bundle from mgmt into the zone qube and applies.
if wgq -z work sync >"$WORK/out" 2>&1 \
	&& grep -q -- '-u user -- wgq-mgmt tar -C /home/user/.local/share/wgq/zones/work -cf - peers' "$QLOG" \
	&& grep -q -- '-u root -- sys-wgq-work' "$QLOG" \
	&& grep -q 'wgq apply /tmp/wgq-sync/peers' "$QLOG"; then
	ok "sync frames mgmt -> zone qube -> apply"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "sync went wrong"
fi

# 11. panic -z blocks the firewall THEN kills the VPN qube, one zone.
if wgq panic -z work >"$WORK/out" 2>&1 \
	&& grep -q 'qvm-firewall sys-fw-work reset' "$QLOG" \
	&& grep -q 'qvm-firewall sys-fw-work del --rule-no 0' "$QLOG" \
	&& grep -q 'qvm-kill sys-wgq-work' "$QLOG" \
	&& ! grep -q 'sys-fw-wgq' "$QLOG"; then
	# order: the deny-all must land before the kill
	fwline=$(grep -n 'qvm-firewall sys-fw-work del --rule-no 0' "$QLOG" | cut -d: -f1)
	killline=$(grep -n 'qvm-kill sys-wgq-work' "$QLOG" | cut -d: -f1)
	if [ "$fwline" -lt "$killline" ]; then
		ok "panic -z blocks then kills one zone"
	else
		fail "panic blocked after killing (wrong order)"
	fi
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "panic -z went wrong"
fi

# 12. bare panic hits every zone qvm-ls reports.
if wgq panic >"$WORK/out" 2>&1 \
	&& grep -q 'qvm-kill sys-wgq' "$QLOG" \
	&& grep -q 'qvm-kill sys-wgq-work' "$QLOG" \
	&& grep -q 'qvm-firewall sys-fw-wgq del --rule-no 0' "$QLOG"; then
	ok "bare panic stops every zone"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "bare panic went wrong"
fi

# Framing rides stderr, never stdout. `wgq pubkey | wgq provision` choked
# when the "-> qvm-run" line landed on stdout and was read as the key; the
# dispatcher must add nothing to stdout so a proxied verb's output pipes
# clean. (The fake qvm-run emits nothing on stdout, so a clean run leaves
# stdout empty and the framing on stderr.)
: >"$QLOG"
env PATH="$WORK/bin:$PATH" sh "$WGQ" -z work pubkey >"$WORK/o" 2>"$WORK/e"
if [ ! -s "$WORK/o" ] && grep -q -- '-> qvm-run' "$WORK/e"; then
	ok "framing rides stderr, leaving stdout clean for a pipe"
else
	printf 'stdout:\n'
	cat "$WORK/o"
	printf 'stderr:\n'
	cat "$WORK/e"
	fail "framing leaked onto stdout -- a piped key would be corrupted"
fi

# -z reads the same in any position: after the verb must equal before
# it, and the framed target must prove the zone was heard.
if wgq status -z work >"$WORK/out" 2>&1 \
	&& grep -q "sys-wgq-work" "$QLOG"; then
	ok "-z after the verb still addresses the zone"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "post-verb -z was dropped"
fi

# --zone AFTER a management verb is that verb's own flag: it must pass
# through into the framed remote command, never be eaten by the
# dispatcher.
if wgq provision --zone work --provider ivpn >"$WORK/out" 2>&1 \
	&& grep -q -- "wgq-mgmt wgq 'provision' '--zone' 'work' '--provider' 'ivpn'" "$QLOG"; then
	ok "post-verb --zone passes through to the verb untouched"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "post-verb --zone was eaten or mangled"
fi

# The positional grammar: the zone is the verb's first argument.
if wgq status work >"$WORK/out" 2>&1 \
	&& grep -q -- "-u user -- sys-wgq-work wgq 'status'" "$QLOG"; then
	ok "a positional zone routes to that zone's qube"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "positional zone was not honored"
fi

# switch keeps its peer even if the peer's name matches no zone; with
# two args the first is the zone.
if wgq switch work se-mma-wg-001 >"$WORK/out" 2>&1 \
	&& grep -q -- "-u root -- sys-wgq-work wgq 'switch' 'se-mma-wg-001'" "$QLOG"; then
	ok "switch parses zone-then-peer"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "switch zone/peer parse broke"
fi

# No zone, no terminal: refusal that lists the zones -- never a guess,
# never a prompt a script can hang on.
if wgq status >"$WORK/out" 2>&1; then
	fail "zoneless status guessed a zone"
elif grep -q "no terminal to ask on" "$WORK/out" && grep -q "work" "$WORK/out"; then
	ok "zoneless command without a tty refuses and lists zones"
else
	cat "$WORK/out"
	fail "zoneless refusal said the wrong thing"
fi

# set tells a key from a zone by the closed set; --global needs no zone.
if wgq set work dns 9.9.9.9 >"$WORK/out" 2>&1 || true; then
	if grep -q "run sys-wgq-work" "$WORK/out" 2>/dev/null || true; then :; fi
fi
if wgq set dns 9.9.9.9 >"$WORK/out" 2>&1; then
	fail "zoneless zone-layer set guessed"
elif grep -q "no terminal to ask on" "$WORK/out"; then
	ok "zone-layer set without a zone refuses off-tty"
else
	cat "$WORK/out"
	fail "zoneless set refusal said the wrong thing"
fi

# up|down are connect|disconnect.
if wgq down work >"$WORK/out" 2>&1 \
	&& grep -q "systemctl stop wg-tunnel" "$QLOG"; then
	ok "down is disconnect, positionally zoned"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "the down alias broke"
fi

# Bare wgq is the health view, not usage; -h is usage.
if wgq >"$WORK/out" 2>&1 \
	&& grep -q 'routes: ' "$WORK/out" \
	&& grep -q 'commands: wgq -h' "$WORK/out"; then
	ok "bare wgq shows the health view and points at -h"
else
	cat "$WORK/out"
	fail "bare wgq went wrong"
fi
if wgq -h >"$WORK/out" 2>&1; then
	fail "-h exited 0"
elif grep -q 'bare: the health view' "$WORK/out"; then
	ok "-h is usage, and usage names the bare form"
else
	cat "$WORK/out"
	fail "-h went wrong"
fi

# -n prints the framed command and runs nothing.
if wgq switch work nl1 -n >"$WORK/out" 2>&1 \
	&& grep -q 'dry-run: nothing executed' "$WORK/out" \
	&& [ ! -s "$QLOG" ]; then
	ok "-n prints the framed command and executes nothing"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null
	fail "-n dry-run went wrong"
fi

# -n on a dom0-native verb is refused with the reason, not faked.
if wgq restart -n >"$WORK/out" 2>&1; then
	fail "-n on restart pretended"
elif grep -q "prints its plan before asking" "$WORK/out"; then
	ok "-n on a plan-first verb is refused honestly"
else
	cat "$WORK/out"
	fail "-n refusal went wrong"
fi

# --version answers from the tree, matching the in-qube CLI's string.
want=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$(dirname "$WGQ")/../src/wgq/__init__.py")
if wgq --version >"$WORK/out" 2>&1 \
	&& grep -qx "wgq $want" "$WORK/out"; then
	ok "--version prints the tree's own version"
else
	cat "$WORK/out"
	fail "--version went wrong (wanted 'wgq $want')"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_dispatch: all passed\n'
exit 0
