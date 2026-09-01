#!/bin/sh
#
# Tests for wgq/dom0/wgq-zone, run without a Qubes machine: the qvm-*
# tools and qubesctl are faked over a small state file, and answers are
# typed over stdin exactly as an operator would. The cases pin the
# decisions the tool must never make silently: no attach without consent,
# no cross-zone move without a question, no removal under attached
# clients.

set -u

ZONE=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-zone
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

failures=0
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

# ---- fakes ----------------------------------------------------------------
# State: $WORK/qubes holds "name|class|netvm|provides_network" rows;
# $WORK/running lists the qubes that are up (fresh zone qubes are born
# halted, exactly as on a real machine).
mkdir -p "$WORK/bin"
cat > "$WORK/qubes" <<'EOF'
work|AppVM|sys-firewall|False
media|AppVM|sys-firewall|False
mail|AppVM|sys-firewall|False
dev|AppVM|sys-firewall|False
sys-net|AppVM|-|True
sys-firewall|AppVM|sys-net|True
tpl1|TemplateVM|-|False
EOF

cat > "$WORK/bin/qvm-check" <<'EOF'
#!/bin/sh
running=0
for a in "$@"; do case "$a" in --quiet) ;; --running) running=1 ;; *) name=$a ;; esac; done
grep -q "^${name}|" "${FAKEQ:?}" || exit 1
[ "$running" -eq 0 ] || grep -qx "$name" "${RUNNING:?}"
EOF

cat > "$WORK/bin/qvm-start" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) name=$a ;; esac; done
grep -qx "$name" "${RUNNING:?}" || printf '%s\n' "$name" >> "$RUNNING"
printf 'started %s\n' "$name" >> "${QCTL_LOG:?}"
EOF

cat > "$WORK/bin/qvm-prefs" <<'EOF'
#!/bin/sh
name=$1 prop=$2
case "$prop" in
	netvm)
		if [ $# -ge 3 ]; then
			awk -F'|' -v OFS='|' -v n="$name" -v v="$3" \
				'$1 == n {$3 = v} {print}' "${FAKEQ:?}" > "$FAKEQ.tmp" \
				&& mv "$FAKEQ.tmp" "$FAKEQ"
		else
			awk -F'|' -v n="$name" '$1 == n {print $3}' "${FAKEQ:?}"
		fi ;;
	provides_network)
		awk -F'|' -v n="$name" '$1 == n {print $4}' "${FAKEQ:?}" ;;
esac
EOF

cat > "$WORK/bin/qubes-prefs" <<'EOF'
#!/bin/sh
[ "$1" = default_netvm ] && echo sys-firewall
EOF

cat > "$WORK/bin/qvm-ls" <<'EOF'
#!/bin/sh
fields=name
for a in "$@"; do case "$prev" in --fields) fields=$a ;; esac; prev=$a; done
awk -F'|' -v f="$fields" 'BEGIN { n = split(f, want, ",") }
{
	line = ""
	for (i = 1; i <= n; i++) {
		v = ""
		if (want[i] == "name") v = $1
		if (want[i] == "class") v = $2
		if (want[i] == "netvm") v = $3
		if (want[i] == "template") v = $5
		line = (i == 1 ? v : line "|" v)
	}
	print line
}' "${FAKEQ:?}"
EOF

cat > "$WORK/bin/qubesctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${QCTL_LOG:?}"
zone=$(printf '%s' "$*" | sed -n 's/.*"zone": "\([a-z0-9-]*\)".*/\1/p')
if [ -n "$zone" ]; then
	vpn="sys-wgq-$zone"
	[ "$zone" = wgq ] && vpn=sys-wgq
	printf '%s|AppVM|sys-firewall|True\n' "$vpn" >> "${FAKEQ:?}"
	printf 'sys-fw-%s|AppVM|%s|True\n' "$zone" "$vpn" >> "$FAKEQ"
fi
EOF

cat > "$WORK/bin/qvm-shutdown" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$WORK/bin/qvm-remove" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -f) ;; *) name=$a ;; esac; done
grep -v "^${name}|" "${FAKEQ:?}" > "$FAKEQ.tmp"; mv "$FAKEQ.tmp" "$FAKEQ"
printf 'removed %s\n' "$name" >> "${QCTL_LOG:?}"
EOF

chmod +x "$WORK/bin/"*
export FAKEQ="$WORK/qubes" QCTL_LOG="$WORK/qctl.log" RUNNING="$WORK/running"
: > "$QCTL_LOG"
printf 'sys-net\nsys-firewall\n' > "$RUNNING"

zone() { env PATH="$WORK/bin:$PATH" sh "$ZONE" "$@"; }
netvm_of() { awk -F'|' -v n="$1" '$1 == n {print $3}' "$FAKEQ"; }

# 1. Hostile zone names are refused.
if zone add 'Bad_Zone' >"$WORK/out" 2>&1; then
	fail "an unusable zone name was accepted"
else
	ok "unusable zone name refused"
fi

# 2. add with no attach flags creates plumbing, asks nothing (no qube
# shares the zone's name), touches no client -- and finishes creation by
# starting the firewall qube, because a halted netvm refuses clients.
if zone add tz </dev/null >"$WORK/out" 2>&1 \
	&& grep -q 'wgq.wg-zone' "$QCTL_LOG" \
	&& grep -q '"zone": "tz"' "$QCTL_LOG" \
	&& grep -q 'started sys-fw-tz' "$QCTL_LOG" \
	&& [ "$(netvm_of work)" = "sys-firewall" ] \
	&& [ "$(netvm_of media)" = "sys-firewall" ]; then
	ok "plain add creates the zone, starts its firewall, attaches nothing"
else
	cat "$WORK/out"; fail "plain add went wrong"
fi

# 3. add asks the name-match question and honours the answer.
if printf 'y\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" add work >"$WORK/out" 2>&1 \
	&& grep -q 'a qube named work exists' "$WORK/out" \
	&& [ "$(netvm_of work)" = "sys-fw-work" ]; then
	ok "name-match prompt attaches the matching qube on yes"
else
	cat "$WORK/out"; fail "interactive name-match went wrong"
fi

# 4. Moving a qube across zones asks; 'no' leaves it put.
if printf 'n\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" attach tz work >"$WORK/out" 2>&1 \
	&& grep -q 'currently belongs to zone work' "$WORK/out" \
	&& [ "$(netvm_of work)" = "sys-fw-work" ]; then
	ok "cross-zone move refused without consent"
else
	cat "$WORK/out"; fail "cross-zone protection went wrong"
fi
if printf 'y\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" attach tz work >"$WORK/out" 2>&1 \
	&& [ "$(netvm_of work)" = "sys-fw-tz" ]; then
	ok "cross-zone move happens after an explicit yes"
else
	cat "$WORK/out"; fail "consented move went wrong"
fi

# 5. add --attach wires the named qubes, comma list included.
if zone add z2 --attach media,mail >"$WORK/out" 2>&1 \
	&& [ "$(netvm_of media)" = "sys-fw-z2" ] \
	&& [ "$(netvm_of mail)" = "sys-fw-z2" ]; then
	ok "add --attach wires the named qubes"
else
	cat "$WORK/out"; fail "add --attach went wrong"
fi

# 5b. Attaching to a zone whose firewall was shut down since creation
# starts it again first; the client still lands where it was pointed.
: > "$RUNNING"
if zone attach z2 dev >"$WORK/out" 2>&1 \
	&& grep -q 'started sys-fw-z2' "$QCTL_LOG" \
	&& [ "$(netvm_of dev)" = "sys-fw-z2" ]; then
	ok "attach starts a halted zone firewall before rewiring"
else
	cat "$WORK/out"; fail "the halted-zone attach guard went wrong"
fi

# 6. A bad upstream is refused before anything is created.
if zone add z3 --upstream nosuch >"$WORK/out" 2>&1; then
	fail "a nonexistent upstream was accepted"
elif ! grep -q '"zone": "z3"' "$QCTL_LOG"; then
	ok "bad upstream refused before creating the zone"
else
	fail "zone z3 was created despite the bad upstream"
fi

# 7. remove refuses while clients are attached, then works once detached.
if printf 'work\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" remove tz >"$WORK/out" 2>&1; then
	fail "remove succeeded with an attached client"
elif grep -q 'still attached' "$WORK/out"; then
	ok "remove refuses while a client is attached"
else
	cat "$WORK/out"; fail "remove refusal failed for the wrong reason"
fi
if zone detach work nosuch >"$WORK/out" 2>&1; then
	fail "detach accepted a nonexistent replacement netvm"
elif grep -q "no such netvm" "$WORK/out" && [ "$(netvm_of work)" = "sys-fw-tz" ]; then
	ok "detach refuses a replacement netvm that does not exist"
else
	cat "$WORK/out"; fail "bad-netvm refusal failed for the wrong reason"
fi
zone detach work >"$WORK/out" 2>&1 || { cat "$WORK/out"; fail "detach failed"; }
if [ "$(netvm_of work)" = "sys-firewall" ]; then
	ok "detach returns the qube to the default netvm"
else
	fail "detach set the wrong netvm"
fi
if printf 'tz\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" remove tz >"$WORK/out" 2>&1 \
	&& ! grep -q '^sys-fw-tz|' "$FAKEQ" \
	&& ! grep -q '^sys-wgq-tz|' "$FAKEQ"; then
	ok "typed confirmation removes the empty zone"
else
	cat "$WORK/out"; fail "zone removal went wrong"
fi

# 8. list names zones and their clients.
if zone list >"$WORK/out" 2>&1 && grep -q 'clients:' "$WORK/out"; then
	ok "list shows zones and clients"
else
	cat "$WORK/out"; fail "list went wrong"
fi

# 9. Bare `add` prompts; Enter takes the single-VPN default: bare sys-wgq.
if printf '\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" add >"$WORK/out" 2>&1 \
	&& grep -q 'single-VPN default' "$WORK/out" \
	&& grep -q '^sys-wgq|' "$FAKEQ" \
	&& grep -q '^sys-fw-wgq|' "$FAKEQ"; then
	ok "bare add defaults to the singleton (sys-wgq + sys-fw-wgq)"
else
	cat "$WORK/out"; fail "singleton default went wrong"
fi

# 10. The magic attach flags are gone for good: a sweep that once rewired
# Whonix plumbing must never come back, even as a refused option.
if zone add z9 --attach-all >"$WORK/out" 2>&1; then
	fail "--attach-all was accepted"
elif zone add z9 --no-attach >"$WORK/out" 2>&1; then
	fail "--no-attach was accepted"
elif ! grep -q '"zone": "z9"' "$QCTL_LOG" \
	&& [ "$(netvm_of media)" = "sys-fw-z2" ]; then
	ok "the deleted attach flags are refused before anything runs"
else
	cat "$WORK/out"; fail "a deleted attach flag still did something"
fi

# 11. Removing the singleton zone removes the bare-named qube.
awk -F'|' '$3 == "sys-fw-wgq" {print $1}' "$FAKEQ" | while read -r q; do
	zone detach "$q" >/dev/null 2>&1 || true
done
if printf 'wgq\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" remove wgq >"$WORK/out" 2>&1 \
	&& ! grep -q '^sys-wgq|' "$FAKEQ" \
	&& ! grep -q '^sys-fw-wgq|' "$FAKEQ"; then
	ok "singleton zone removal takes the bare-named qube"
else
	cat "$WORK/out"; fail "singleton removal went wrong"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_zone: all passed\n'
exit 0
