#!/usr/bin/env bash
# Bring the terminal running a session to the front.
#
#   focus.sh <claude-pid>
#
# A claude process does not own a window -- the terminal above it does, and that
# terminal may be holding several sessions in tabs. So this works in two stages:
# walk up the process tree to whatever the compositor knows about and focus that
# window, then ask the terminal itself to select the right tab. The second stage
# needs the terminal's own control channel, and the pieces that identify the tab
# are already sitting in the session's environment (TMUX_PANE, KITTY_WINDOW_ID,
# WEZTERM_PANE), which is the only place that mapping exists.
#
# Every stage is best-effort: a missing tool or a terminal with no control
# channel costs you tab precision, never the window focus.
set -uo pipefail
shopt -s extglob

pid=${1:-}
[[ $pid == +([0-9]) && -d /proc/$pid ]] || exit 0

ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve
log() { [[ -n ${CA_DEBUG:-} ]] && printf '%(%H:%M:%S)T %s\n' -1 "$*" >> "$ROOT/focus.log"; return 0; }

# ---- the process tree --------------------------------------------------------
# The ppid from /proc/pid/stat: field 4 overall, but the split has to start at
# the LAST closing paren -- comm sits in brackets and may itself contain spaces
# and brackets -- which leaves state first and ppid second.
ppid_of() {
	local data
	data=$(< "/proc/$1/stat") || return 1
	data=${data##*)}
	read -r _ p _ <<<"$data"
	printf '%s' "$p"
}

chain=("$pid")
cur=$pid
for _ in {1..12}; do
	cur=$(ppid_of "$cur") || break
	[[ $cur == +([0-9]) && $cur -gt 1 ]] || break
	chain+=("$cur")
done
log "chain: ${chain[*]}"

# ---- the session's own environment ------------------------------------------
declare -A env=()
while IFS= read -r -d '' kv; do
	[[ $kv == *=* ]] || continue
	env[${kv%%=*}]=${kv#*=}
done < "/proc/$pid/environ" 2>/dev/null

# ---- stage one: the window ---------------------------------------------------
pids_json="[$(IFS=,; echo "${chain[*]}")]"

focus_hyprland() {
	command -v hyprctl >/dev/null || return 1
	local addr out
	addr=$(hyprctl clients -j 2>/dev/null |
	       jq -r --argjson p "$pids_json" \
	          'first(.[] | select(.pid as $x | $p | index($x)) | .address) // empty')
	[[ -n $addr ]] || return 1
	# Hyprland 0.56 moved dispatchers to a Lua API and the old spelling errors
	# out; older versions do not know the new one. Try the old, fall back.
	out=$(hyprctl dispatch "focuswindow address:$addr" 2>&1)
	[[ $out == ok* ]] || out=$(hyprctl dispatch "hl.dsp.focus({window='address:$addr'})" 2>&1)
	log "hyprland $addr -> $out"
	[[ $out == ok* ]]
}

focus_sway() {
	command -v swaymsg >/dev/null || return 1
	local p
	for p in "${chain[@]}"; do
		if swaymsg "[pid=$p] focus" >/dev/null 2>&1; then
			log "sway pid:$p"
			return 0
		fi
	done
	return 1
}

focus_niri() {
	command -v niri >/dev/null || return 1
	local id
	id=$(niri msg --json windows 2>/dev/null |
	     jq -r --argjson p "$pids_json" \
	        'first(.[] | select(.pid as $x | $p | index($x)) | .id) // empty')
	[[ -n $id ]] || return 1
	niri msg action focus-window --id "$id" >/dev/null 2>&1
	log "niri $id"
}

focus_hyprland || focus_sway || focus_niri || log "no window found for ${chain[*]}"

# ---- stage two: the tab ------------------------------------------------------
# The window is up; now the right tab inside it. Nothing here is fatal.

# tmux keeps its socket path in the first field of $TMUX.
if [[ -n ${env[TMUX_PANE]:-} && -n ${env[TMUX]:-} ]] && command -v tmux >/dev/null; then
	sock=${env[TMUX]%%,*}
	tmux -S "$sock" select-window -t "${env[TMUX_PANE]}" >/dev/null 2>&1
	tmux -S "$sock" select-pane   -t "${env[TMUX_PANE]}" >/dev/null 2>&1
	log "tmux ${env[TMUX_PANE]}"
fi

# kitty only answers from outside the terminal when remote control is on and a
# socket is configured; without those two the window focus above is all we get.
if [[ -n ${env[KITTY_LISTEN_ON]:-} && -n ${env[KITTY_WINDOW_ID]:-} ]] && command -v kitty >/dev/null; then
	kitty @ --to "${env[KITTY_LISTEN_ON]}" focus-window \
	        --match "id:${env[KITTY_WINDOW_ID]}" >/dev/null 2>&1
	log "kitty id:${env[KITTY_WINDOW_ID]}"
fi

if [[ -n ${env[WEZTERM_PANE]:-} ]] && command -v wezterm >/dev/null; then
	wezterm cli activate-pane --pane-id "${env[WEZTERM_PANE]}" >/dev/null 2>&1
	log "wezterm ${env[WEZTERM_PANE]}"
fi

exit 0
