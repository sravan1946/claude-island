#!/usr/bin/env bash
# Installs the island: a systemd user service for the surface, and the hooks
# Claude Code needs to feed it.
#
# Safe to re-run. It only ever touches hook entries whose command points inside
# this directory, so anything else in your settings.json is left alone, and it
# writes a timestamped backup before editing.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/claude-island.service"

say()  { printf '  %s\n' "$*"; }
fail() { printf '\n%s\n' "error: $*" >&2; exit 1; }

echo "claude-island -> $HERE"
echo

# ---- dependencies -----------------------------------------------------------
echo "checking dependencies"
missing=()
for c in quickshell python3 jq systemctl; do
	command -v "$c" >/dev/null || missing+=("$c")
done
(( ${#missing[@]} == 0 )) || fail "not found: ${missing[*]}
  quickshell  the surface itself      https://quickshell.org
  python3     session discovery
  jq          hook payload parsing
  systemctl   runs the surface as a user service"

(( BASH_VERSINFO[0] >= 5 )) || fail "bash 5+ required (found $BASH_VERSION); status.sh uses \$EPOCHSECONDS"

qtver=$(quickshell --version 2>/dev/null | head -1 || true)
say "quickshell: ${qtver:-unknown}"
say "python3:    $(python3 --version 2>&1)"
command -v claude >/dev/null \
	&& say "claude:     $(claude --version 2>/dev/null | head -1)" \
	|| say "claude:     not on PATH -- hooks will still be written to $SETTINGS"

# The surface is a wlroots layer-shell client. It will not start under GNOME or
# KDE's compositors.
case "${XDG_CURRENT_DESKTOP:-}" in
	*Hyprland*|*sway*|*river*|*niri*|*wlroots*) ;;
	"") say "note: XDG_CURRENT_DESKTOP unset; needs a wlroots compositor (Hyprland, sway, river, niri)" ;;
	*)  say "note: '$XDG_CURRENT_DESKTOP' may not support wlr-layer-shell, which this needs" ;;
esac
echo

# ---- the surface ------------------------------------------------------------
echo "installing the user service"
mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<UNIT
[Unit]
Description=Claude Code session island
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=$(command -v quickshell) -p $HERE/island.qml
Restart=on-failure
RestartSec=2
Slice=background.slice

[Install]
WantedBy=graphical-session.target
UNIT
say "$UNIT"

# ---- hooks ------------------------------------------------------------------
echo
echo "registering hooks in $SETTINGS"
CI_DIR="$HERE" CI_SETTINGS="$SETTINGS" python3 - <<'PY'
import collections, json, os, pathlib, shutil, time

here = pathlib.Path(os.environ["CI_DIR"])
path = pathlib.Path(os.environ["CI_SETTINGS"])
path.parent.mkdir(parents=True, exist_ok=True)

cfg = collections.OrderedDict()
if path.exists():
    backup = path.with_suffix(f".json.bak-{int(time.time())}")
    shutil.copy2(path, backup)
    print(f"  backup: {backup}")
    try:
        cfg = json.loads(path.read_text(), object_pairs_hook=collections.OrderedDict)
    except json.JSONDecodeError as e:
        raise SystemExit(f"error: {path} is not valid JSON ({e}); not touching it")

hooks = cfg.setdefault("hooks", collections.OrderedDict())

def cmd(script, arg=""):
    return f"{here / script}" + (f" {arg}" if arg else "")

def group(command, timeout, matcher=None, status_message=None):
    h = collections.OrderedDict(type="command", command=command, timeout=timeout)
    if status_message:
        h["statusMessage"] = status_message
    g = collections.OrderedDict()
    if matcher:
        g["matcher"] = matcher
    g["hooks"] = [h]
    return g

# The grant runs on PreToolUse, not PermissionRequest -- see "Why the grant runs
# on PreToolUse" in the README. approve.sh exits in ~3ms for any session not in
# default or plan mode, so the per-call cost of being on this event is paid only
# by sessions that asked to be prompted.
wanted = collections.defaultdict(list)
wanted["PreToolUse"].append(
    group(cmd("approve.sh"), 600, matcher="Bash|Write|Edit|WebFetch",
          status_message="Waiting on the island..."))
wanted["SessionStart"].append(group(cmd("session.sh", "start"), 10))
wanted["SessionEnd"].append(group(cmd("session.sh", "end"), 10))

# Live status. Every event that marks a state change, so the surface never has
# to guess from the transcript (which cannot answer the question -- see "Status").
for ev in ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
           "PostToolUse", "PostToolUseFailure", "MessageDisplay", "Notification",
           "Stop", "StopFailure", "PreCompact", "PostCompact",
           "SubagentStart", "SubagentStop", "PostModelSwitch"):
    wanted[ev].append(group(cmd("status.sh", ev), 5))

def ours(g):
    return any(str(here) in h.get("command", "") for h in g.get("hooks", []))

added = 0
for ev, groups in wanted.items():
    kept = [g for g in hooks.get(ev, []) if not ours(g)]
    hooks[ev] = kept + groups
    added += len(groups)

# A previous version registered approve.sh here; its decision is not honoured by
# Claude Code 2.1.269, so leaving it would just block every prompt for nothing.
if "PermissionRequest" in hooks:
    hooks["PermissionRequest"] = [g for g in hooks["PermissionRequest"] if not ours(g)]
    if not hooks["PermissionRequest"]:
        del hooks["PermissionRequest"]
        print("  removed a stale PermissionRequest registration")

path.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"  {added} hook entries across {len(wanted)} events")
PY

# ---- start ------------------------------------------------------------------
echo
echo "starting"
systemctl --user daemon-reload
systemctl --user enable --now claude-island.service >/dev/null 2>&1 || true
systemctl --user restart claude-island.service
sleep 2
if [[ $(systemctl --user is-active claude-island.service) == active ]]; then
	say "running"
else
	say "NOT running -- systemctl --user status claude-island.service"
fi

cat <<DONE

Done. The bar appears at the bottom of the screen once a Claude Code session is
open; hover it for detail.

Click-to-approve only engages for sessions in "default" or "plan" permission
mode (Shift+Tab cycles). Sessions in auto mode are left completely alone.

Open sessions pick the hooks up on their own; restart one if it does not.
DONE
