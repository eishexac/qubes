#!/bin/sh
#
# Tests for dom0/ingest, run without a qube: QUBES_INGEST_TRANSPORT is pointed
# at a local tar, QUBES_INGEST_SALT_ROOT at a scratch directory, and the
# confirmation is answered over stdin exactly as an operator would type
# it. The cases mirror the script's promises: nothing installs without a
# yes, nothing installs that the scan refused, and the receipt notices
# tampering afterwards.

set -u

INGEST=$(cd "$(dirname "$0")/.." && pwd)/dom0/ingest
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

export QUBES_INGEST_SALT_ROOT="$WORK/salt"
export PAGER=cat
mkdir -p "$QUBES_INGEST_SALT_ROOT"

# The fake transport ignores the qube name and tars the local "repo".
cat > "$WORK/transport" <<'EOF'
#!/bin/sh
tar -C "$2" -cf - "$3"
EOF
chmod +x "$WORK/transport"
export QUBES_INGEST_TRANSPORT="$WORK/transport"

REPO="$WORK/repo"
mkdir -p "$REPO/demo/salt"
printf 'first version\n' > "$REPO/demo/readme.txt"
printf 'x:\n  test.nop: []\n' > "$REPO/demo/salt/x.sls"

failures=0
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
ok()   { printf 'ok:   %s\n' "$*"; }

run_pull() { printf '%s\n' "$1" | "$INGEST" pull testqube demo "$REPO" >"$WORK/out" 2>&1; }

# 1. A fresh pull with a typed yes installs the tree and writes a receipt.
if run_pull yes \
	&& [ -f "$QUBES_INGEST_SALT_ROOT/demo/readme.txt" ] \
	&& [ -f "$QUBES_INGEST_SALT_ROOT/.ingest-receipts/demo" ]; then
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
if run_pull yes && grep -q 'already exactly' "$WORK/out"; then
	ok "unchanged pull is a no-op"
else
	fail "unchanged pull was not detected"
fi

# 4. Anything but a literal yes refuses, and the tree stays untouched.
printf 'second version\n' > "$REPO/demo/readme.txt"
if run_pull no; then
	fail "a 'no' answer still exited 0"
else
	if grep -q 'first version' "$QUBES_INGEST_SALT_ROOT/demo/readme.txt"; then
		ok "declined pull left the installed tree alone"
	else
		fail "declined pull modified the installed tree"
	fi
fi

# 5. An update pull shows exactly the change and installs it.
if run_pull yes \
	&& grep -q '^-first version' "$WORK/out" \
	&& grep -q '^+second version' "$WORK/out" \
	&& grep -q 'second version' "$QUBES_INGEST_SALT_ROOT/demo/readme.txt"; then
	ok "update pull diffs and installs the change"
else
	cat "$WORK/out"; fail "update pull went wrong"
fi

# 6. status: clean after approval, loud after tampering.
if "$INGEST" status >"$WORK/out" 2>&1 && grep -q 'ok, as approved' "$WORK/out"; then
	ok "status reports the approved tree as ok"
else
	cat "$WORK/out"; fail "status did not report ok"
fi
printf 'tampered\n' >> "$QUBES_INGEST_SALT_ROOT/demo/readme.txt"
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
if run_pull yes; then
	fail "a payload with a symlink was accepted"
elif grep -q 'not plain files' "$WORK/out"; then
	ok "symlink payload refused"
else
	cat "$WORK/out"; fail "symlink refusal failed for the wrong reason"
fi
rm "$REPO/demo/evil-link"

# 8. An undeclared binary is refused; declaring it makes it reviewable.
printf 'BIN\000ARY\n' > "$REPO/demo/blob.bin"
if run_pull yes; then
	fail "an undeclared binary was accepted"
elif grep -q 'undeclared binary' "$WORK/out"; then
	ok "undeclared binary refused"
else
	cat "$WORK/out"; fail "binary refusal failed for the wrong reason"
fi
printf 'blob.bin\n' > "$REPO/demo/.ingest-binaries"
if run_pull yes && grep -q 'blob.bin' "$WORK/out" && grep -q 'staged:' "$WORK/out"; then
	ok "declared binary accepted and shown by hash"
else
	cat "$WORK/out"; fail "declared binary handling went wrong"
fi

# 9. A hostile file name is refused.
printf 'x\n' > "$REPO/demo/bad name.txt"
if run_pull yes; then
	fail "a payload with a space in a file name was accepted"
elif grep -q 'file names outside' "$WORK/out"; then
	ok "unportable file name refused"
else
	cat "$WORK/out"; fail "file-name refusal failed for the wrong reason"
fi
rm "$REPO/demo/bad name.txt"

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_ingest: all passed\n'
exit 0
