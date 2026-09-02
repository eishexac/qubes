# msg.sh - one voice for the wgq dom0 tools (wgq, wgq-zone, wgq-uninstall).
#
# Sourced, not executed; the sourcing script sets PROG first. Every level
# writes to STDERR, so stdout carries only data a caller may pipe (a key,
# a server list) -- the bug that made `wgq pubkey | wgq provision` choke
# on the framing line was note/ok going to stdout. Levels:
#
#     trace  dim,    the framed qvm-run a wrapper is about to run
#     note   plain,  what is happening
#     ok     green,  something completed
#     warn   yellow, something to know; nothing failed
#     die    red,    a refusal or failure, then exit
#
# Colour discipline (non-negotiable in dom0, where output gets piped,
# grepped and read back): an escape code reaches stderr only when stderr
# is a terminal, NO_COLOR is unset and TERM is not dumb. Apart from the
# escape codes the coloured and plain forms are byte-identical, so nothing
# that parses this output can tell the difference.
#
# airlock carries an inlined copy of note/ok/warn/die (it must remain a
# single file you can carry into dom0 by hand); keep the two in step.

PROG=${PROG:-wgq}

colour_to() {
	[ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ] && [ -t "$1" ]
}

# _say <sgr> <label> <message> -- note/ok/warn/die funnel through here,
# always to stderr; only the "PROG: label" prefix is ever coloured.
_say() {
	m_pre="$PROG:${2:+ $2}"
	if [ -n "$1" ] && colour_to 2; then
		printf '\033[%sm%s\033[0m %s\n' "$1" "$m_pre" "$3" >&2
	else
		printf '%s %s\n' "$m_pre" "$3" >&2
	fi
}

# trace dims the WHOLE line, not just the prefix: the framed command is
# transparency, deliberately subordinate to the messages around it.
trace() {
	if colour_to 2; then
		printf '\033[2m%s %s\033[0m\n' "$PROG:" "$*" >&2
	else
		printf '%s %s\n' "$PROG:" "$*" >&2
	fi
}

note() { _say ''   ''         "$*"; }
ok()   { _say '32' ''         "$*"; }
warn() { _say '33' 'warning:' "$*"; }
die()  { _say '31' 'error:'   "$*"; exit 1; }
