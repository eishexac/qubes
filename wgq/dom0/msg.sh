# msg.sh - one voice for the wgq dom0 tools (wgq-zone, wgq-uninstall).
#
# Sourced, not executed; the sourcing script sets PROG first. Four levels:
#
#     note   plain,  stdout        what is happening
#     ok     green,  stdout        something completed
#     warn   yellow, stderr        something to know; nothing failed
#     die    red,    stderr, exits a refusal or failure
#
# Colour discipline (non-negotiable in dom0, where output gets piped,
# grepped and read back): escape codes reach a stream only when that
# stream is a terminal, NO_COLOR is unset and TERM is not dumb. Apart
# from the escape codes the coloured and plain forms are byte-identical,
# so nothing that parses this output can tell the difference.
#
# airlock carries an inlined copy of this file (it must remain a
# single file you can carry into dom0 by hand); keep the two in step.

PROG=${PROG:-wgq}

colour_to() {
	[ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ] && [ -t "$1" ]
}

# _say <fd-for-tty-check> <sgr> <label> <message> -- every level funnels
# through here; only the "PROG: label" prefix is ever coloured.
_say() {
	m_pre="$PROG:${3:+ $3}"
	if [ -n "$2" ] && colour_to "$1"; then
		printf '\033[%sm%s\033[0m %s\n' "$2" "$m_pre" "$4"
	else
		printf '%s %s\n' "$m_pre" "$4"
	fi
}

note() { _say 1 ''   ''         "$*"; }
ok()   { _say 1 '32' ''         "$*"; }
warn() { _say 2 '33' 'warning:' "$*" >&2; }
die()  { _say 2 '31' 'error:'   "$*" >&2; exit 1; }
