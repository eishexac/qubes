#!/bin/sh
#
# bootstrap.sh must run the project's own checks for real and print dom0
# instructions with real values -- and refuse bad input loudly instead of
# printing instructions for a project it never verified.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp) || exit 2
trap 'rm -f "$out"' EXIT INT TERM

failures=0
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

if (cd "$ROOT" && sh bootstrap.sh wgq) >"$out" 2>&1; then
	if grep -q 'qubes-ingest pull' "$out" \
		&& grep -q 'qubes-ingest apply wgq' "$out" \
		&& grep -q 'dist/wgq' "$out"; then
		ok "bootstrap builds, verifies, and prints the dom0 steps"
	else
		cat "$out"; fail "bootstrap output is missing pieces"
	fi
else
	cat "$out"; fail "bootstrap failed on a healthy tree"
fi

if (cd "$ROOT" && sh bootstrap.sh 'no such!') >"$out" 2>&1; then
	fail "a hostile project name was accepted"
else
	ok "unusable project name refused"
fi

if (cd "$ROOT" && sh bootstrap.sh nonexistent) >"$out" 2>&1; then
	fail "a missing project was accepted"
else
	ok "missing project refused"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_bootstrap: all passed\n'
exit 0
