#!/usr/bin/env bash
# SessionStart / SessionEnd hook -> register this Claude session so the island
# can draw a dot for it. Records the claude PID so state.py can sweep the file
# if the process dies without firing SessionEnd.
set -uo pipefail
ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve"
mkdir -p "$ROOT/sessions" || exit 0
command -v jq >/dev/null || exit 0

payload="$(cat)" || exit 0
sid=$(jq -r '.session_id // empty' <<<"$payload")
cwd=$(jq -r '.cwd // empty'        <<<"$payload")
[[ -n $sid ]] || exit 0

case "${1:-start}" in
	end) rm -f "$ROOT/sessions/$sid"; exit 0 ;;
esac

# Walk up from this hook to the claude process itself; the hook's own shell and
# any wrapper exit immediately, so their PIDs would look dead within seconds.
pid=$PPID
for _ in 1 2 3 4; do
	parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
	[[ -n $parent && $parent -gt 1 ]] || break
	comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
	[[ $comm == *claude* || $comm == node ]] && break
	pid=$parent
done

jq -nc --arg s "$sid" --arg c "$cwd" --argjson p "${pid:-0}" --argjson t "$(date +%s)" \
	'{session_id:$s, cwd:$c, pid:$p, started:$t}' > "$ROOT/sessions/$sid"
exit 0
