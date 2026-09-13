#!/usr/bin/env bash
# Removes the service and every hook entry pointing into this directory.
# Leaves the rest of your settings.json untouched, and backs it up first.
#
#   --purge   also delete the runtime state (sessions, order, logs)
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/claude-island.service"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-approve"

say() { printf '  %s\n' "$*"; }

echo "removing claude-island ($HERE)"

systemctl --user disable --now claude-island.service >/dev/null 2>&1 || true
rm -f "$UNIT"
systemctl --user daemon-reload
say "service removed"

if [[ -f $SETTINGS ]]; then
	CI_DIR="$HERE" CI_SETTINGS="$SETTINGS" python3 - <<'PY'
import collections, json, os, pathlib, shutil, time
here = pathlib.Path(os.environ["CI_DIR"])
path = pathlib.Path(os.environ["CI_SETTINGS"])
shutil.copy2(path, path.with_suffix(f".json.bak-{int(time.time())}"))
cfg = json.loads(path.read_text(), object_pairs_hook=collections.OrderedDict)
hooks = cfg.get("hooks") or {}
removed = 0
for ev in list(hooks):
    kept = [g for g in hooks[ev]
            if not any(str(here) in h.get("command", "") for h in g.get("hooks", []))]
    removed += len(hooks[ev]) - len(kept)
    if kept:
        hooks[ev] = kept
    else:
        del hooks[ev]
if not hooks:
    cfg.pop("hooks", None)
path.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"  {removed} hook entries removed")
PY
fi

if [[ ${1:-} == --purge ]]; then
	rm -rf "$STATE"
	say "state removed: $STATE"
else
	say "state kept at $STATE (--purge to remove)"
fi

echo
echo "Done. Open Claude Code sessions may hold the old hooks until restarted;"
echo "they fail safe, so a call will just fall through to the normal prompt."
