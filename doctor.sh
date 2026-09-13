#!/usr/bin/env bash
# Checks everything the island needs and everything it installed, and says what
# to do about anything that is wrong.
#
# Exit 0 if nothing is broken (warnings are fine), 1 if something needs fixing.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/claude-island.service"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve"

fails=0
warns=0
ok()   { printf '  \033[32m ok \033[0m %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; warns=$((warns+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; fails=$((fails+1)); }
head_() { printf '\n%s\n' "$1"; }

echo "claude-island doctor -- $HERE"

# ---- required tools ---------------------------------------------------------
head_ "dependencies"
for c in quickshell python3 jq systemctl; do
	if command -v "$c" >/dev/null; then
		ok "$c  $(command -v "$c")"
	else
		case $c in
			quickshell) bad "quickshell not found" "the surface itself -- https://quickshell.org" ;;
			python3)    bad "python3 not found"    "session discovery and the state feed" ;;
			jq)         bad "jq not found"         "hook payload parsing; hooks exit quietly without it" ;;
			systemctl)  bad "systemctl not found"  "used to run the surface as a user service" ;;
		esac
	fi
done

if (( BASH_VERSINFO[0] >= 5 )); then
	ok "bash $BASH_VERSION"
else
	bad "bash $BASH_VERSION is too old" "status.sh needs 5+ for \$EPOCHSECONDS"
fi

# ---- optional ---------------------------------------------------------------
head_ "optional"
usage_cache="${CA_USAGE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-status/cache.json}"
if [[ -r $usage_cache ]]; then
	ok "usage cache  $usage_cache"
else
	warn "no usage cache at $usage_cache" \
	     "the 5h/7d limits row is omitted; everything else works. It comes from
       claude-pulse, or point CA_USAGE_CACHE at a file of the same shape."
fi

if command -v fc-list >/dev/null; then
	# Captured, not piped into grep -q: under `set -o pipefail` the early exit
	# from -q kills fc-list with SIGPIPE (141) and the whole check reads as a
	# failure, which is how this reported two installed fonts as missing.
	families=$(fc-list : family 2>/dev/null)
	for spec in "${CA_FONT_SANS:-Cantarell}" "${CA_FONT_MONO:-JetBrainsMono Nerd Font}"; do
		if grep -qiF -- "$spec" <<<"$families"; then
			ok "font  $spec"
		else
			warn "font not installed: $spec" "Qt will substitute; set CA_FONT_SANS / CA_FONT_MONO to pick your own"
		fi
	done
fi

# ---- compositor -------------------------------------------------------------
head_ "compositor"
if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
	bad "WAYLAND_DISPLAY is unset" "this is a Wayland layer-shell client; it cannot run on X11"
else
	ok "wayland  $WAYLAND_DISPLAY"
fi
case "${XDG_CURRENT_DESKTOP:-}" in
	*Hyprland*|*sway*|*river*|*niri*|*wlroots*) ok "desktop  $XDG_CURRENT_DESKTOP" ;;
	"") warn "XDG_CURRENT_DESKTOP unset" "needs wlr-layer-shell: Hyprland, sway, river, niri" ;;
	*)  warn "desktop '$XDG_CURRENT_DESKTOP' may not implement wlr-layer-shell" \
	         "GNOME and KDE do not; the surface will fail to appear" ;;
esac

# ---- this checkout ----------------------------------------------------------
head_ "files"
for f in island.qml Settings.qml themes.js state.py status.sh approve.sh session.sh focus.sh; do
	if [[ ! -f $HERE/$f ]]; then
		bad "missing $f"
	elif [[ $f == *.sh || $f == *.py ]] && [[ ! -x $HERE/$f ]]; then
		bad "$f is not executable" "chmod +x $HERE/$f"
	else
		ok "$f"
	fi
done

# ---- service ----------------------------------------------------------------
head_ "service"
if [[ ! -f $UNIT ]]; then
	bad "no unit at $UNIT" "run ./install.sh"
else
	exec_line=$(grep -m1 '^ExecStart=' "$UNIT" | cut -d= -f2-)
	if [[ $exec_line == *"$HERE/island.qml"* ]]; then
		ok "unit points at this checkout"
	else
		bad "unit points somewhere else" "ExecStart=$exec_line -- re-run ./install.sh from $HERE"
	fi
	state=$(systemctl --user is-active claude-island.service 2>/dev/null)
	if [[ $state == active ]]; then
		ok "running"
	else
		bad "not running ($state)" "systemctl --user status claude-island.service"
	fi
	[[ $(systemctl --user is-enabled claude-island.service 2>/dev/null) == enabled ]] \
		&& ok "enabled at login" \
		|| warn "not enabled at login" "systemctl --user enable claude-island.service"
fi

if pgrep -f "state.py --serve" >/dev/null 2>&1; then
	ok "state feed running"
else
	[[ -f $UNIT ]] && bad "state feed not running" "the surface has no data; check the service log"
fi

if [[ -f $STATE/alive ]]; then
	age=$(( $(date +%s) - $(stat -c %Y "$STATE/alive") ))
	if (( age <= 20 )); then
		ok "heartbeat fresh (${age}s)"
	else
		bad "heartbeat is ${age}s stale" "approve.sh will decline to block, so clicks cannot reach it"
	fi
else
	warn "no heartbeat file yet" "written once the feed has run a scan"
fi

# ---- hooks ------------------------------------------------------------------
head_ "hooks"
if [[ ! -f $SETTINGS ]]; then
	bad "no $SETTINGS" "run ./install.sh"
elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
	bad "$SETTINGS is not valid JSON" "fix it by hand; install.sh will not touch a broken file"
else
	n=$(jq --arg d "$HERE" '[.hooks // {} | to_entries[] | .value[] | .hooks[]
	                          | select(.command | startswith($d))] | length' "$SETTINGS")
	if (( n == 0 )); then
		bad "no hooks registered for this checkout" "run ./install.sh"
	else
		ok "$n hook entries registered"
	fi

	jq -e '.hooks.PreToolUse // [] | map(.hooks[].command) | any(contains("approve.sh"))' \
		"$SETTINGS" >/dev/null 2>&1 \
		&& ok "click-to-approve wired (PreToolUse)" \
		|| warn "approve.sh not on PreToolUse" "the bar still works; clicking Allow will not"

	jq -e '.hooks.PermissionRequest // [] | map(.hooks[].command) | any(contains("approve.sh"))' \
		"$SETTINGS" >/dev/null 2>&1 \
		&& bad "approve.sh is on PermissionRequest" \
		       "that event's decision is ignored by Claude Code 2.1.269 -- every prompt
       would block for nothing. Re-run ./install.sh to move it." \
		|| true

	mode=$(jq -r '.permissions.defaultMode // "default"' "$SETTINGS")
	case $mode in
		default|plan) ok "default permission mode is '$mode' -- clicks will be asked for" ;;
		*) warn "default permission mode is '$mode'" \
		        "the island is bypassed in this mode by design. Shift+Tab to 'default'
       in a session when you want click-to-approve." ;;
	esac
fi

# ---- state ------------------------------------------------------------------
head_ "state"
if [[ -d $STATE ]]; then
	if [[ -w $STATE ]]; then ok "$STATE"; else bad "$STATE is not writable"; fi
else
	warn "$STATE does not exist yet" "created on first run"
fi

if command -v python3 >/dev/null && [[ -x $HERE/state.py ]]; then
	if out=$("$HERE/state.py" 2>&1) && printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
		n=$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"]))')
		if [[ $n == 0 ]]; then
			warn "state.py sees no live sessions" "open a Claude Code session; the bar hides itself when there are none"
		else
			ok "state.py reports $n live session(s)"
		fi
	else
		bad "state.py did not return valid JSON" "$(printf '%s' "$out" | tail -3)"
	fi
fi

# ---- config -----------------------------------------------------------------
head_ "config"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-island/config.json"
if [[ ! -f $CFG ]]; then
	ok "no config file -- using defaults ($CFG)"
elif jq -e . "$CFG" >/dev/null 2>&1; then
	ok "config  $CFG"
	mon=$(jq -r 'if .monitors == "all" or .monitors == null then "all" else (.monitors | join(", ")) end' "$CFG")
	printf '       position=%s  theme=%s  monitors=%s\n' \
		"$(jq -r '.position // "bottom"' "$CFG")" \
		"$(jq -r '.theme // "tokyo-night"' "$CFG")" "$mon"
	# A monitor list naming nothing attached draws the bar on no screen at all,
	# which looks exactly like the surface being broken.
	if [[ $mon != all ]] && command -v hyprctl >/dev/null; then
		have=$(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' | tr '\n' ' ')
		for m in ${mon//,/ }; do
			[[ " $have " == *" $m "* ]] || warn "config names monitor '$m', which is not attached" \
			                                   "attached: ${have:-none}"
		done
	fi
else
	bad "$CFG is not valid JSON" "delete it to fall back to the defaults"
fi

# ---- recent trouble ---------------------------------------------------------
head_ "recent log"
errs=$(journalctl --user -u claude-island.service --since "10 minutes ago" --no-pager 2>/dev/null \
       | grep -ciE 'error|warn' || true)
if [[ ${errs:-0} -gt 0 ]]; then
	warn "$errs warning/error lines in the last 10 minutes" \
	     "journalctl --user -u claude-island.service -n 50"
else
	ok "no errors in the last 10 minutes"
fi
if [[ -s $STATE/approve.log ]]; then
	ok "last decision: $(tail -1 "$STATE/approve.log")"
fi

# ---- verdict ----------------------------------------------------------------
echo
if (( fails > 0 )); then
	printf '%d problem(s), %d warning(s).\n' "$fails" "$warns"
	exit 1
fi
if (( warns > 0 )); then
	printf 'No problems, %d warning(s) -- all optional.\n' "$warns"
else
	printf 'All good.\n'
fi
exit 0
