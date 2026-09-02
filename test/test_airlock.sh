#!/bin/sh
#
# Tests for dom0/airlock, run without a qube: AIRLOCK_TRANSPORT is pointed
# at a local tar, AIRLOCK_SALT_ROOT at a scratch directory, and the
# confirmation is answered over stdin exactly as an operator would type
# it. The cases mirror the script's promises: nothing installs without a
# yes, nothing installs that the scan refused, and the receipt notices
# tampering afterwards.

set -u

INGEST=$(cd "$(dirname "$0")/.." && pwd)/dom0/airlock
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

export AIRLOCK_SALT_ROOT="$WORK/salt"
export PAGER=cat
mkdir -p "$AIRLOCK_SALT_ROOT"

# The fake transport ignores the qube name and tars the local "repo".
cat > "$WORK/transport" <<'EOF'
#!/bin/sh
tar -C "$2" -cf - "$3"
EOF
chmod +x "$WORK/transport"
export AIRLOCK_TRANSPORT="$WORK/transport"

REPO="$WORK/repo"
mkdir -p "$REPO/demo/salt"
printf 'first version\n' > "$REPO/demo/readme.txt"
printf 'x:\n  test.nop: []\n' > "$REPO/demo/salt/x.sls"

failures=0
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
ok()   { printf 'ok:   %s\n' "$*"; }

# $1 = the answers typed over stdin: first the open-the-review prompt
# (empty = default = open; PAGER=cat prints the diff into the capture),
# then the typed install confirmation.
run_pull() { printf '%b' "$1" | "$INGEST" pull testqube demo "$REPO" >"$WORK/out" 2>&1; }

# 1. A fresh pull with a typed yes installs the tree and writes a receipt.
if run_pull '\nyes\n' \
	&& [ -f "$AIRLOCK_SALT_ROOT/demo/readme.txt" ] \
	&& [ -f "$AIRLOCK_SALT_ROOT/.ingest-receipts/demo" ]; then
	ok "fresh pull installs after yes"
else
	cat "$WORK/out"; fail "fresh pull did not install"
fi

# 2. The review shown before that yes contained the new content as a diff.
if grep -q '^+first version' "$WORK/out"; then
	ok "review showed the incoming content"
else
	fail "review did not show the diff"
fi

# 3. Pulling again with nothing changed is a no-op and says so.
if run_pull '' && grep -q 'already exactly' "$WORK/out"; then
	ok "unchanged pull is a no-op"
else
	fail "unchanged pull was not detected"
fi

# 4. Anything but a literal yes refuses, and the tree stays untouched.
printf 'second version\n' > "$REPO/demo/readme.txt"
if run_pull '\nno\n'; then
	fail "a 'no' answer still exited 0"
else
	if grep -q 'first version' "$AIRLOCK_SALT_ROOT/demo/readme.txt"; then
		ok "declined pull left the installed tree alone"
	else
		fail "declined pull modified the installed tree"
	fi
fi

# 5. An update pull shows exactly the change and installs it.
if run_pull '\nyes\n' \
	&& grep -q '^-first version' "$WORK/out" \
	&& grep -q '^+second version' "$WORK/out" \
	&& grep -q 'second version' "$AIRLOCK_SALT_ROOT/demo/readme.txt"; then
	ok "update pull diffs and installs the change"
else
	cat "$WORK/out"; fail "update pull went wrong"
fi

# 5b. Declining the pager is a typed choice, said out loud; the typed
# install gate still stands afterwards.
printf 'third version\n' > "$REPO/demo/readme.txt"
if run_pull 'n\nyes\n' \
	&& grep -q 'review skipped' "$WORK/out" \
	&& ! grep -q '^+third version' "$WORK/out" \
	&& grep -q 'third version' "$AIRLOCK_SALT_ROOT/demo/readme.txt"; then
	ok "skipping the review is typed, warned about, and still gated on yes"
else
	cat "$WORK/out"; fail "the review-skip path went wrong"
fi

# 6. status: clean after approval, loud after tampering.
if "$INGEST" status >"$WORK/out" 2>&1 && grep -q 'ok, as approved' "$WORK/out"; then
	ok "status reports the approved tree as ok"
else
	cat "$WORK/out"; fail "status did not report ok"
fi
printf 'tampered\n' >> "$AIRLOCK_SALT_ROOT/demo/readme.txt"
if "$INGEST" status >"$WORK/out" 2>&1; then
	fail "status exited 0 for a tampered tree"
elif grep -q 'MODIFIED' "$WORK/out"; then
	ok "status flags a tampered tree"
else
	fail "status did not name the tampering"
fi

# The refusal tests assert the message as well as the exit code: a script
# that failed to run at all would otherwise pass them.
# 7. A symlink in the payload is refused outright.
ln -s /etc/passwd "$REPO/demo/evil-link"
if run_pull ''; then
	fail "a payload with a symlink was accepted"
elif grep -q 'not plain files' "$WORK/out"; then
	ok "symlink payload refused"
else
	cat "$WORK/out"; fail "symlink refusal failed for the wrong reason"
fi
rm "$REPO/demo/evil-link"

# 8. An undeclared binary is refused; declaring it makes it reviewable.
printf 'BIN\000ARY\n' > "$REPO/demo/blob.bin"
if run_pull ''; then
	fail "an undeclared binary was accepted"
elif grep -q 'undeclared binary' "$WORK/out"; then
	ok "undeclared binary refused"
else
	cat "$WORK/out"; fail "binary refusal failed for the wrong reason"
fi
printf 'blob.bin\n' > "$REPO/demo/.ingest-binaries"
if run_pull '\nyes\n' && grep -q 'blob.bin' "$WORK/out" && grep -q 'staged:' "$WORK/out"; then
	ok "declared binary accepted and shown by hash"
else
	cat "$WORK/out"; fail "declared binary handling went wrong"
fi

# 9. A hostile file name is refused.
printf 'x\n' > "$REPO/demo/bad name.txt"
if run_pull ''; then
	fail "a payload with a space in a file name was accepted"
elif grep -q 'file names outside' "$WORK/out"; then
	ok "unportable file name refused"
else
	cat "$WORK/out"; fail "file-name refusal failed for the wrong reason"
fi
rm "$REPO/demo/bad name.txt"

# ---- apply -----------------------------------------------------------------
# A fake qubesctl logs its arguments; a scratch policy dir stands in for
# /etc/qubes/policy.d. Answers are typed over stdin, like an operator would.

cat > "$WORK/qubesctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${QLOG:?}"
exit "${QRC:-0}"
EOF
chmod +x "$WORK/qubesctl"

run_apply() {
	# $1 = answers piped to the prompts, $2 = fake qubesctl exit code
	printf '%b' "$1" | env AIRLOCK_QUBESCTL="$WORK/qubesctl" \
		AIRLOCK_POLICY_DIR="$WORK/policy.d" \
		QLOG="$WORK/qlog" QRC="${2:-0}" \
		"$INGEST" apply demo >"$WORK/out" 2>&1
}
reset_apply() { : > "$WORK/qlog"; rm -rf "$WORK/policy.d"; mkdir "$WORK/policy.d"; }

# 10. Applying a project that declares no plan is a clear refusal.
reset_apply
if run_apply 'y\n'; then
	fail "apply without a plan exited 0"
elif grep -q 'declares no apply plan' "$WORK/out"; then
	ok "apply refuses a project without a plan"
else
	cat "$WORK/out"; fail "no-plan refusal failed for the wrong reason"
fi

# Give the demo project a plan and a policy file, and install them.
mkdir -p "$REPO/demo/dom0"
printf 'demo policy line\n' > "$REPO/demo/dom0/demo.policy"
cat > "$REPO/demo/.ingest-apply" <<'EOF'
# comment shown during apply
salt demo.state
salt-target demo-tpl demo.state
policy demo.policy
EOF
run_pull '\nyes\n' || { cat "$WORK/out"; fail "pull of the plan-bearing tree failed"; }

# 11. A confirmed plan runs every step through the fixed verbs, each one
# announced with its place in the walk.
reset_apply
if run_apply 'y\ny\ny\n' \
	&& grep -q -- '--show-output state.apply demo.state' "$WORK/qlog" \
	&& grep -q -- '--skip-dom0 --targets=demo-tpl' "$WORK/qlog" \
	&& grep -q '^\[1/3\] ' "$WORK/out" \
	&& grep -q '^\[3/3\] ' "$WORK/out" \
	&& [ -f "$WORK/policy.d/demo.policy" ]; then
	ok "apply runs salt, salt-target and policy steps after yes, counted"
else
	cat "$WORK/out" "$WORK/qlog" 2>/dev/null; fail "confirmed apply went wrong"
fi

# 12. Skipped steps run nothing.
reset_apply
if run_apply 's\ns\ns\n' && [ ! -s "$WORK/qlog" ] && [ ! -f "$WORK/policy.d/demo.policy" ]; then
	ok "skipped steps run nothing"
else
	cat "$WORK/out"; fail "skip still ran something"
fi

# 13. Stopping aborts the rest of the plan.
reset_apply
if run_apply 'q\n'; then
	fail "a 'q' answer still exited 0"
elif [ ! -s "$WORK/qlog" ] && grep -q 'stopped' "$WORK/out"; then
	ok "stop aborts before anything runs"
else
	cat "$WORK/out"; fail "stop behaved unexpectedly"
fi

# 14. A failing step halts the plan loudly.
reset_apply
if run_apply 'y\ny\ny\n' 1; then
	fail "a failing qubesctl still exited 0"
elif grep -q 'step failed' "$WORK/out"; then
	ok "a failing step halts the plan"
else
	cat "$WORK/out"; fail "failure handling went wrong"
fi

# 15. A plan with an unknown verb is refused whole, before any prompt --
# and the refusal teaches the way out: a plan from a newer tree means the
# installed tool is stale, so the message names the self-update pull.
printf 'rm -rf /\n' > "$REPO/demo/.ingest-apply"
run_pull '\nyes\n' || { cat "$WORK/out"; fail "pull of the malformed plan failed"; }
reset_apply
if run_apply '' ; then
	fail "a malformed plan was accepted"
elif grep -q 'unknown verb' "$WORK/out" && [ ! -s "$WORK/qlog" ] \
	&& grep -q 'pull <qube> dom0' "$WORK/out"; then
	ok "malformed plan refused whole, nothing ran, self-update taught"
else
	cat "$WORK/out"; fail "malformed-plan refusal failed for the wrong reason"
fi

# 16. A tree that drifted since approval is not applied.
printf 'tampered\n' >> "$AIRLOCK_SALT_ROOT/demo/readme.txt"
reset_apply
if run_apply 'y\n'; then
	fail "apply ran on a tree that drifted from its receipt"
elif grep -q 'differs from what was approved' "$WORK/out" && [ ! -s "$WORK/qlog" ]; then
	ok "drifted tree refused before anything runs"
else
	cat "$WORK/out"; fail "drift refusal failed for the wrong reason"
fi

# ---- the template verb -----------------------------------------------------
cat > "$WORK/qvm-check" <<'EOF'
#!/bin/sh
exit "${QCHECK_RC:-0}"
EOF
cat > "$WORK/qvm-template" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${QTLOG:?}"
exit 0
EOF
chmod +x "$WORK/qvm-check" "$WORK/qvm-template"

run_apply_t() {
	# $1 = answers, $2 = qvm-check exit code (0 = template present)
	printf '%b' "$1" | env AIRLOCK_QUBESCTL="$WORK/qubesctl" \
		AIRLOCK_POLICY_DIR="$WORK/policy.d" \
		AIRLOCK_QVM_TEMPLATE="$WORK/qvm-template" \
		AIRLOCK_QVM_CHECK="$WORK/qvm-check" \
		QLOG="$WORK/qlog" QTLOG="$WORK/qtlog" QCHECK_RC="$2" QRC=0 \
		"$INGEST" apply demo >"$WORK/out" 2>&1
}
reset_apply_t() { reset_apply; : > "$WORK/qtlog"; }

# A fresh, drift-free tree with a template step in the plan.
cat > "$REPO/demo/.ingest-apply" <<'EOF'
template demo-tpl
salt demo.state
EOF
run_pull '\nyes\n' || { cat "$WORK/out"; fail "pull of the template-bearing plan failed"; }

# 17. Present template: skipped automatically, no prompt spent, no install.
reset_apply_t
if run_apply_t 'y\n' 0 \
	&& grep -q 'already installed' "$WORK/out" \
	&& [ ! -s "$WORK/qtlog" ] \
	&& grep -q 'state.apply demo.state' "$WORK/qlog"; then
	ok "present template auto-skips; the rest of the plan still runs"
else
	cat "$WORK/out"; fail "template auto-skip went wrong"
fi

# 18. Absent template: shown, confirmed, installed.
reset_apply_t
if run_apply_t 'y\ny\n' 1 \
	&& grep -q 'install demo-tpl' "$WORK/qtlog" \
	&& grep -q 'state.apply demo.state' "$WORK/qlog"; then
	ok "absent template installs after a yes"
else
	cat "$WORK/out" "$WORK/qtlog" 2>/dev/null; fail "template install step went wrong"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_airlock: all passed\n'
exit 0
