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
# State: $WORK/qubes holds "name|class|netvm|provides_network" rows.
mkdir -p "$WORK/bin"
cat > "$WORK/qubes" <<'EOF'
work|AppVM|sys-firewall|False
media|AppVM|sys-firewall|False
sys-net|AppVM|-|True
sys-firewall|AppVM|sys-net|True
tpl1|TemplateVM|-|False
EOF

cat > "$WORK/bin/qvm-check" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in --quiet) ;; *) name=$a ;; esac; done
grep -q "^${name}|" "${FAKEQ:?}"
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
	printf 'sys-wgq-%s|AppVM|sys-firewall|True\n' "$zone" >> "${FAKEQ:?}"
	printf 'sys-fw-%s|AppVM|sys-wgq-%s|True\n' "$zone" "$zone" >> "$FAKEQ"
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
export FAKEQ="$WORK/qubes" QCTL_LOG="$WORK/qctl.log"
: > "$QCTL_LOG"

zone() { env PATH="$WORK/bin:$PATH" sh "$ZONE" "$@"; }
netvm_of() { awk -F'|' -v n="$1" '$1 == n {print $3}' "$FAKEQ"; }

# 1. Hostile zone names are refused.
if zone add 'Bad_Zone' >"$WORK/out" 2>&1; then
	fail "an unusable zone name was accepted"
else
	ok "unusable zone name refused"
fi

# 2. add --no-attach creates plumbing and touches no client.
if zone add tz --no-attach >"$WORK/out" 2>&1 \
	&& grep -q 'wgq.wg-zone' "$QCTL_LOG" \
	&& grep -q '"zone": "tz"' "$QCTL_LOG" \
	&& [ "$(netvm_of work)" = "sys-firewall" ]; then
	ok "add --no-attach creates the zone and attaches nothing"
else
	cat "$WORK/out"; fail "add --no-attach went wrong"
fi

# 3. Interactive add asks the name-match question and honours the answer.
if printf 'y\n\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" add work >"$WORK/out" 2>&1 \
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

# 5. add --attach wires the named qube without a dialogue.
if zone add z2 --attach media >"$WORK/out" 2>&1 \
	&& [ "$(netvm_of media)" = "sys-fw-z2" ]; then
	ok "add --attach wires the named qube"
else
	cat "$WORK/out"; fail "add --attach went wrong"
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

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_zone: all passed\n'
exit 0
