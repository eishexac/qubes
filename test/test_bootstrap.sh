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
	if grep -q 'airlock pull' "$out" \
		&& grep -q 'airlock apply wgq' "$out" \
		&& grep -q 'dist/wgq' "$out"; then
		ok "bootstrap builds, verifies, and prints the dom0 steps"
	else
		cat "$out"; fail "bootstrap output is missing pieces"
	fi
	# The payload dom0 pulls must hold no undeclared binaries: the checks
	# above ran the test suite, so bytecode droppings existed -- bootstrap
	# must have scrubbed them, or the ingest scan will refuse the tree.
	if find "$ROOT/wgq" -type d -name __pycache__ | grep -q .; then
		fail "bootstrap left __pycache__ in the project tree"
	else
		ok "project tree left clean of bytecode droppings"
	fi
else
	cat "$out"; fail "bootstrap failed on a healthy tree"
fi

if (cd "$ROOT" && sh bootstrap.sh) >"$out" 2>&1; then
	fail "bootstrap ran with no project named"
elif grep -q 'name one or more projects' "$out" && grep -q 'available:.*wgq' "$out"; then
	ok "a missing project name is refused, and the available ones are listed"
else
	cat "$out"; fail "no-project refusal failed for the wrong reason"
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

# Several projects in one run: each is checked and gets its own dom0
# pull/apply pair. Only wgq exists, so name it twice -- the loop must
# process it once per name, not collapse to one.
if (cd "$ROOT" && sh bootstrap.sh wgq wgq) >"$out" 2>&1 \
	&& [ "$(grep -c 'airlock pull' "$out")" -eq 2 ] \
	&& [ "$(grep -c 'airlock apply wgq' "$out")" -eq 2 ]; then
	ok "multiple named projects each get their own dom0 commands"
else
	cat "$out"; fail "multi-project bootstrap went wrong"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s failure(s)\n' "$failures"
	exit 1
fi
printf 'test_bootstrap: all passed\n'
exit 0
