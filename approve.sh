#!/usr/bin/env bash
# PermissionRequest hook. Hands the call to the island and waits for the
# decision it writes back.
#
# This event fires only when Claude Code is about to ask for permission, which
# is exactly the set of calls the island exists to answer. It matches no tool
# name, so everything that can prompt arrives here: MCP calls, plan approvals,
# notebook edits, whatever a plugin adds next.
#
# It used to run on PreToolUse, which was wrong in both directions. PreToolUse
# fires ahead of EVERY tool call, so the island asked about greps, reads and
# allowlisted commands Claude Code never intended to gate; and it was pinned to
# a Bash|Write|Edit|WebFetch matcher, so every other prompt went to the terminal
# with the panel saying it could not help. The move to PreToolUse was made on a
# misreading of this event's contract, not a fault in it: the decision was
# returned as {"decision":"allow"} when the field is an OBJECT --
# {"decision":{"behavior":"allow"}}. Claude Code was honouring the contract the
# whole time; this script was not writing it. Both directions verified end to
# end on 2.1.270.
#
# Fail-safe throughout: any error, timeout, or missing daemon exits 0 with no
# output, which leaves the permission flow exactly as it was -- in a session
# that can show a prompt, that is the prompt. A broken UI must never approve.
set -uo pipefail
ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve"
TIMEOUT="${CA_TIMEOUT:-300}"
defer() { exit 0; }

payload="$(cat)" || defer

command -v jq >/dev/null || defer
mkdir -p "$ROOT/requests" "$ROOT/decisions" || defer

tool=$(jq -r '.tool_name  // empty' <<<"$payload")
sid=$( jq -r '.session_id // empty' <<<"$payload")
cwd=$( jq -r '.cwd        // empty' <<<"$payload")
# Logged, because it is the one thing that says whether a session is running the
# registration this script expects. A session started before the grant moved
# keeps the hooks it was launched with, and the symptom -- being asked about
# calls nobody wanted gated -- looks identical to a bug in here.
ev=$(  jq -r '.hook_event_name // "?"' <<<"$payload")
[[ -n $tool ]] || defer
# This event carries no tool_use_id -- the id only has to be unique and agreed
# between this script and the surface, so a local one is fine.
tuid="req-$$-$(date +%s%N)"

# What the panel shows. Every tool that can prompt reaches here now, so the
# fallback matters as much as the named cases: an unknown tool is shown as its
# whole input rather than as nothing.
case "$tool" in
	Bash)         body=$(jq -r '.tool_input.command     // ""'  <<<"$payload") ;;
	Write|Edit)   body=$(jq -r '.tool_input.file_path   // ""'  <<<"$payload") ;;
	NotebookEdit) body=$(jq -r '.tool_input.notebook_path // ""' <<<"$payload") ;;
	Read)         body=$(jq -r '.tool_input.file_path   // ""'  <<<"$payload") ;;
	WebFetch)     body=$(jq -r '.tool_input.url         // ""'  <<<"$payload") ;;
	WebSearch)    body=$(jq -r '.tool_input.query       // ""'  <<<"$payload") ;;
	Task|Agent)   body=$(jq -r '.tool_input.description // ""'  <<<"$payload") ;;
	ExitPlanMode) body=$(jq -r '.tool_input.plan        // ""'  <<<"$payload") ;;
	*)            body=$(jq -r '.tool_input | tostring'         <<<"$payload") ;;
esac
[[ -z $body ]] && body=$(jq -r '.tool_input | tostring' <<<"$payload")
[[ ${#body} -gt 3000 ]] && body="${body:0:3000}…"

dec="$ROOT/decisions/$tuid"
req="$ROOT/requests/$tuid.json"
log() { printf '%s %s %s\n' "$(date +%H:%M:%S.%3N)" "$tuid" "$*" >> "$ROOT/approve.log"; }

# Nothing is watching, so blocking here would just stall the prompt for five
# minutes before deferring to it anyway. state.py --serve refreshes this.
alive=$(stat -c %Y "$ROOT/alive" 2>/dev/null || echo 0)
if (( $(date +%s) - alive > 20 )); then
	log "SKIP island not running (heartbeat ${alive})"
	defer
fi

rm -f "$dec"
trap 'rm -f "$req" "$dec"' EXIT

log "ASK on=$ev tool=$tool sid=${sid:0:6} body=${body:0:60}"
jq -nc --arg s "$sid" --arg t "$tool" --arg b "$body" --arg c "$cwd" \
       --argjson ts "$(date +%s)" \
	'{session_id:$s, tool:$t, body:$b, cwd:$c, ts:$ts}' > "$req" || defer

# The verdict is the first line, an optional reason the second.
#
# The island is not the only surface asking: the terminal shows the same prompt
# the whole time this waits. Answer it there and the tool moves on with nothing
# to tell this script, which went on blocking for the full five minutes with a
# dead Allow/Deny sitting on the panel. So the session's own status is watched
# too -- a tool finishing, the model talking again, or a turn ending, any of
# them after this request went up, means the answer already happened somewhere
# else, and the only safe reading of that is to stop waiting. Deferring can
# never approve anything; it just takes the row off the panel and leaves the
# terminal to it.
#
# Two things have to be true before that reading is safe, and getting either
# wrong pulls a live prompt off the panel half a second after it arrives.
#
# The evidence has to be NEW. The status file already holds whatever the session
# last did, and what it last did is frequently one of these events -- the tool
# before this one finished, and that is why there is a tool to ask about now. So
# the file is remembered as it was when this request went up, and only a change
# from that counts.
#
# And it has to be an event that cannot happen while a prompt is pending.
# MessageDisplay is not one: the text of an assistant message keeps rendering
# after the tool call inside it has gone out, so it landed a beat after every
# request and took the row with it. A refusal typed in the terminal therefore
# waits for the turn to end rather than being caught as it happens.
#
# None of them is the moment the answer was given -- no event fires there -- so
# an allowed long-running command keeps its row until it finishes.
live="$ROOT/live/$sid.json"
start=$(date +%s)
was=""
[[ -r $live ]] && IFS= read -r was < "$live"
answer=""
reason=""
for (( i = 0; i < TIMEOUT * 10; i++ )); do
	if (( i % 10 == 9 )); then
		[[ -e $req ]] || { log "GONE request went away"; defer; }
		if [[ -r $live ]] && IFS= read -r state < "$live" && [[ $state != "$was" ]]; then
			case $state in
			*'"event":"PostToolUse"'*|*'"event":"PostToolUseFailure"'* \
			|*'"event":"PostToolBatch"'* \
			|*'"event":"Stop"'*|*'"event":"StopFailure"'*)
				ts=${state##*\"ts\":}; ts=${ts%%,*}; ts=${ts%%\}*}
				if [[ $ts =~ ^[0-9]+$ ]] && (( ts >= start )); then
					log "GONE answered outside the island after ${i}00ms"
					defer
				fi ;;
			esac
		fi
	fi
	if [[ -s $dec ]]; then
		{ IFS= read -r answer; IFS= read -r reason; } < "$dec" 2>/dev/null
		# A half-written file can present as "allo". Only a complete verdict counts;
		# anything else means keep waiting rather than guess.
		[[ $answer == allow || $answer == deny ]] && break
		answer=""
	fi
	sleep 0.1
done

# behavior is the whole contract: a bare string here is ignored and the prompt
# goes to the terminal. deny carries a message back to Claude; allow has no
# field for one, so the note a person typed on an allow lives in the log only.
case "$answer" in
	allow) log "ANSWER allow after ${i}00ms reason=${reason:-(none)}"
         jq -nc '{hookSpecificOutput:{hookEventName:"PermissionRequest",
                  decision:{behavior:"allow"}}}' ;;
	deny)  log "ANSWER deny after ${i}00ms reason=${reason:-(none)}"
         jq -nc --arg m "${reason:-Denied from the Claude island}" \
           '{hookSpecificOutput:{hookEventName:"PermissionRequest",
             decision:{behavior:"deny",message:$m}}}' ;;
	*)     log "DEFER no decision after ${i}00ms -- the permission flow takes over" ;;
esac
exit 0
