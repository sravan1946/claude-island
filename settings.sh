#!/usr/bin/env bash
# Open the settings window from outside the surface.
#
#   settings.sh [toggle|open|close]     (default: toggle)
#
# The surface hides itself when no session is open, so right-clicking it is not
# always available -- this is the route that always is. Bind it:
#
#   # ~/.config/hypr/hyprland.conf
#   bind = SUPER SHIFT, I, exec, ~/dev/claude-island/settings.sh
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
action=${1:-toggle}

case $action in
	toggle|open|close) ;;
	*) echo "usage: ${0##*/} [toggle|open|close]" >&2; exit 2 ;;
esac

if ! command -v quickshell >/dev/null; then
	echo "quickshell not found" >&2
	exit 1
fi

if ! quickshell ipc -p "$HERE/island.qml" call settings "$action" 2>/dev/null; then
	echo "the island is not running -- systemctl --user start claude-island.service" >&2
	exit 1
fi
