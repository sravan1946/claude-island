#!/usr/bin/env bash
# PreToolUse hook. Hands the call to the island and waits for the decision it
# writes back.
#
# This used to run on PermissionRequest, which is the event that exists for
# exactly this job -- it fires only when a decision is actually needed. In
# Claude Code 2.1.269 its decision is not honoured: a hook returning the
# documented {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
# "decision":"allow"}} runs, returns cleanly, and the tool stays blocked.
# Verified three times, including inside a trusted project directory. That
# build's payload also omits the documented tool_use_id and carries an
# undocumented permission_suggestions array, so its contract has moved.
# PreToolUse's permissionDecision does work, so the grant happens here instead.
#
# The cost of that move is that PreToolUse fires for EVERY tool call rather than
# only the ones needing a decision, so the fast path below matters: in auto,
# acceptEdits or bypassPermissions mode this exits before doing any work, which
# is every session that has not deliberately asked to be prompted.
#
# Fail-safe throughout: any error, timeout, or missing daemon exits 0 with no
# output, which leaves the normal permission flow untouched. A broken UI must
# never approve.
set -uo pipefail
ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve"
TIMEOUT="${CA_TIMEOUT:-300}"
defer() { exit 0; }

payload="$(cat)" || defer

# Only sessions that have opted into being asked. Plain string matches, no fork:
# this runs ahead of every tool call in every session.
case "$payload" in
	*'"permission_mode":"default"'*|*'"permission_mode":"plan"'*) ;;
	*) defer ;;
esac

command -v jq >/dev/null || defer
mkdir -p "$ROOT/requests" "$ROOT/decisions" || defer

tool=$(jq -r '.tool_name   // empty' <<<"$payload")
sid=$( jq -r '.session_id  // empty' <<<"$payload")
cwd=$( jq -r '.cwd         // empty' <<<"$payload")
tuid=$(jq -r '.tool_use_id // empty' <<<"$payload")
[[ -n $tool ]] || defer
# 2.1.269 does not send tool_use_id on this event; the id only has to be unique
# and agreed between this script and the surface, so a local one is fine.
[[ -n $tuid ]] || tuid="req-$$-$(date +%s%N)"

case "$tool" in
	Bash)     body=$(jq -r '.tool_input.command   // ""' <<<"$payload") ;;
	Write)    body=$(jq -r '.tool_input.file_path // ""' <<<"$payload") ;;
	Edit)     body=$(jq -r '.tool_input.file_path // ""' <<<"$payload") ;;
	WebFetch) body=$(jq -r '.tool_input.url       // ""' <<<"$payload") ;;
	*)        body=$(jq -r '.tool_input | tostring'      <<<"$payload") ;;
esac
[[ ${#body} -gt 3000 ]] && body="${body:0:3000}…"

dec="$ROOT/decisions/$tuid"
req="$ROOT/requests/$tuid.json"
log() { printf '%s %s %s\n' "$(date +%H:%M:%S.%3N)" "$tuid" "$*" >> "$ROOT/approve.log"; }

# Nothing is watching, so blocking here would just stall every tool call for
# five minutes before deferring anyway. state.py --serve refreshes this.
alive=$(stat -c %Y "$ROOT/alive" 2>/dev/null || echo 0)
if (( $(date +%s) - alive > 20 )); then
	log "SKIP island not running (heartbeat ${alive})"
	defer
fi

rm -f "$dec"
trap 'rm -f "$req" "$dec"' EXIT

log "ASK tool=$tool sid=${sid:0:6} body=${body:0:60}"
jq -nc --arg s "$sid" --arg t "$tool" --arg b "$body" --arg c "$cwd" \
       --argjson ts "$(date +%s)" \
	'{session_id:$s, tool:$t, body:$b, cwd:$c, ts:$ts}' > "$req" || defer

# The verdict is the first line, an optional reason the second.
answer=""
reason=""
for (( i = 0; i < TIMEOUT * 10; i++ )); do
	if [[ -s $dec ]]; then
		{ IFS= read -r answer; IFS= read -r reason; } < "$dec" 2>/dev/null
		# A half-written file can present as "allo". Only a complete verdict counts;
		# anything else means keep waiting rather than guess.
		[[ $answer == allow || $answer == deny ]] && break
		answer=""
	fi
	sleep 0.1
done

case "$answer" in
	allow) log "ANSWER allow after ${i}00ms reason=${reason:-(none)}"
         jq -nc --arg r "${reason:-Allowed from the Claude island}" \
           '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}' ;;
	deny)  log "ANSWER deny after ${i}00ms reason=${reason:-(none)}"
         jq -nc --arg r "${reason:-Denied from the Claude island}" \
           '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
	*)     log "DEFER no decision after ${i}00ms -- normal permission flow takes over" ;;
esac
exit 0
