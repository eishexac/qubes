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
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/qvm-run" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${QLOG:?}"
EOF
# panic's tools log to the same file so order and targets can be pinned.
for t in qvm-firewall qvm-kill; do
cat > "$WORK/bin/$t" <<EOF
#!/bin/sh
printf '$t %s\n' "\$*" >> "\${QLOG:?}"
EOF
done
cat > "$WORK/bin/qvm-check" <<'EOF'
#!/bin/sh
# Every sys-fw-* / sys-wgq* the tests reference "exists".
for a in "$@"; do case "$a" in --quiet|--running) ;; *) n=$a ;; esac; done
case "$n" in sys-fw-*|sys-wgq|sys-wgq-*) exit 0 ;; *) exit 1 ;; esac
EOF
cat > "$WORK/bin/qvm-ls" <<'EOF'
#!/bin/sh
printf 'sys-fw-wgq\nsys-fw-work\n'
EOF
chmod +x "$WORK/bin/"*
export QLOG="$WORK/qlog"

wgq() { : > "$QLOG"; env PATH="$WORK/bin:$PATH" sh "$WGQ" "$@"; }

# 1. A mgmt verb frames into wgq-mgmt as user, arguments quoted.
if wgq servers --provider ivpn >"$WORK/out" 2>&1 \
	&& grep -q -- "-u user -- wgq-mgmt wgq 'servers' '--provider' 'ivpn'" "$QLOG"; then
	ok "mgmt verb routed to wgq-mgmt as user"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "mgmt routing went wrong"
fi

# 2. A vpn verb defaults to the singleton zone, as root.
if wgq switch nl1 >"$WORK/out" 2>&1 \
	&& grep -q -- "-u root -- sys-wgq wgq 'switch' 'nl1'" "$QLOG"; then
	ok "vpn verb routed to sys-wgq as root by default"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "default-zone vpn routing went wrong"
fi

# 3. -z picks the zone; read-only vpn verbs run as user.
if wgq -z work pubkey >"$WORK/out" 2>&1 \
	&& grep -q -- "-u user -- sys-wgq-work wgq 'pubkey'" "$QLOG"; then
	ok "-z routes to the named zone; pubkey runs as user"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "zoned vpn routing went wrong"
fi

# 4. Hostile arguments stay data: quoted through to the remote command.
if wgq switch 'a b; rm -rf /' >"$WORK/out" 2>&1 \
	&& grep -qF -- "wgq 'switch' 'a b; rm -rf /'" "$QLOG"; then
	ok "arguments are quoted, shell metacharacters stay inert"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "argument quoting went wrong"
fi

# 5. A single quote inside an argument cannot break out.
if wgq switch "it's" >"$WORK/out" 2>&1 \
	&& grep -qF -- "wgq 'switch' 'it'\\''s'" "$QLOG"; then
	ok "embedded single quotes are escaped"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "single-quote escaping went wrong"
fi

# 6. An unusable zone name is refused before any qvm-run.
if wgq -z 'Bad_Zone' switch x >"$WORK/out" 2>&1; then
	fail "an unusable zone name was accepted"
elif [ ! -s "$QLOG" ] && grep -q 'unusable zone name' "$WORK/out"; then
	ok "hostile zone name refused, nothing ran"
else
	cat "$WORK/out"; fail "zone-name refusal failed for the wrong reason"
fi

# 7. The zone subcommand execs the real zone manager, which speaks as
# the command the operator typed.
if wgq zone add 'Bad_Zone' >"$WORK/out" 2>&1; then
	fail "the zone subcommand accepted a bad zone name"
elif grep -q 'wgq zone: error: unusable zone name' "$WORK/out"; then
	ok "zone verbs exec wgq-zone under the typed name"
else
	cat "$WORK/out"; fail "zone routing failed for the wrong reason"
fi

# 8. credential pipes the typed secret into the provider file in mgmt.
if printf 'acct123\n' | wgq credential ivpn >"$WORK/out" 2>&1 \
	&& grep -q -- '-u user -- wgq-mgmt umask 077 && cat > /rw/config/ivpn-account' "$QLOG"; then
	ok "credential frames the account file into wgq-mgmt"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "credential went wrong"
fi

# 9. A hostile provider name is refused before anything runs.
if printf 'x\n' | wgq credential 'ivpn;rm' >"$WORK/out" 2>&1; then
	fail "a hostile provider name was accepted"
elif [ ! -s "$QLOG" ] && grep -q 'unusable provider name' "$WORK/out"; then
	ok "hostile provider name refused, nothing ran"
else
	cat "$WORK/out"; fail "provider refusal failed for the wrong reason"
fi

# 10. sync streams the bundle from mgmt into the zone qube and applies.
if wgq -z work sync >"$WORK/out" 2>&1 \
	&& grep -q -- '-u user -- wgq-mgmt tar -C /home/user/.local/share/wgq/zones/work -cf - peers' "$QLOG" \
	&& grep -q -- '-u root -- sys-wgq-work' "$QLOG" \
	&& grep -q 'wgq apply /tmp/wgq-sync/peers' "$QLOG"; then
	ok "sync frames mgmt -> zone qube -> apply"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "sync went wrong"
fi

# 11. panic -z blocks the firewall THEN kills the VPN qube, one zone.
if wgq panic -z work >"$WORK/out" 2>&1 \
	&& grep -q 'qvm-firewall sys-fw-work set-policy drop' "$QLOG" \
	&& grep -q 'qvm-kill sys-wgq-work' "$QLOG" \
	&& ! grep -q 'sys-fw-wgq' "$QLOG"; then
	# order: firewall line must precede the kill line
	fwline=$(grep -n 'qvm-firewall sys-fw-work set-policy' "$QLOG" | cut -d: -f1)
	killline=$(grep -n 'qvm-kill sys-wgq-work' "$QLOG" | cut -d: -f1)
	if [ "$fwline" -lt "$killline" ]; then
		ok "panic -z blocks then kills one zone"
	else
		fail "panic blocked after killing (wrong order)"
	fi
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "panic -z went wrong"
fi

# 12. bare panic hits every zone qvm-ls reports.
if wgq panic >"$WORK/out" 2>&1 \
	&& grep -q 'qvm-kill sys-wgq' "$QLOG" \
	&& grep -q 'qvm-kill sys-wgq-work' "$QLOG" \
	&& grep -q 'qvm-firewall sys-fw-wgq set-policy drop' "$QLOG"; then
	ok "bare panic stops every zone"
else
	cat "$WORK/out" "$QLOG" 2>/dev/null; fail "bare panic went wrong"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_dispatch: all passed\n'
exit 0
