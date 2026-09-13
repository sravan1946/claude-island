#!/usr/bin/env bash
# Live per-session status, fed by hook events.
#
# Why not the transcript: it is a post-hoc log. A text block is only appended
# once it is complete, and it carries stop_reason=end_turn when the turn ends --
# so "the model is answering right now" is visible for about a millisecond
# before it reads as idle. Thinking blocks land 4ms before the tool_use they
# precede. Tailing the transcript can therefore only ever report two states:
# thinking (a tool_result is the last line) and idle (nothing new). Hook events
# fire at the moment the state changes, so they are the real source.
#
# Speed matters -- MessageDisplay fires repeatedly while text streams -- so this
# uses bash builtins only, forks nothing until it exits, and reads just the head
# of stdin. Every field it wants (session_id, tool_name, notification_type) sits
# near the front of the payload; a PostToolUse tool_result can be megabytes, and
# reading all of it costs ~4s in bash versus 2.7ms for the first 1KB.
#
# Usage: status.sh <event-name>   (stdin = hook JSON)

shopt -s extglob
ev=$1
ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve
LIVE=$ROOT/live
q='"'

IFS= read -r -N 1024 head

# Hand the untouched remainder to cat so the writer never sees EPIPE, and exit.
drain() { exec cat >/dev/null; }

# _f <key> -> REPLY, empty when the key is not in the head we read.
# Steps past the key, then to the next quote, so it reads both the compact
# {"k":"v"} the hooks emit and the spaced {"k": "v"} a pretty-printer would.
_f() {
	REPLY=${head#*${q}$1${q}}
	if [[ $REPLY == "$head" ]]; then REPLY=; return; fi
	REPLY=${REPLY#*${q}}
	REPLY=${REPLY%%${q}*}
}

_f session_id; sid=$REPLY
# A uuid and nothing else; anything else means the key was absent and the
# expansion handed back a slice of some other field's text.
[[ ${#sid} -eq 36 && $sid == *-*-*-*-* ]] || drain

f=$LIVE/${sid}.json
cur=
[[ -r $f ]] && IFS= read -r cur < "$f"

# _cur <key> -> REPLY: a field from what we last wrote, so an event that only
# knows about one of them does not blank the others. Trimmed one delimiter at a
# time and never with a bracket expression: a `}` inside ${...} closes the
# expansion early, so ${v%%[,}]*} silently parses as something else entirely.
_cur() {
	REPLY=${cur#*${q}$1${q}:}
	if [[ $REPLY == "$cur" ]]; then REPLY=; return; fi
	REPLY=${REPLY%%,*}
	REPLY=${REPLY%%\}*}
	REPLY=${REPLY#${q}}
	REPLY=${REPLY%${q}}
}

_cur agents; agents=${REPLY:-0}
[[ $agents == +([0-9]) ]] || agents=0
_cur model;  model=$REPLY

# Subagents are the one thing that legitimately reports from inside an agent
# context, so they are counted before the guard that drops everything else.
case $ev in
	SubagentStart) agents=$(( agents + 1 )); st=; keep=1 ;;
	SubagentStop)  agents=$(( agents > 0 ? agents - 1 : 0 )); st=; keep=1 ;;
esac

# Every other event raised inside a subagent carries the parent's session_id and
# would overwrite the main thread's status with the subagent's tool. The
# parent's own "running Agent" already covers that span.
if [[ -z ${keep:-} && $head == *${q}agent_id${q}:* ]]; then drain; fi

case $ev in
	UserPromptSubmit)  st=thinking ;;
	PreToolUse)        _f tool_name; st="running ${REPLY:-tool}" ;;
	PostToolUse|PostToolUseFailure|PostToolBatch|PostCompact)
	                   st=thinking ;;
	MessageDisplay)    st=responding ;;
	Stop)              st=idle ;;
	# A turn that ended on an API error is not idle. It looks identical to a
	# finished turn from the transcript, which is exactly why it needs saying.
	StopFailure)       st=error ;;
	PreCompact)        st=compacting ;;
	SessionStart)      _f model; model=${REPLY:-$model}; st=idle ;;
	PostModelSwitch)   _f to_model; model=${REPLY:-$model}; st=; keep=1 ;;
	SubagentStart|SubagentStop) ;;      # counted above; status unchanged
	SessionEnd)        rm -f "$f"; drain ;;
	Notification)
		_f notification_type
		case $REPLY in
			permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog)
			             st=waiting ;;
			# Out of quota. Nothing is wrong and nothing is running -- the
			# session is parked until the window resets, which is worth
			# seeing without opening the terminal to find out.
			quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled)
			             st=limit ;;
			idle_prompt) st=idle ;;
			*)           drain ;;
		esac ;;
	*)                 drain ;;
esac

now=$EPOCHSECONDS
since=$now
# An event that carries no status of its own (a subagent count, a model switch)
# keeps whatever the session was already doing.
if [[ -z $st ]]; then
	_cur status; st=${REPLY:-idle}
fi
if [[ $cur == *${q}status${q}:${q}$st${q}* ]]; then
	# Same state as before: keep the original start time so the island's timer
	# measures the state, not the last event that confirmed it.
	_cur since; old=$REPLY
	[[ $old == +([0-9]) ]] && since=$old
	# Streaming text would otherwise rewrite this file per chunk. One write
	# every 2s is enough to keep proving the session is alive.
	if [[ $ev == MessageDisplay ]]; then
		_cur ts; ts=$REPLY
		[[ $ts == +([0-9]) && $(( now - ts )) -lt 2 ]] && drain
	fi
fi

[[ -d $LIVE ]] || mkdir -p "$LIVE"
printf '{"session_id":"%s","status":"%s","since":%s,"ts":%s,"event":"%s","agents":%s,"model":"%s"}\n' \
	"$sid" "$st" "$since" "$now" "$ev" "$agents" "$model" > "$f"
drain
