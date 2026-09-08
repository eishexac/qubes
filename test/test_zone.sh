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
ok() { printf 'ok:   %s\n' "$*"; }
fail() {
	printf 'FAIL: %s\n' "$*"
	failures=$((failures + 1))
}

# ---- fakes ----------------------------------------------------------------
# State: $WORK/qubes holds "name|class|netvm|provides_network" rows;
# $WORK/running lists the qubes that are up (fresh zone qubes are born
# halted, exactly as on a real machine).
mkdir -p "$WORK/bin"
cat >"$WORK/qubes" <<'EOF'
work|AppVM|sys-firewall|False
media|AppVM|sys-firewall|False
mail|AppVM|sys-firewall|False
dev|AppVM|sys-firewall|False
sys-net|AppVM|-|True
sys-firewall|AppVM|sys-net|True
tpl1|TemplateVM|-|False
EOF

cat >"$WORK/bin/qvm-check" <<'EOF'
#!/bin/sh
running=0
for a in "$@"; do case "$a" in --quiet) ;; --running) running=1 ;; *) name=$a ;; esac; done
grep -q "^${name}|" "${FAKEQ:?}" || exit 1
[ "$running" -eq 0 ] || grep -qx "$name" "${RUNNING:?}"
EOF

cat >"$WORK/bin/qvm-start" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) name=$a ;; esac; done
grep -qx "$name" "${RUNNING:?}" || printf '%s\n' "$name" >> "$RUNNING"
printf 'started %s\n' "$name" >> "${QCTL_LOG:?}"
EOF

cat >"$WORK/bin/qvm-prefs" <<'EOF'
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

cat >"$WORK/bin/qubes-prefs" <<'EOF'
#!/bin/sh
def=0
[ "$1" = --default ] && {
	def=1
	shift
}
prop=$1
if [ "$def" -eq 1 ]; then
	grep -v "^$prop=" "${GPREFS:?}" > "$GPREFS.tmp" || :
	mv "$GPREFS.tmp" "$GPREFS"
	printf 'gprefs-default %s\n' "$prop" >> "${QCTL_LOG:?}"
elif [ $# -ge 2 ]; then
	grep -v "^$prop=" "${GPREFS:?}" > "$GPREFS.tmp" || :
	mv "$GPREFS.tmp" "$GPREFS"
	printf '%s=%s\n' "$prop" "$2" >> "$GPREFS"
	printf 'gprefs-set %s=%s\n' "$prop" "$2" >> "${QCTL_LOG:?}"
else
	v=$(sed -n "s/^$prop=//p" "${GPREFS:?}")
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	else
		case "$prop" in
			default_netvm | updatevm) echo sys-firewall ;;
			clockvm) echo sys-net ;;
		esac
	fi
fi
EOF

cat >"$WORK/bin/qvm-ls" <<'EOF'
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

cat >"$WORK/bin/qubesctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${QCTL_LOG:?}"
zone=$(printf '%s' "$*" | sed -n 's/.*"zone": "\([a-z0-9-]*\)".*/\1/p')
if [ -n "$zone" ]; then
	vpn="sys-wgq-$zone"
	[ "$zone" = wgq ] && vpn=sys-wgq
	# create-if-missing, like the real salt states: qubesd never dupes
	grep -q "^$vpn|" "${FAKEQ:?}" \
		|| printf '%s|AppVM|sys-firewall|True\n' "$vpn" >> "$FAKEQ"
	grep -q "^sys-fw-$zone|" "$FAKEQ" \
		|| printf 'sys-fw-%s|AppVM|%s|True\n' "$zone" "$vpn" >> "$FAKEQ"
	# the adoption guard in wg-zone.sls tags what it makes
	printf '%s|created-by-wgq\nsys-fw-%s|created-by-wgq\n' "$vpn" "$zone" >> "${TAGS:?}"
fi
EOF

cat >"$WORK/bin/qvm-shutdown" <<'EOF'
#!/bin/sh
printf 'shutdown %s\n' "$*" >> "${QCTL_LOG:?}"
for a in "$@"; do
	case "$a" in
		-*) ;;
		*)
			grep -v "^${a}\$" "${RUNNING:?}" > "$RUNNING.tmp" || :
			mv "$RUNNING.tmp" "$RUNNING"
			;;
	esac
done
EOF

cat >"$WORK/bin/qvm-clone" <<'EOF'
#!/bin/sh
old=$1 new=$2
awk -F'|' -v OFS='|' -v o="$old" -v n="$new" \
	'{ print } $1 == o { print n, $2, $3, $4 }' "${FAKEQ:?}" > "$FAKEQ.tmp" \
	&& mv "$FAKEQ.tmp" "$FAKEQ"
printf 'clone %s %s\n' "$old" "$new" >> "${QCTL_LOG:?}"
EOF

cat >"$WORK/bin/qvm-remove" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -f) ;; *) name=$a ;; esac; done
grep -v "^${name}|" "${FAKEQ:?}" > "$FAKEQ.tmp"; mv "$FAKEQ.tmp" "$FAKEQ"
printf 'removed %s\n' "$name" >> "${QCTL_LOG:?}"
EOF

cat >"$WORK/bin/qvm-tags" <<'EOF'
#!/bin/sh
name=$1 verb=$2
case "$verb" in
	add)  grep -qx "$name|$3" "${TAGS:?}" 2>/dev/null \
		|| printf '%s|%s\n' "$name" "$3" >> "$TAGS" ;;
	list) awk -F'|' -v n="$name" '$1 == n {print $2}' "${TAGS:?}" ;;
esac
EOF

cat >"$WORK/bin/qvm-run" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
	case "$1" in
		-u) shift 2 ;;
		--no-gui | --no-autostart | --pass-io | --) shift ;;
		*) break ;;
	esac
done
name=$1
shift
printf 'run %s: %s\n' "$name" "$*" >> "${QCTL_LOG:?}"
case "$*" in
	*journalctl*)
		printf '2026-09-08T09:14:02 wgq-firewall: kill switch installed\n'
		printf '2026-09-08T09:14:03 wg-tunnel[412]: up: peer \033[31mhostile\033[0m se-mma\n'
		;;
	*"latest-handshakes"*) printf 'tick 1000 988 1048576 524288 42 ok_peer=se-mma_dns=10.64.0.1\n' ;;
	*"cat /run/wgq/state"*) printf 'ok peer=se-mma dns=10.64.0.1\n' ;;
	*"cat /rw/config/wg/dns"*) exit 1 ;;
	*"test -f /rw/config/wg/dns"*) exit 1 ;;
esac
EOF

cat >"$WORK/bin/qvm-features" <<'EOF'
#!/bin/sh
unset_flag=0
[ "$1" = --unset ] && { unset_flag=1; shift; }
name=$1 feat=$2
if [ "$unset_flag" -eq 1 ]; then
	grep -v "^$name|$feat|" "${FEATS:?}" > "$FEATS.tmp" 2>/dev/null || :
	mv "$FEATS.tmp" "$FEATS"
elif [ $# -ge 3 ]; then
	printf '%s|%s|%s\n' "$name" "$feat" "$3" >> "${FEATS:?}"
else
	awk -F'|' -v n="$name" -v f="$feat" '$1 == n && $2 == f {print $3}' "${FEATS:?}"
fi
EOF

chmod +x "$WORK/bin/"*
export FAKEQ="$WORK/qubes" QCTL_LOG="$WORK/qctl.log" RUNNING="$WORK/running" TAGS="$WORK/tags" FEATS="$WORK/features" GPREFS="$WORK/gprefs"
: >"$WORK/features"
: >"$WORK/gprefs"
: >"$TAGS"
: >"$QCTL_LOG"
printf 'sys-net\nsys-firewall\n' >"$RUNNING"

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
	cat "$WORK/out"
	fail "plain add went wrong"
fi

# 3. add asks the name-match question and honours the answer.
if printf 'y\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" add work >"$WORK/out" 2>&1 \
	&& grep -q 'a qube named work exists' "$WORK/out" \
	&& [ "$(netvm_of work)" = "sys-fw-work" ]; then
	ok "name-match prompt attaches the matching qube on yes"
else
	cat "$WORK/out"
	fail "interactive name-match went wrong"
fi

# 4. Moving a qube across zones asks; 'no' leaves it put.
if printf 'n\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" attach tz work >"$WORK/out" 2>&1 \
	&& grep -q 'currently belongs to zone work' "$WORK/out" \
	&& [ "$(netvm_of work)" = "sys-fw-work" ]; then
	ok "cross-zone move refused without consent"
else
	cat "$WORK/out"
	fail "cross-zone protection went wrong"
fi
if printf 'y\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" attach tz work >"$WORK/out" 2>&1 \
	&& [ "$(netvm_of work)" = "sys-fw-tz" ]; then
	ok "cross-zone move happens after an explicit yes"
else
	cat "$WORK/out"
	fail "consented move went wrong"
fi

# 5. add --attach wires the named qubes, comma list included.
if zone add z2 --attach media,mail >"$WORK/out" 2>&1 \
	&& [ "$(netvm_of media)" = "sys-fw-z2" ] \
	&& [ "$(netvm_of mail)" = "sys-fw-z2" ]; then
	ok "add --attach wires the named qubes"
else
	cat "$WORK/out"
	fail "add --attach went wrong"
fi

# 5b. Attaching to a zone whose firewall was shut down since creation
# starts it again first; the client still lands where it was pointed.
: >"$RUNNING"
if zone attach z2 dev >"$WORK/out" 2>&1 \
	&& grep -q 'started sys-fw-z2' "$QCTL_LOG" \
	&& [ "$(netvm_of dev)" = "sys-fw-z2" ]; then
	ok "attach starts a halted zone firewall before rewiring"
else
	cat "$WORK/out"
	fail "the halted-zone attach guard went wrong"
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
	cat "$WORK/out"
	fail "remove refusal failed for the wrong reason"
fi
if zone detach work nosuch >"$WORK/out" 2>&1; then
	fail "detach accepted a nonexistent replacement netvm"
elif grep -q "no such netvm" "$WORK/out" && [ "$(netvm_of work)" = "sys-fw-tz" ]; then
	ok "detach refuses a replacement netvm that does not exist"
else
	cat "$WORK/out"
	fail "bad-netvm refusal failed for the wrong reason"
fi
zone detach work >"$WORK/out" 2>&1 || {
	cat "$WORK/out"
	fail "detach failed"
}
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
	cat "$WORK/out"
	fail "zone removal went wrong"
fi

# 8. list names zones and their clients.
if zone list >"$WORK/out" 2>&1 && grep -q 'clients:' "$WORK/out"; then
	ok "list shows zones and clients"
else
	cat "$WORK/out"
	fail "list went wrong"
fi

# 9a. Every zone is named: bare `add` refuses instead of prompting for
# a default nobody chose.
if zone add >"$WORK/out" 2>&1; then
	fail "bare add still created something"
elif grep -q 'name the zone' "$WORK/out"; then
	ok "bare add refuses: zones are named"
else
	cat "$WORK/out"
	fail "bare add refused for the wrong reason"
fi

# 9b. The reserved zone cannot be BORN anymore.
if zone add wgq >"$WORK/out" 2>&1; then
	fail "a fresh reserved zone was created"
elif grep -q 'cannot be created anymore' "$WORK/out"; then
	ok "a fresh reserved zone is refused"
else
	cat "$WORK/out"
	fail "fresh reserved zone refused for the wrong reason"
fi

# 9c. An EXISTING reserved zone (a pre-0.3.0 install) still converges,
# with the deprecation warning pointing at rename.
printf 'sys-wgq|AppVM|sys-firewall|True\nsys-fw-wgq|AppVM|sys-wgq|True\n' >>"$FAKEQ"
printf 'sys-wgq|created-by-wgq\nsys-fw-wgq|created-by-wgq\n' >>"$TAGS"
if zone add wgq >"$WORK/out" 2>&1 \
	&& grep -q 'deprecated' "$WORK/out" \
	&& grep -q 'rename wgq' "$WORK/out"; then
	ok "an existing reserved zone converges with the deprecation warning"
else
	cat "$WORK/out"
	fail "legacy reserved-zone converge went wrong"
fi

# 9d. The migration itself: rename the reserved zone. Clone, retag,
# rewire (including an attached client), remove the old pair, converge
# under the new name -- and the mgmt bundle follows.
printf 'tc1|AppVM|sys-fw-wgq|False\n' >>"$FAKEQ"
if printf 'vault\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" rename wgq vault >"$WORK/out" 2>&1 \
	&& grep -q 'clone sys-wgq sys-wgq-vault' "$QCTL_LOG" \
	&& grep -q 'clone sys-fw-wgq sys-fw-vault' "$QCTL_LOG" \
	&& [ "$(netvm_of sys-fw-vault)" = "sys-wgq-vault" ] \
	&& [ "$(netvm_of tc1)" = "sys-fw-vault" ] \
	&& ! grep -q '^sys-wgq|' "$FAKEQ" \
	&& ! grep -q '^sys-fw-wgq|' "$FAKEQ" \
	&& grep -q 'sys-wgq-vault|created-by-wgq' "$TAGS" \
	&& grep -q 'zones/wgq' "$QCTL_LOG" \
	&& grep -q '"zone": "vault"' "$QCTL_LOG"; then
	ok "rename migrates the reserved zone: clone, retag, rewire, converge"
else
	cat "$WORK/out"
	fail "rename went wrong"
fi
zone detach tc1 >/dev/null 2>&1 || true
grep -v '^tc1|' "$FAKEQ" >"$FAKEQ.tmp" && mv "$FAKEQ.tmp" "$FAKEQ"

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
	cat "$WORK/out"
	fail "a deleted attach flag still did something"
fi

# 11. Removing the renamed zone takes the suffixed pair.
awk -F'|' '$3 == "sys-fw-vault" {print $1}' "$FAKEQ" | while read -r q; do
	zone detach "$q" >/dev/null 2>&1 || true
done
if printf 'vault\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" remove vault >"$WORK/out" 2>&1 \
	&& ! grep -q '^sys-wgq-vault|' "$FAKEQ" \
	&& ! grep -q '^sys-fw-vault|' "$FAKEQ"; then
	ok "renamed zone removal takes the suffixed pair"
else
	cat "$WORK/out"
	fail "renamed zone removal went wrong"
fi

# 11a2. doctor: on this healthy fake machine every invariant holds. The
# identity dirs are pointed at prepared stand-ins (doctor is read-only,
# so the override exists exactly for this harness), the running zone
# qubes have no qvm-run here, and doctor must SKIP their dataplane
# rather than guess.
DOCTOR=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-doctor
mkdir -p "$WORK/icons" "$WORK/policy" "$WORK/salt"
for i in appvm-wgq appvm-wgq-fw appvm-wgq-mgmt servicevm-wgq servicevm-wgq-fw templatevm-wgq-tpl; do
	: >"$WORK/icons/$i.svg"
done
for pol in 30-wgq 30-wgq-labels 30-wgq-creation; do
	: >"$WORK/policy/$pol.policy"
done
doctor() {
	env PATH="$WORK/bin:$PATH" WGQ_ICON_DIR="$WORK/icons" \
		WGQ_POLICY_DIR="$WORK/policy" WGQ_SALT_DIR="$WORK/salt" \
		WGQ_ENTRY="$DOCTOR" sh "$DOCTOR"
}
if doctor >"$WORK/out" 2>&1 \
	&& grep -q 'chain sys-fw-work -> sys-wgq-work -> sys-firewall ok' "$WORK/out" \
	&& grep -q 'dataplane checks skipped' "$WORK/out" \
	&& grep -q 'icons 6/6 ok' "$WORK/out" \
	&& grep -q 'nothing broken' "$WORK/out"; then
	ok "doctor passes a healthy machine, skips what it cannot probe"
else
	cat "$WORK/out"
	fail "doctor mis-judged a healthy machine"
fi

# 11a3. doctor: rewire the zone's firewall qube behind wgq's back -- the
# exact hand-modification the no-locks design says must be DETECTED. It
# must fail, name the break, and print the one-line repair.
env PATH="$WORK/bin:$PATH" qvm-prefs sys-fw-work netvm sys-firewall
if doctor >"$WORK/out" 2>&1; then
	cat "$WORK/out"
	fail "doctor blessed a broken chain"
elif grep -q "clients bypass the tunnel path" "$WORK/out" \
	&& grep -q "fix:  qvm-prefs sys-fw-work netvm sys-wgq-work" "$WORK/out"; then
	ok "doctor catches a rewired chain and names the repair"
else
	cat "$WORK/out"
	fail "doctor failed the broken chain for the wrong reason"
fi
env PATH="$WORK/bin:$PATH" qvm-prefs sys-fw-work netvm sys-wgq-work

# 11a4. The connection lifecycle. connect drives systemctl start in the
# zone qube and reads the state back; disconnect stops it and SAYS the
# zone is dark -- the kill-switch-stays framing is part of the contract.
CTL=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-ctl
ctl() { env PATH="$WORK/bin:$PATH" sh "$CTL" "$@"; }
if ctl --zone work connect >"$WORK/out" 2>&1 \
	&& grep -q 'run sys-wgq-work: systemctl start wg-tunnel' "$QCTL_LOG" \
	&& grep -q 'zone work connected (ok peer=se-mma' "$WORK/out"; then
	ok "connect starts the tunnel and proves the state"
else
	cat "$WORK/out"
	fail "connect did not drive and verify the tunnel"
fi
if ctl --zone work disconnect >"$WORK/out" 2>&1 \
	&& grep -q 'run sys-wgq-work: systemctl stop wg-tunnel' "$QCTL_LOG" \
	&& grep -q 'dark' "$WORK/out" && grep -q 'kill switch holds' "$WORK/out"; then
	ok "disconnect stops the tunnel and says dark, not clear"
else
	cat "$WORK/out"
	fail "disconnect lost the darkness contract"
fi

# 11a5. Settings: autoconnect off is a per-qube service feature (visible,
# persistent, dom0-set); on removes it; a bogus dns value is refused
# before anything reaches the qube.
if ctl --zone work set autoconnect off >"$WORK/out" 2>&1 \
	&& grep -q 'sys-wgq-work|service.wgq-no-autoconnect|1' "$WORK/features" \
	&& ctl --zone work get 2>/dev/null | grep -q 'autoconnect: off' \
	&& ctl --zone work set autoconnect on >/dev/null 2>&1 \
	&& ! grep -q 'wgq-no-autoconnect' "$WORK/features"; then
	ok "autoconnect off/on writes and clears the service feature"
else
	cat "$WORK/out"
	fail "autoconnect setting did not land in qvm-features"
fi
cp "$QCTL_LOG" "$WORK/qctl.before"
if ctl --zone work set dns 999.1.2.3 >"$WORK/out" 2>&1; then
	fail "a bogus resolver address was accepted"
elif grep -q 'not an IPv4 address' "$WORK/out" && cmp -s "$QCTL_LOG" "$WORK/qctl.before"; then
	ok "a bogus resolver is refused before touching the qube"
else
	cat "$WORK/out"
	fail "bogus resolver refused for the wrong reason"
fi

# 11a5b. Layered settings: a global default lands in dom0's features and
# materializes into zones without an override; a zone override wins and
# says so; clearing the override lets the global answer again.
if ctl --zone work set --global dns 10.64.0.99 >"$WORK/out" 2>&1 \
	&& grep -q 'dom0|wgq.dns|10.64.0.99' "$WORK/features" \
	&& grep -q "'10.64.0.99' > /rw/config/wg/dns" "$QCTL_LOG" \
	&& ctl --zone work get 2>/dev/null | grep -q 'dns:         10.64.0.99 (global)'; then
	ok "a global dns default stores on dom0 and materializes into the zone"
else
	cat "$WORK/out"
	fail "global dns did not layer correctly"
fi
if ctl --zone work set dns 9.9.9.9 >/dev/null 2>&1 \
	&& grep -q 'sys-wgq-work|wgq.dns|9.9.9.9' "$WORK/features" \
	&& ctl --zone work get 2>/dev/null | grep -q 'dns:         9.9.9.9 (zone override)' \
	&& ctl --zone work set dns default >/dev/null 2>&1 \
	&& ctl --zone work get 2>/dev/null | grep -q 'dns:         10.64.0.99 (global)'; then
	ok "a zone override wins, and clearing it restores the global"
else
	ctl --zone work get 2>&1 | head -3
	fail "override/global precedence broke"
fi
ctl --zone work set --global dns default >/dev/null 2>&1 || :

# 11a6. The ownership rule holds for the lifecycle verbs too.
printf 'sys-wgq-alien|AppVM|sys-firewall|True\n' >>"$FAKEQ"
if ctl --zone alien connect >"$WORK/out" 2>&1; then
	fail "connect drove a foreign qube's tunnel"
elif grep -q 'not created by wgq' "$WORK/out"; then
	ok "a foreign lookalike zone is refused by connect"
else
	cat "$WORK/out"
	fail "foreign zone refused for the wrong reason"
fi
grep -v '^sys-wgq-alien|' "$FAKEQ" >"$FAKEQ.tmp" && mv "$FAKEQ.tmp" "$FAKEQ"

# 11a6b. Zone colours: refused off-palette, unique across zones,
# stored as a feature, painted only for humans (this harness is a pipe,
# so outputs stay escape-free).
if zone add zc --color plaid >"$WORK/out" 2>&1; then
	fail "an off-palette colour was accepted"
elif grep -q "unknown colour 'plaid'" "$WORK/out"; then
	ok "an off-palette colour is refused with the palette shown"
else
	cat "$WORK/out"
	fail "bad colour refused for the wrong reason"
fi
work_colour=$(awk -F'|' '$1 == "sys-wgq-work" && $2 == "wgq.color" {print $3}' "$FEATS" | head -1)
if [ -n "$work_colour" ] \
	&& ! zone add zc --color "$work_colour" >"$WORK/out" 2>&1 \
	&& grep -q "already worn" "$WORK/out"; then
	ok "a colour cannot be worn by two zones"
else
	cat "$WORK/out"
	fail "duplicate colour was not refused (work wears '$work_colour')"
fi
if zone add zc --color pink >"$WORK/out" 2>&1 \
	&& grep -q 'sys-wgq-zc|wgq.color|pink' "$FEATS" \
	&& grep -q 'wears pink' "$WORK/out" \
	&& ! grep -q '\033' "$WORK/out"; then
	ok "a picked colour stores on the zone and prints plain off-tty"
else
	cat "$WORK/out"
	fail "colour assignment went wrong"
fi
printf 'zc\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" remove zc >/dev/null 2>&1 || :
grep -v '^sys-wgq-zc|' "$FEATS" >"$FEATS.tmp" && mv "$FEATS.tmp" "$FEATS"

# 11a6c. System routes: prefs move behind a zone and come back; the
# policy write prints first and installs only on yes; clock argues.
ROUTE=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-route
route() { env PATH="$WORK/bin:$PATH" WGQ_POLICY_DIR="$WORK/policy" sh "$ROUTE" "$@"; }
if route dom0-updates work >"$WORK/out" 2>&1 \
	&& grep -q 'gprefs-set updatevm=sys-fw-work' "$QCTL_LOG" \
	&& route list 2>/dev/null | grep -q 'dom0-updates.*via zone work' \
	&& route dom0-updates default >/dev/null 2>&1 \
	&& grep -q 'gprefs-default updatevm' "$QCTL_LOG"; then
	ok "dom0-updates routes through a zone and back to stock"
else
	cat "$WORK/out"
	fail "dom0-updates routing went wrong"
fi
if printf 'n\n' | route template-updates work >"$WORK/out" 2>&1 \
	&& [ ! -f "$WORK/policy/51-wgq-routes.policy" ] \
	&& grep -q 'yours to paste' "$WORK/out"; then
	ok "declining the policy write installs nothing"
else
	cat "$WORK/out"
	fail "template-updates decline still wrote something"
fi
if printf 'y\n' | route template-updates work >"$WORK/out" 2>&1 \
	&& grep -q 'target=sys-fw-work' "$WORK/policy/51-wgq-routes.policy" \
	&& grep -q 'sys-fw-work|service.qubes-updates-proxy|1' "$FEATS" \
	&& grep -q 'Tor' "$WORK/out"; then
	ok "template-updates installs the 51-sorted policy and the proxy flag"
else
	cat "$WORK/out"
	fail "template-updates yes-path went wrong"
fi
route template-updates default >/dev/null 2>&1 || :
grep -v 'service.qubes-updates-proxy' "$FEATS" >"$FEATS.tmp" && mv "$FEATS.tmp" "$FEATS"
if printf 'n\n' | route clock work >"$WORK/out" 2>&1 \
	&& grep -q 'paradox' "$WORK/out" \
	&& ! grep -q 'gprefs-set clockvm' "$QCTL_LOG"; then
	ok "clock routing argues, and no means no"
else
	cat "$WORK/out"
	fail "the clock paradox warning went missing"
fi
if route dom0-updates alien >"$WORK/out" 2>&1; then
	fail "routing accepted a nonexistent zone"
elif grep -q "does not exist" "$WORK/out"; then
	ok "routing refuses an unknown zone"
else
	cat "$WORK/out"
	fail "unknown-zone refusal said the wrong thing"
fi

# 11a6d. The tree: every owned zone as a painted chain with its health
# read from the qube, plus the routes footer -- and a pipe sees no
# escapes.
TREE=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-tree
if env PATH="$WORK/bin:$PATH" WGQ_POLICY_DIR="$WORK/policy" sh "$TREE" >"$WORK/out" 2>&1 \
	&& grep -q '^sys-net$' "$WORK/out" \
	&& grep -q '└─ sys-firewall' "$WORK/out" \
	&& grep -q '├─ zone work' "$WORK/out" \
	&& grep -q 'ok peer=se-mma' "$WORK/out" \
	&& grep -q 'sys-wgq-work ─ sys-fw-work' "$WORK/out" \
	&& grep -q 'routes: dom0-updates sys-firewall | template-updates stock' "$WORK/out" \
	&& ! grep -q '\033' "$WORK/out"; then
	ok "tree draws the rooted forest, the health, and the routes"
else
	cat "$WORK/out"
	fail "the tree went wrong"
fi

# 11a6e. top --once: one snapshot, plain, with the kill-switch drop
# counter front and centre.
TOP=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-top
if env PATH="$WORK/bin:$PATH" sh "$TOP" work --once >"$WORK/out" 2>&1 \
	&& grep -q 'zone work' "$WORK/out" \
	&& grep -q 'ok peer=se-mma dns=10.64.0.1 · hs 12s' "$WORK/out" \
	&& grep -q 'drops 42' "$WORK/out" \
	&& grep -q 'rx' "$WORK/out" \
	&& ! grep -q '\033' "$WORK/out"; then
	ok "top --once snapshots state, handshake age and drops, plainly"
else
	cat "$WORK/out"
	fail "top --once went wrong"
fi

# 11a6f. logs: the merged journal, labeled by journald, escape-stripped
# before it touches a terminal -- a log line is where a hostile qube
# would put its escape sequence.
LOGS=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-logs
if env PATH="$WORK/bin:$PATH" sh "$LOGS" work >"$WORK/out" 2>&1 \
	&& grep -q 'zone work' "$WORK/out" \
	&& grep -q 'wgq-firewall: kill switch installed' "$WORK/out" \
	&& grep -q 'hostile' "$WORK/out" \
	&& ! grep -q '\033' "$WORK/out"; then
	ok "logs merges the journal and strips a hostile escape"
else
	cat "$WORK/out"
	fail "logs went wrong"
fi
if env PATH="$WORK/bin:$PATH" sh "$LOGS" work --since 'yesterday; rm -rf /' >"$WORK/out" 2>&1; then
	fail "a hostile --since value was accepted"
elif grep -q 'unusable --since' "$WORK/out"; then
	ok "a hostile --since value is refused before any qvm-run"
else
	cat "$WORK/out"
	fail "--since refusal went wrong"
fi

# 11a7. The restart cycle: plan first, clients named as going dark, one
# confirmation; fw down (forced, it stops under clients), vpn down,
# mgmt down, template down, fw and mgmt back up -- template stays
# halted. Declining runs nothing.
RESTART=$(cd "$(dirname "$0")/.." && pwd)/wgq/dom0/wgq-restart
printf 'debian-13-wgq|TemplateVM|-|False\nwgq-mgmt|AppVM|sys-firewall|False\n' >>"$FAKEQ"
printf 'wgq-mgmt|created-by-wgq\n' >>"$TAGS"
printf 'debian-13-wgq\nwgq-mgmt\nwork\n' >>"$RUNNING"
env PATH="$WORK/bin:$PATH" qvm-prefs work netvm sys-fw-work
cp "$QCTL_LOG" "$WORK/qctl.rst"
if printf 'n\n' | env PATH="$WORK/bin:$PATH" sh "$RESTART" >"$WORK/out" 2>&1 \
	&& grep -q 'DARK' "$WORK/out" && grep -q 'work' "$WORK/out" \
	&& cmp -s "$QCTL_LOG" "$WORK/qctl.rst"; then
	ok "restart declined runs nothing, after naming the dark clients"
else
	cat "$WORK/out"
	fail "restart declined still moved something"
fi
if printf 'y\n' | env PATH="$WORK/bin:$PATH" sh "$RESTART" >"$WORK/out" 2>&1 \
	&& grep -q 'shutdown --force --wait sys-fw-work' "$QCTL_LOG" \
	&& grep -q 'shutdown --wait sys-wgq-work' "$QCTL_LOG" \
	&& grep -q 'shutdown --wait wgq-mgmt' "$QCTL_LOG" \
	&& grep -q 'shutdown --wait debian-13-wgq' "$QCTL_LOG" \
	&& grep -q 'started sys-fw-work' "$QCTL_LOG" \
	&& grep -q 'started wgq-mgmt' "$QCTL_LOG" \
	&& ! grep -qx 'debian-13-wgq' "$RUNNING" \
	&& grep -qx 'sys-fw-work' "$RUNNING"; then
	ok "restart cycles zones, mgmt and template; template stays halted"
else
	cat "$WORK/out"
	tail -8 "$QCTL_LOG"
	fail "the restart cycle went wrong"
fi
env PATH="$WORK/bin:$PATH" qvm-prefs work netvm sys-firewall
grep -vE '^(debian-13-wgq|wgq-mgmt)\|' "$FAKEQ" >"$FAKEQ.tmp" && mv "$FAKEQ.tmp" "$FAKEQ"

# 11b. list --json emits one parseable document with at least the zone
# rows this harness created -- an empty [] must not pass.
if zone list --json >"$WORK/out" 2>/dev/null \
	&& python3 -c "
import json, sys
rows = json.load(open('$WORK/out'))
assert isinstance(rows, list), rows
assert any(r.get('zone') == 'work' for r in rows), rows
for r in rows:
	assert set(r) == {'zone', 'vpn', 'fw', 'color', 'clients'}, r
	assert isinstance(r['clients'], list), r
"; then
	ok "list --json parses and carries zone, vpn, fw, clients"
else
	cat "$WORK/out"
	fail "list --json is not clean parseable JSON"
fi

# 12. A stranger's qube sharing the sys-fw-* grammar is not a zone: not
# listed, not routed through, not destroyed. The created-by-wgq tag
# stamped at creation is the proof; a name proves nothing.
printf 'sys-fw-alien|AppVM|sys-firewall|True\n' >>"$FAKEQ"
printf 'sys-fw-alien\n' >>"$RUNNING"
if zone list >"$WORK/out" 2>&1 \
	&& grep -q 'sys-fw-alien exists but was not created by wgq' "$WORK/out" \
	&& ! grep -q '^alien ' "$WORK/out"; then
	ok "list refuses to present a stranger's qube as a zone"
else
	cat "$WORK/out"
	fail "a foreign qube was listed as a zone"
fi
if zone attach alien media >"$WORK/out" 2>&1; then
	fail "attach routed a client through a stranger's qube"
elif grep -q 'refusing to route' "$WORK/out" \
	&& [ "$(netvm_of media)" = "sys-fw-z2" ]; then
	ok "attach refuses a firewall wgq did not make"
else
	cat "$WORK/out"
	fail "the foreign-attach refusal failed for the wrong reason"
fi
if printf 'alien\n' | env PATH="$WORK/bin:$PATH" sh "$ZONE" remove alien >"$WORK/out" 2>&1; then
	fail "remove destroyed a stranger's qube"
elif grep -q 'refusing to destroy' "$WORK/out" && grep -q '^sys-fw-alien|' "$FAKEQ"; then
	ok "remove refuses a firewall wgq did not make"
else
	cat "$WORK/out"
	fail "the foreign-remove refusal failed for the wrong reason"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_zone: all passed\n'
exit 0
