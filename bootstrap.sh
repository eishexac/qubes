#!/bin/sh
#
# bootstrap.sh - from a fresh clone to printed dom0 commands, in one run.
#
# Made for a disposable qube: open a terminal in a networked DispVM, then
#
#     git clone https://github.com/eishexac/qubes.git ~/qubes
#     cd ~/qubes && sh bootstrap.sh wgq          # one or more project names
#
# It checks the build dependencies, runs each named project's own checks,
# builds the artifacts and proves the builds reproduce, then prints the
# exact commands to type in dom0 -- with THIS qube's real name and path
# filled in. Keep the qube running until dom0 has pulled; if it is a
# disposable, everything here disappears when you close it, the point.
#
# This automates only the qube side. The dom0 side stays typed by hand and
# reviewed, because that is the security model, not an oversight.

set -eu

# Never in dom0: dom0 pulls, it does not clone or build.
if [ -e /etc/qubes-release ] && ! command -v qrexec-client-vm >/dev/null 2>&1; then
	printf 'bootstrap: this runs in a qube, never in dom0\n' >&2
	exit 2
fi

cd "$(dirname "$0")"

# The project(s) are named, never defaulted: this is a monorepo of separate
# projects, and which ones you put into dom0 is a decision, not a guess
# bootstrap makes for you. Name one or more; each is built and installed
# independently, in the order given.
if [ "$#" -eq 0 ]; then
	printf 'bootstrap: name one or more projects, e.g.\n' >&2
	printf '    sh bootstrap.sh wgq\n' >&2
	avail=$(for d in */Makefile; do [ -f "$d" ] && printf '%s ' "${d%/Makefile}"; done)
	[ -n "${avail% }" ] && printf 'available: %s\n' "${avail% }" >&2
	exit 2
fi
for PROJECT in "$@"; do
	case "$PROJECT" in
		*[!a-z0-9-]*)
			printf 'bootstrap: unusable project name: %s\n' "$PROJECT" >&2
			exit 2 ;;
	esac
	if [ ! -d "$PROJECT" ] || [ ! -f "$PROJECT/Makefile" ]; then
		printf 'bootstrap: no project %s/ here; run from the repository root\n' "$PROJECT" >&2
		exit 2
	fi
done

missing=""
for dep in make python3 unzip; do
	command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
if [ -n "$missing" ]; then
	printf 'bootstrap: missing tool(s):%s\n' "$missing" >&2
	printf 'bootstrap: in a Debian-based qube: sudo apt install make python3 unzip\n' >&2
	exit 2
fi

if command -v sha256sum >/dev/null 2>&1; then SHA=sha256sum; else SHA="shasum -a 256"; fi

# Check, build and verify EVERY named project before printing anything: dom0
# gets the commands only once all of them have passed and reproduced. One
# project's failure stops the run (set -e), so nothing half-checked is
# handed on.
ARTIFACTS=""
for PROJECT in "$@"; do
	printf '== %s: check ==\n' "$PROJECT"
	make -C "$PROJECT" check
	printf '\n== %s: build and verify (must be deterministic) ==\n' "$PROJECT"
	make -C "$PROJECT" verify
	# The test run leaves __pycache__ droppings in the tree; they are
	# binaries the airlock scan would rightly refuse, and dom0 has no use
	# for them. The artifact itself is already built and about to be hashed.
	find "$PROJECT" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	# shellcheck disable=SC2086 # SHA may be two words (shasum -a 256)
	h=$(cd "$PROJECT" || exit 0; $SHA dist/* 2>/dev/null || :)
	ARTIFACTS="${ARTIFACTS}    ${PROJECT}: ${h:-none}
"
done

NAME=$(qubesdb-read /name 2>/dev/null || true)
QUBE_KNOWN=1
if [ -z "$NAME" ]; then
	NAME='<this-qube>'
	QUBE_KNOWN=0
fi
REPO=$(pwd)

# Where this tree stands relative to a signed release: REPORTED, never
# gated -- installing a branch is how development happens -- but the
# human about to type dom0 commands should see whether what they hold
# is an attested release or a moving branch, on the same screen as
# those commands.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
	TREE='not a git checkout; release verification unavailable'
elif RELEASE=$(git describe --exact-match --tags HEAD 2>/dev/null) && [ -n "$RELEASE" ]; then
	if git verify-tag "$RELEASE" >/dev/null 2>&1; then
		TREE="release $RELEASE -- tag signature VERIFIED"
	else
		TREE="release $RELEASE -- tag signature NOT verified here.
           Import the key and compare its fingerprint with SECURITY.md:
               gpg --locate-keys hexac@existin.space
               git verify-tag $RELEASE"
	fi
else
	TREE="development tree: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git rev-parse --short HEAD 2>/dev/null) -- not a release.
           For a verified release:  git verify-tag <project>-vX.Y.Z && git checkout <project>-vX.Y.Z"
fi

printf '\n== all checks passed ==\n\n'
printf 'projects:  %s\n' "$*"
printf 'artifacts:\n%s' "$ARTIFACTS"
printf 'tree:      %s\n' "$TREE"
printf 'qube:      %s\n' "$NAME"
printf 'repo:      %s\n\n' "$REPO"

printf 'In dom0 -- FIRST TIME ONLY -- install the airlock, and read it first:\n\n'
printf "    qvm-run --pass-io %s 'cat %s/dom0/airlock' > /tmp/airlock\n" "$NAME" "$REPO"
printf '    less /tmp/airlock\n'
printf '    sudo install -m 0755 /tmp/airlock /usr/local/bin/airlock\n\n'

printf 'Then, still in dom0, for each project:\n\n'
for PROJECT in "$@"; do
	printf '    sudo airlock pull %s %s %s\n' "$NAME" "$PROJECT" "$REPO"
	printf '    sudo airlock apply %s\n' "$PROJECT"
done

printf '\nThe pull shows everything as a diff and installs only after you type\n'
printf '"yes"; apply then walks the project'"'"'s install plan one confirmed step\n'
printf 'at a time. Keep this qube running until the pull(s) have finished.\n'

if [ "$QUBE_KNOWN" -eq 0 ]; then
	printf '\nnote: this does not look like a Qubes VM (no qubesdb), so <this-qube>\n'
	printf 'above is a placeholder -- substitute the name of the qube holding this\n'
	printf 'clone when you type the commands.\n'
fi
