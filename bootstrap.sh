#!/bin/sh
#
# bootstrap.sh - from a fresh clone to printed dom0 commands, in one run.
#
# Made for a disposable qube: open a terminal in a networked DispVM, then
#
#     git clone https://github.com/eishexac/qubes.git ~/qubes
#     cd ~/qubes && sh bootstrap.sh
#
# It checks the build dependencies, runs the project's own checks, builds
# the artifact and proves the build reproduces, then prints the exact
# commands to type in dom0 -- with THIS qube's real name and path filled
# in. Keep the qube running until dom0 has pulled; if it is a disposable,
# everything here disappears when you close it, which is the point.
#
# This automates only the qube side. The dom0 side stays typed by hand and
# reviewed, because that is the security model, not an oversight.

set -eu

PROJECT=${1:-wgq}
case "$PROJECT" in
	''|*[!a-z0-9-]*)
		printf 'bootstrap: unusable project name\n' >&2
		exit 2 ;;
esac

# Never in dom0: dom0 pulls, it does not clone or build.
if [ -e /etc/qubes-release ] && ! command -v qrexec-client-vm >/dev/null 2>&1; then
	printf 'bootstrap: this runs in a qube, never in dom0\n' >&2
	exit 2
fi

cd "$(dirname "$0")"
if [ ! -d "$PROJECT" ] || [ ! -f "$PROJECT/Makefile" ]; then
	printf 'bootstrap: no project %s/ here; run from the repository root\n' "$PROJECT" >&2
	exit 2
fi

missing=""
for dep in make python3 unzip; do
	command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
if [ -n "$missing" ]; then
	printf 'bootstrap: missing tool(s):%s\n' "$missing" >&2
	printf 'bootstrap: in a Debian-based qube: sudo apt install make python3 unzip\n' >&2
	exit 2
fi

printf '== %s: check ==\n' "$PROJECT"
make -C "$PROJECT" check
printf '\n== %s: build and verify (must be deterministic) ==\n' "$PROJECT"
make -C "$PROJECT" verify

if command -v sha256sum >/dev/null 2>&1; then SHA=sha256sum; else SHA="shasum -a 256"; fi
# shellcheck disable=SC2086 # SHA may be two words (shasum -a 256)
HASH=$(cd "$PROJECT" && $SHA dist/* 2>/dev/null || true)

NAME=$(qubesdb-read /name 2>/dev/null || true)
QUBE_KNOWN=1
if [ -z "$NAME" ]; then
	NAME='<this-qube>'
	QUBE_KNOWN=0
fi
REPO=$(pwd)

cat <<EOF

== all checks passed ==

project:   $PROJECT
artifacts: ${HASH:-none}
qube:      $NAME
repo:      $REPO

In dom0 -- FIRST TIME ONLY -- install the airlock, and read it first:

    qvm-run --pass-io $NAME 'cat $REPO/dom0/ingest' > ingest
    less ingest
    sudo install -m 0755 ingest /usr/local/bin/qubes-ingest

Then, still in dom0:

    sudo qubes-ingest pull $NAME $PROJECT $REPO
    sudo qubes-ingest apply $PROJECT

The pull shows everything as a diff and installs only after you type
"yes"; apply then walks the project's install plan one confirmed step at
a time. Keep this qube running until the pull has finished.
EOF

if [ "$QUBE_KNOWN" -eq 0 ]; then
	cat <<'EOF'

note: this does not look like a Qubes VM (no qubesdb), so <this-qube>
above is a placeholder -- substitute the name of the qube holding this
clone when you type the commands.
EOF
fi
