# bash completion for wgq (dom0). Deliberately bash, not POSIX sh --
# completion is a bash feature. Installed by wgq.wg-cli into
# /usr/share/bash-completion/completions/wgq; removed by wgq-uninstall.
# Zone names come from qvm-ls best-effort, no sudo, no prompts: a
# completion that asks questions is worse than none.

_wgq() {
	local cur prev verbs zones
	COMPREPLY=()
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD - 1]}
	verbs="zone connect disconnect up down set get servers provision peer
		firewall credential keygen pubkey apply switch status sync verify
		doctor tree top logs route restart panic uninstall"
	zones=$(qvm-ls --raw-data --fields name 2>/dev/null | sed -n 's/^sys-fw-//p')

	case $prev in
		zone)
			COMPREPLY=($(compgen -W "add attach detach list rename remove" -- "$cur"))
			return
			;;
		route)
			COMPREPLY=($(compgen -W "list dom0-updates template-updates clock new-qubes" -- "$cur"))
			return
			;;
		set)
			COMPREPLY=($(compgen -W "--global autoconnect dns $zones" -- "$cur"))
			return
			;;
		-z)
			COMPREPLY=($(compgen -W "$zones" -- "$cur"))
			return
			;;
	esac
	if [ "$COMP_CWORD" -eq 1 ]; then
		COMPREPLY=($(compgen -W "$verbs -z -n -h" -- "$cur"))
	else
		COMPREPLY=($(compgen -W "$zones default" -- "$cur"))
	fi
}
complete -F _wgq wgq
