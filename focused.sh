#!/usr/bin/env bash
# Is the person already looking at the session that is asking?
#
#   focused.sh <pid>     exit 0 = yes, exit 1 = no, or we could not tell
#
# The inverse of focus.sh, and unlike focus.sh it has to be right. A wrong
# answer here does not cost tab precision, it costs the prompt: approve.sh
# reads a yes as "the terminal is in front of them, let the terminal ask" and
# never puts the row on the panel. So every uncertainty answers no -- no
# compositor, no control channel, a tool that errors, a window holding more
# sessions than we can tell apart. No is what the island did before this
# existed, and being asked twice is a nuisance where being asked nowhere is a
# session stuck until someone thinks to go looking for it.
#
# <pid> is any process in the session -- the hook that calls this, or the claude
# process itself. Everything works off its ancestor chain.
set -uo pipefail
shopt -s extglob

pid=${1:-}
[[ $pid == +([0-9]) && -d /proc/$pid ]] || exit 1

ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve
log() { [[ -n ${CA_DEBUG:-} ]] && printf '%(%H:%M:%S)T %s\n' -1 "$*" >> "$ROOT/focus.log"; return 0; }

# ---- the process tree --------------------------------------------------------
# Same walk as focus.sh: split at the LAST closing paren, because comm sits in
# brackets and may contain spaces and brackets of its own.
ppid_of() {
	local data
	data=$(< "/proc/$1/stat") || return 1
	data=${data##*)}
	read -r _ p _ <<<"$data"
	printf '%s' "$p"
}

chain_of() {
	local cur=$1 out=("$1")
	local _
	for _ in {1..12}; do
		cur=$(ppid_of "$cur") || break
		[[ $cur == +([0-9]) && $cur -gt 1 ]] || break
		out+=("$cur")
	done
	printf '%s\n' "${out[@]}"
}

mapfile -t chain < <(chain_of "$pid")
pids_json="[$(IFS=,; echo "${chain[*]}")]"
in_chain() { local p; for p in "${chain[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

# ---- stage one: which window has the focus -----------------------------------
# CA_FOCUS_PID stands in for the compositor so the rest can be tested without a
# compositor to steal focus from.
focused_pid=${CA_FOCUS_PID:-}
if [[ -z $focused_pid ]]; then
	if command -v hyprctl >/dev/null; then
		focused_pid=$(hyprctl activewindow -j 2>/dev/null | jq -r '.pid // empty')
	elif command -v swaymsg >/dev/null; then
		focused_pid=$(swaymsg -t get_tree 2>/dev/null |
		              jq -r 'first(recurse(.nodes[]?, .floating_nodes[]?) | select(.focused == true) | .pid) // empty')
	elif command -v niri >/dev/null; then
		focused_pid=$(niri msg --json focused-window 2>/dev/null | jq -r '.pid // empty')
	fi
fi
[[ $focused_pid == +([0-9]) && $focused_pid -gt 0 ]] || { log "no focused window"; exit 1; }

# The terminal above this session, not the session itself: a claude process owns
# no window, so what the compositor named is one of its ancestors.
in_chain "$focused_pid" || { log "focus is $focused_pid, not in ${chain[*]}"; exit 1; }

# ---- stage two: which tab inside it -------------------------------------------
# The window is right, which for a terminal holding one session is the whole
# answer and for a terminal holding four is barely a third of it.

# The session's environment, which is where the terminal's control channel is
# named. Read from the whole chain rather than the one pid, so it works whether
# this was called with the hook's pid or the session's.
env_from_chain() {
	local p kv
	for p in "${chain[@]}"; do
		while IFS= read -r -d '' kv; do
			[[ $kv == "$1="* ]] && { printf '%s' "${kv#*=}"; return 0; }
		done < "/proc/$p/environ" 2>/dev/null
	done
	return 1
}

# kitty knows which of its windows is current whether or not kitty itself has
# the compositor's focus, and reports the processes running in it -- so the
# question is answered by intersecting that with the chain, with no window ids
# to keep in step. Preferring an is_focused OS window matters when one kitty
# process draws several: they each have a current window and only one of them
# is in front.
if listen=$(env_from_chain KITTY_LISTEN_ON) && [[ -n $listen ]] && command -v kitty >/dev/null; then
	if tree=$(timeout 2 kitty @ --to "$listen" ls --match state:focused 2>/dev/null) && [[ -n $tree ]]; then
		hit=$(jq -r --argjson p "$pids_json" '
			. as $all
			| (map(select(.is_focused)) | if length > 0 then . else $all end)
			| [ .[].tabs[].windows[] | .pid, (.foreground_processes[]?.pid) ]
			| any(. as $x | ($p | index($x)) != null)
		' <<<"$tree" 2>/dev/null)
		case $hit in
			true)  log "kitty: focused window is this session"; exit 0 ;;
			false) log "kitty: focused window is another session"; exit 1 ;;
		esac
		log "kitty: could not read the tree, falling through"
	fi
fi

# No control channel, so the tab is not knowable -- but it only has to be known
# when there is more than one session behind that window. Every other registered
# session whose terminal is this terminal makes the answer ambiguous, and
# ambiguous is no.
shopt -s nullglob
for f in "$ROOT"/sessions/*; do
	other=$(jq -r '.pid // empty' "$f" 2>/dev/null)
	[[ $other == +([0-9]) && -d /proc/$other ]] || continue
	in_chain "$other" && continue          # the session we were asked about
	while read -r a; do
		if [[ $a == "$focused_pid" ]]; then
			log "window $focused_pid also holds session pid $other -- ambiguous"
			exit 1
		fi
	done < <(chain_of "$other")
done

log "window $focused_pid is this session, and holds no other"
exit 0
